extends StaticBody3D
## Cleanable Mesh - GPU painting with zone-based completion.
## Supports both simple meshes (direct child) and armature models (multiple meshes).
## Job: own the dirt texture, track zones, trigger victory when all zones clean.

# =============================================================================
# SIGNALS
# =============================================================================

signal zone_completed(zone_color: Color, world_position: Vector3)
signal object_completed

# =============================================================================
# EXPORTS
# =============================================================================

@export_group("Mesh")
@export var surface_index: int = 0

@export_group("Texture")
@export var texture_size: int = 256
@export var zone_map: Texture2D

@export_group("Zone Names")
@export var zone_names: Dictionary = {}

@export_group("Cleaning Speed")
@export_range(0.1, 5.0, 0.1) var laser_power: float = 1.0
@export_range(0.1, 5.0, 0.1) var rust_resistance: float = 1.0
@export_range(0.1, 5.0, 0.1) var metal_resistance: float = 1.5

@export_group("Completion")
@export_range(0.8, 1.0, 0.01) var rust_complete_threshold: float = 0.91
@export_range(0.8, 1.0, 0.01) var metal_complete_threshold: float = 0.89
@export var flash_fade_speed: float = 3.0
@export var min_zone_pixels: int = 100

@export_group("Zone Discovery")
@export_range(0.3, 0.9, 0.05) var brightness_threshold: float = 0.5
@export_range(0.05, 0.5, 0.05) var seed_merge_distance: float = 0.15

@export_group("Victory Animation")
@export var victory_animation_name: String = "victory_dance"

# =============================================================================
# PRIVATE STATE
# =============================================================================

var _paint_viewport: Node
var _paint_dirty: bool = false
var _progress_timer: float = 0.0
var _victory_triggered: bool = false
var _flash_active: bool = false

var _flash_data: PackedByteArray
var _flash_texture: ImageTexture
var _zone_image: Image
var _zone_mask_image: Image
var _zone_mask_texture: ImageTexture
var _last_snapshot: Image

var _materials: Array[ShaderMaterial] = []
var _mesh_instances: Array[MeshInstance3D] = []

var _zones: Dictionary = {}
var _zone_auto_names: Dictionary = {}
var _pixel_to_zone: Dictionary = {}

# Spatial grid for fast UV lookup from world position
var _face_grid: Dictionary = {}
var _face_cache: Array[Dictionary] = []
var _grid_cell_size: float = 1.0

const PROGRESS_INTERVAL: float = 0.3

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	add_to_group("cleanable")
	_validate_collision_shapes()

	_mesh_instances = _find_all_mesh_instances()
	if _mesh_instances.is_empty():
		push_warning("No MeshInstance3D found in subtree")
		return

	_setup_mesh_data()
	_setup_paint_viewport()
	_setup_textures()
	_setup_zones()

	if has_node("/root/DirtVision"):
		get_node("/root/DirtVision").dirt_vision_changed.connect(_on_dirt_vision_changed)


func _process(delta: float) -> void:
	if _flash_active:
		_fade_flash(delta)

	if _paint_dirty:
		_progress_timer += delta
		if _progress_timer >= PROGRESS_INTERVAL:
			_progress_timer = 0.0
			_paint_dirty = false
			_recalculate_progress()

# =============================================================================
# PUBLIC API — called by sprayer and game systems
# =============================================================================

## Paint dirt away at a world position. Called every frame by the sprayer.
func clean_at(world_pos: Vector3, _normal: Vector3, intensity: float, effectiveness: float, delta: float, brush_size: int = 8, pressure: float = 1.0) -> void:
	if effectiveness <= 0.0:
		return

	var local_pos: Vector3 = to_local(world_pos)
	var uv: Vector2 = _find_uv_at_position(local_pos)
	if uv.x < 0:
		return

	var strength: float = laser_power * intensity * effectiveness * pressure * delta
	_paint_viewport.stamp(uv, brush_size, strength)
	_paint_dirty = true


## Instantly clear all dirt. Used by ESC-shortcut win path.
func clean_all() -> void:
	_paint_viewport.clear_all()

	var black_img := Image.create(texture_size, texture_size, false, Image.FORMAT_RGBA8)
	black_img.fill(Color(0, 0, 0, 1))
	var black_tex := ImageTexture.create_from_image(black_img)
	for mat: ShaderMaterial in _materials:
		mat.set_shader_parameter("dirt_mask", black_tex)

	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		if zone["completed"]:
			continue
		zone["completed"] = true
		zone["rust_remaining"] = 0.0
		zone["metal_remaining"] = 0.0

	_flash_data.fill(255)
	_flash_active = true
	_paint_dirty = false


## Returns zone info at a world position. Used by sprayer for UI display.
func get_zone_at_position(world_pos: Vector3) -> Dictionary:
	var local_pos: Vector3 = to_local(world_pos)
	var uv: Vector2 = _find_uv_at_position(local_pos)
	if uv.x < 0:
		return {}

	var pixel_x: int = int(uv.x * texture_size) % texture_size
	var pixel_y: int = int(uv.y * texture_size) % texture_size
	var pixel_key: int = pixel_x + pixel_y * texture_size

	if not _pixel_to_zone.has(pixel_key):
		return {}

	var zone_key: String = _pixel_to_zone[pixel_key]
	if not _zones.has(zone_key):
		return {}

	var zone: Dictionary = _zones[zone_key]
	return {
		"key": zone_key,
		"name": _get_zone_display_name(zone_key),
		"progress": _calculate_zone_progress(zone),
		"completed": zone["completed"]
	}


## Returns true if there's still dirt at a world position. Used by crosshair.
func has_dirt_at(world_pos: Vector3) -> bool:
	var local_pos: Vector3 = to_local(world_pos)
	var uv: Vector2 = _find_uv_at_position(local_pos)
	if uv.x < 0:
		return false
	if not _last_snapshot:
		return true

	var px: int = clampi(int(uv.x * texture_size), 0, texture_size - 1)
	var py: int = clampi(int(uv.y * texture_size), 0, texture_size - 1)
	var color: Color = _last_snapshot.get_pixel(px, py)
	return color.r > 0.05 or color.g > 0.05


## Overall cleaning progress 0.0–1.0. Used by pause menu and progress UI.
func get_total_progress() -> float:
	if _paint_dirty:
		_recalculate_progress()
		_paint_dirty = false

	var total_rust: float = 0.0
	var total_metal: float = 0.0
	var remaining_rust: float = 0.0
	var remaining_metal: float = 0.0

	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		total_rust += zone["rust_total"]
		total_metal += zone["metal_total"]
		remaining_rust += zone["rust_remaining"]
		remaining_metal += zone["metal_remaining"]

	if total_rust + total_metal == 0:
		return 0.0

	return ((1.0 - remaining_rust / total_rust) + (1.0 - remaining_metal / total_metal)) / 2.0


## Per-zone state for pause menu display.
func get_zones_state() -> Dictionary:
	if _paint_dirty:
		_recalculate_progress()
		_paint_dirty = false

	var state: Dictionary = {}
	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		state[zone_key] = {
			"name": _get_zone_display_name(zone_key),
			"completed": zone["completed"],
			"progress": _calculate_zone_progress(zone)
		}
	return state


func get_dirt_image() -> Image:
	return _paint_viewport.get_snapshot()


func set_dirt_image(img: Image) -> void:
	if img:
		_paint_viewport.restore_state(img)
		_paint_dirty = true

# =============================================================================
# SETUP — runs once in _ready
# =============================================================================

func _validate_collision_shapes() -> void:
	for child: Node in get_children():
		if child is CollisionShape3D:
			assert(
				child.shape is ConcavePolygonShape3D,
				"Cleanable '%s' has '%s' using %s. Must be ConcavePolygonShape3D." % [name, child.name, child.shape.get_class()]
			)


func _find_all_mesh_instances() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	_collect_mesh_instances(self, result)
	return result


func _collect_mesh_instances(node: Node, result: Array[MeshInstance3D]) -> void:
	for child: Node in node.get_children():
		if child is MeshInstance3D:
			result.append(child)
		_collect_mesh_instances(child, result)


func _find_animation_player() -> AnimationPlayer:
	return _find_anim_recursive(self)


func _find_anim_recursive(node: Node) -> AnimationPlayer:
	for child: Node in node.get_children():
		if child is AnimationPlayer:
			return child
		var result: AnimationPlayer = _find_anim_recursive(child)
		if result:
			return result
	return null


func _setup_paint_viewport() -> void:
	var script := load("res://cleanable/paint_viewport.gd")
	_paint_viewport = Node.new()
	_paint_viewport.set_script(script)
	add_child(_paint_viewport)
	_paint_viewport.setup(texture_size, rust_resistance, metal_resistance)


func _setup_mesh_data() -> void:
	_face_cache.clear()
	_face_grid.clear()

	var mesh_min := Vector3(INF, INF, INF)
	var mesh_max := Vector3(-INF, -INF, -INF)

	# Collect faces from ALL mesh instances into one unified grid
	# All vertices transformed to StaticBody3D local space
	for mesh_instance: MeshInstance3D in _mesh_instances:
		var mesh: Mesh = mesh_instance.mesh
		if not mesh:
			continue

		var si: int = min(surface_index, mesh.get_surface_count() - 1)

		var array_mesh: ArrayMesh
		if mesh is ArrayMesh:
			array_mesh = mesh
		else:
			array_mesh = ArrayMesh.new()
			for i: int in range(mesh.get_surface_count()):
				var arrays: Array = mesh.surface_get_arrays(i)
				array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

		var mdt := MeshDataTool.new()
		if mdt.create_from_surface(array_mesh, si) != OK:
			continue

		for face_idx: int in range(mdt.get_face_count()):
			var v0_idx: int = mdt.get_face_vertex(face_idx, 0)
			var v1_idx: int = mdt.get_face_vertex(face_idx, 1)
			var v2_idx: int = mdt.get_face_vertex(face_idx, 2)

			var v0: Vector3 = to_local(mesh_instance.to_global(mdt.get_vertex(v0_idx)))
			var v1: Vector3 = to_local(mesh_instance.to_global(mdt.get_vertex(v1_idx)))
			var v2: Vector3 = to_local(mesh_instance.to_global(mdt.get_vertex(v2_idx)))

			_face_cache.append({
				"v0": v0, "v1": v1, "v2": v2,
				"uv0": mdt.get_vertex_uv(v0_idx),
				"uv1": mdt.get_vertex_uv(v1_idx),
				"uv2": mdt.get_vertex_uv(v2_idx)
			})

			for v: Vector3 in [v0, v1, v2]:
				mesh_min = Vector3(min(mesh_min.x, v.x), min(mesh_min.y, v.y), min(mesh_min.z, v.z))
				mesh_max = Vector3(max(mesh_max.x, v.x), max(mesh_max.y, v.y), max(mesh_max.z, v.z))

	if _face_cache.is_empty():
		return

	# Auto-size grid cells based on mesh extents
	var longest_axis: float = max(mesh_max.x - mesh_min.x, max(mesh_max.y - mesh_min.y, mesh_max.z - mesh_min.z))
	_grid_cell_size = longest_axis / 20.0 if longest_axis > 0.0 else 1.0

	for face_idx: int in range(_face_cache.size()):
		var face: Dictionary = _face_cache[face_idx]
		_add_face_to_grid_cells(face_idx, face.v0, face.v1, face.v2)


func _add_face_to_grid_cells(face_idx: int, v0: Vector3, v1: Vector3, v2: Vector3) -> void:
	var min_pos := Vector3(min(v0.x, min(v1.x, v2.x)), min(v0.y, min(v1.y, v2.y)), min(v0.z, min(v1.z, v2.z)))
	var max_pos := Vector3(max(v0.x, max(v1.x, v2.x)), max(v0.y, max(v1.y, v2.y)), max(v0.z, max(v1.z, v2.z)))

	var min_cell := Vector3i(int(floor(min_pos.x / _grid_cell_size)), int(floor(min_pos.y / _grid_cell_size)), int(floor(min_pos.z / _grid_cell_size)))
	var max_cell := Vector3i(int(floor(max_pos.x / _grid_cell_size)), int(floor(max_pos.y / _grid_cell_size)), int(floor(max_pos.z / _grid_cell_size)))

	# Cap very large triangles to avoid filling hundreds of cells
	var span: Vector3i = max_cell - min_cell + Vector3i.ONE
	if span.x * span.y * span.z > 64:
		var center_cell: Vector3i = (min_cell + max_cell) / 2
		for dx: int in [-1, 0, 1]:
			for dy: int in [-1, 0, 1]:
				for dz: int in [-1, 0, 1]:
					var key: Vector3i = center_cell + Vector3i(dx, dy, dz)
					if not _face_grid.has(key):
						_face_grid[key] = []
					_face_grid[key].append(face_idx)
		return

	for x: int in range(min_cell.x, max_cell.x + 1):
		for y: int in range(min_cell.y, max_cell.y + 1):
			for z: int in range(min_cell.z, max_cell.z + 1):
				var key := Vector3i(x, y, z)
				if not _face_grid.has(key):
					_face_grid[key] = []
				_face_grid[key].append(face_idx)


func _setup_textures() -> void:
	# Flash overlay (white pulse when zone completes)
	_flash_data = PackedByteArray()
	_flash_data.resize(texture_size * texture_size)
	_flash_data.fill(0)
	_flash_texture = ImageTexture.create_from_image(
		Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_R8, _flash_data)
	)

	# Zone mask (which pixels belong to any zone)
	_zone_mask_image = Image.create(texture_size, texture_size, false, Image.FORMAT_R8)
	_zone_mask_image.fill(Color(0, 0, 0))
	_zone_mask_texture = ImageTexture.create_from_image(_zone_mask_image)

	# Connect paint viewport + flash + zone mask to every unique material
	_materials.clear()
	var viewport_tex: ViewportTexture = _paint_viewport.get_viewport_texture()

	for mesh_instance: MeshInstance3D in _mesh_instances:
		var mat: ShaderMaterial = mesh_instance.get_surface_override_material(surface_index) as ShaderMaterial
		if not mat:
			var mesh: Mesh = mesh_instance.mesh
			if mesh:
				mat = mesh.surface_get_material(min(surface_index, mesh.get_surface_count() - 1)) as ShaderMaterial

		if mat and not _materials.has(mat):
			mat.set_shader_parameter("dirt_mask", viewport_tex)
			mat.set_shader_parameter("flash_mask", _flash_texture)
			mat.set_shader_parameter("zone_mask", _zone_mask_texture)
			_materials.append(mat)

# =============================================================================
# ZONE DISCOVERY — auto-detect colored regions from zone map
# =============================================================================

func _setup_zones() -> void:
	if not zone_map:
		return

	_zone_image = zone_map.get_image()
	if _zone_image.is_compressed():
		_zone_image.decompress()
	_zone_image.convert(Image.FORMAT_RGB8)

	if _zone_image.get_size() != Vector2i(texture_size, texture_size):
		_zone_image.resize(texture_size, texture_size, Image.INTERPOLATE_NEAREST)

	# Combine user-defined reference colors with auto-discovered ones
	var reference_colors: Array[Color] = []
	for key: Variant in zone_names.keys():
		if key is Color:
			reference_colors.append(key)

	var all_zone_colors: Array[Color] = reference_colors.duplicate()
	for disc_color: Color in _discover_zone_colors():
		var is_new: bool = true
		for existing: Color in all_zone_colors:
			if _color_distance(disc_color, existing) < seed_merge_distance:
				is_new = false
				break
		if is_new:
			all_zone_colors.append(disc_color)

	if all_zone_colors.is_empty():
		return

	# Assign every non-black pixel to its nearest zone color
	var data: PackedByteArray = _zone_image.get_data()
	var stride: int = 3

	for y: int in range(texture_size):
		var row_offset: int = y * texture_size * stride
		for x: int in range(texture_size):
			var i: int = row_offset + x * stride
			var r: float = data[i] / 255.0
			var g: float = data[i + 1] / 255.0
			var b: float = data[i + 2] / 255.0

			if r < 0.05 and g < 0.05 and b < 0.05:
				continue

			var color := Color(r, g, b)
			var best_color: Color = all_zone_colors[0]
			var best_dist: float = _color_distance(color, best_color)
			for zone_color: Color in all_zone_colors:
				var dist: float = _color_distance(color, zone_color)
				if dist < best_dist:
					best_dist = dist
					best_color = zone_color

			var pixel_key: int = x + y * texture_size
			var zone_key: String = _color_to_hex(best_color)
			_pixel_to_zone[pixel_key] = zone_key
			_add_pixel_to_zone(zone_key, x, y)

	# Remove tiny zones (anti-aliasing artifacts)
	var zones_to_remove: Array[String] = []
	for zone_key: String in _zones:
		if _zones[zone_key]["total"] < min_zone_pixels:
			zones_to_remove.append(zone_key)

	for zone_key: String in zones_to_remove:
		for pixel: Vector2i in _zones[zone_key]["pixels"]:
			_pixel_to_zone.erase(pixel.x + pixel.y * texture_size)
		_zones.erase(zone_key)

	_finalize_zones()
	_build_zone_mask()

	# Paint dirt only where zones exist
	_paint_viewport.fill_zone_dirt(_pixel_to_zone, texture_size)


func _discover_zone_colors() -> Array[Color]:
	var seed_colors: Array[Color] = []
	var data: PackedByteArray = _zone_image.get_data()
	var stride: int = 3

	for y: int in range(texture_size):
		var row_offset: int = y * texture_size * stride
		for x: int in range(texture_size):
			var i: int = row_offset + x * stride
			var r: float = data[i] / 255.0
			var g: float = data[i + 1] / 255.0
			var b: float = data[i + 2] / 255.0

			if max(r, max(g, b)) < brightness_threshold:
				continue

			var color := Color(r, g, b)
			var is_new: bool = true
			for seed: Color in seed_colors:
				if _color_distance(color, seed) < seed_merge_distance:
					is_new = false
					break
			if is_new:
				seed_colors.append(color)

	return seed_colors


func _build_zone_mask() -> void:
	var data: PackedByteArray = PackedByteArray()
	data.resize(texture_size * texture_size)
	data.fill(0)
	for pixel_key: int in _pixel_to_zone:
		data[pixel_key] = 255

	_zone_mask_image = Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_R8, data)
	_zone_mask_texture.update(_zone_mask_image)
	for mat: ShaderMaterial in _materials:
		mat.set_shader_parameter("zone_mask", _zone_mask_texture)


func _add_pixel_to_zone(zone_key: String, x: int, y: int) -> void:
	if not _zones.has(zone_key):
		_zones[zone_key] = {
			"color": _hex_to_color(zone_key), "total": 0, "completed": false,
			"pixels": [], "sum_x": 0, "sum_y": 0,
			"rust_total": 0.0, "rust_remaining": 0.0,
			"metal_total": 0.0, "metal_remaining": 0.0
		}

	var zone: Dictionary = _zones[zone_key]
	zone["total"] += 1
	zone["pixels"].append(Vector2i(x, y))
	zone["sum_x"] += x
	zone["sum_y"] += y
	zone["rust_total"] += 1.0
	zone["rust_remaining"] += 1.0
	zone["metal_total"] += 1.0
	zone["metal_remaining"] += 1.0


func _finalize_zones() -> void:
	var zone_index: int = 1
	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		zone["center_uv"] = Vector2(
			zone["sum_x"] / float(zone["total"]) / texture_size,
			zone["sum_y"] / float(zone["total"]) / texture_size
		)
		if not _has_zone_name(zone_key):
			_zone_auto_names[zone_key] = "Zone %d" % zone_index
		zone_index += 1

# =============================================================================
# PROGRESS — reads back the paint viewport to measure cleaning
# =============================================================================

func _recalculate_progress() -> void:
	var snapshot: Image = _paint_viewport.get_snapshot()
	if not snapshot:
		return

	_last_snapshot = snapshot
	snapshot.convert(Image.FORMAT_RGBA8)
	var data: PackedByteArray = snapshot.get_data()
	var stride: int = 4

	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		if zone["completed"]:
			continue

		var rust_sum: float = 0.0
		var metal_sum: float = 0.0
		for pixel: Vector2i in zone["pixels"]:
			var idx: int = (pixel.y * texture_size + pixel.x) * stride
			rust_sum += data[idx] / 255.0
			metal_sum += data[idx + 1] / 255.0

		zone["rust_remaining"] = rust_sum
		zone["metal_remaining"] = metal_sum
		_check_zone_completion(zone_key)

# =============================================================================
# ZONE COMPLETION — triggers flash, ding, and eventually victory
# =============================================================================

func _check_zone_completion(zone_key: String) -> void:
	var zone: Dictionary = _zones[zone_key]
	if zone["completed"]:
		return

	var rust_pct: float = 1.0 - (zone["rust_remaining"] / zone["rust_total"])
	var metal_pct: float = 1.0 - (zone["metal_remaining"] / zone["metal_total"])

	if rust_pct >= rust_complete_threshold and metal_pct >= metal_complete_threshold:
		_complete_zone(zone_key)


func _complete_zone(zone_key: String) -> void:
	var zone: Dictionary = _zones[zone_key]
	if zone["completed"]:
		return

	zone["completed"] = true
	zone["rust_remaining"] = 0.0
	zone["metal_remaining"] = 0.0

	_paint_viewport.clear_zone(zone["pixels"], texture_size)

	for pixel: Vector2i in zone["pixels"]:
		_flash_data[pixel.x + pixel.y * texture_size] = 255
	_flash_active = true

	AudioManager.play_ding()
	emit_signal("zone_completed", zone["color"], global_position)
	_check_object_completed()


func _check_object_completed() -> void:
	for zone_key: String in _zones:
		if not _zones[zone_key]["completed"]:
			return

	if _victory_triggered:
		return
	_victory_triggered = true

	emit_signal("object_completed")
	_play_victory_animation()

# =============================================================================
# VICTORY — plays dance animation, then tells GameManager we're done
# =============================================================================

func _play_victory_animation() -> void:
	var anim_player: AnimationPlayer = _find_animation_player()

	if not anim_player or not anim_player.has_animation(victory_animation_name):
		GameManager.complete_job()
		return

	anim_player.animation_finished.connect(_on_victory_animation_finished, CONNECT_ONE_SHOT)
	anim_player.play(victory_animation_name)


func _on_victory_animation_finished(_anim_name: String) -> void:
	GameManager.complete_job()

# =============================================================================
# FLASH — white pulse that fades after zone completion
# =============================================================================

func _fade_flash(delta: float) -> void:
	var fade_amount: int = max(int(255.0 * flash_fade_speed * delta), 1)
	var any_active: bool = false

	for i: int in range(_flash_data.size()):
		if _flash_data[i] > 0:
			var val: int = _flash_data[i] - fade_amount
			if val < 0:
				val = 0
			_flash_data[i] = val
			if val > 0:
				any_active = true

	_flash_texture.update(
		Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_R8, _flash_data)
	)
	if not any_active:
		_flash_active = false

# =============================================================================
# UV LOOKUP — world position → UV via spatial grid + barycentric coords
# =============================================================================

func _find_uv_at_position(local_pos: Vector3) -> Vector2:
	if _face_cache.is_empty():
		return Vector2(-1, -1)

	var closest_uv: Vector2 = Vector2(-1, -1)
	var closest_dist: float = INF

	var cx: int = int(floor(local_pos.x / _grid_cell_size))
	var cy: int = int(floor(local_pos.y / _grid_cell_size))
	var cz: int = int(floor(local_pos.z / _grid_cell_size))

	for radius: int in [1, 2, 3]:
		var faces_seen: Dictionary = {}
		var faces_to_check: Array[int] = []

		for dx: int in range(-radius, radius + 1):
			for dy: int in range(-radius, radius + 1):
				for dz: int in range(-radius, radius + 1):
					var key: Vector3i = Vector3i(cx + dx, cy + dy, cz + dz)
					if _face_grid.has(key):
						for face_idx: int in _face_grid[key]:
							if not faces_seen.has(face_idx):
								faces_seen[face_idx] = true
								faces_to_check.append(face_idx)

		if faces_to_check.is_empty():
			continue

		for face_idx: int in faces_to_check:
			var face: Dictionary = _face_cache[face_idx]
			var closest_on_tri: Vector3 = _closest_point_on_triangle(local_pos, face.v0, face.v1, face.v2)
			var dist: float = local_pos.distance_to(closest_on_tri)
			if dist < closest_dist:
				closest_dist = dist
				var bary: Vector3 = _barycentric(closest_on_tri, face.v0, face.v1, face.v2)
				closest_uv = face.uv0 * bary.x + face.uv1 * bary.y + face.uv2 * bary.z

		if closest_dist < _grid_cell_size * 2.0:
			return closest_uv

	return closest_uv


func _closest_point_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab: Vector3 = b - a
	var ac: Vector3 = c - a
	var ap: Vector3 = p - a
	var d1: float = ab.dot(ap)
	var d2: float = ac.dot(ap)

	if d1 <= 0.0 and d2 <= 0.0:
		return a

	var bp: Vector3 = p - b
	var d3: float = ab.dot(bp)
	var d4: float = ac.dot(bp)

	if d3 >= 0.0 and d4 <= d3:
		return b

	var vc: float = d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))

	var cp: Vector3 = p - c
	var d5: float = ab.dot(cp)
	var d6: float = ac.dot(cp)

	if d6 >= 0.0 and d5 <= d6:
		return c

	var vb: float = d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))

	var va: float = d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))

	var denom: float = 1.0 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)


func _barycentric(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0: Vector3 = b - a
	var v1: Vector3 = c - a
	var v2: Vector3 = p - a
	var d00: float = v0.dot(v0)
	var d01: float = v0.dot(v1)
	var d11: float = v1.dot(v1)
	var d20: float = v2.dot(v0)
	var d21: float = v2.dot(v1)
	var denom: float = d00 * d11 - d01 * d01

	if abs(denom) < 0.0001:
		return Vector3(1, 0, 0)

	var v: float = (d11 * d20 - d01 * d21) / denom
	var w: float = (d00 * d21 - d01 * d20) / denom
	return Vector3(1.0 - v - w, v, w)

# =============================================================================
# HELPERS
# =============================================================================

func _calculate_zone_progress(zone: Dictionary) -> float:
	if zone["completed"]:
		return 1.0
	var rust_progress: float = 1.0 - (zone["rust_remaining"] / zone["rust_total"])
	var metal_progress: float = 1.0 - (zone["metal_remaining"] / zone["metal_total"])
	return (rust_progress + metal_progress) / 2.0


func _color_distance(a: Color, b: Color) -> float:
	var rd: float = a.r - b.r
	var gd: float = a.g - b.g
	var bd: float = a.b - b.b
	return rd * rd + gd * gd + bd * bd


func _has_zone_name(zone_key: String) -> bool:
	if zone_names.has(zone_key):
		return true
	for key: Variant in zone_names.keys():
		if key is Color and _color_to_hex(key) == zone_key:
			return true
	return false


func _get_zone_display_name(zone_key: String) -> String:
	if zone_names.has(zone_key):
		return zone_names[zone_key]
	for key: Variant in zone_names.keys():
		if key is Color and _color_to_hex(key) == zone_key:
			return zone_names[key]
	if _zone_auto_names.has(zone_key):
		return _zone_auto_names[zone_key]
	return zone_key


func _color_to_hex(color: Color) -> String:
	return "%02x%02x%02x" % [int(round(color.r * 255)), int(round(color.g * 255)), int(round(color.b * 255))]


func _hex_to_color(hex: String) -> Color:
	return Color(
		float(("0x" + hex.substr(0, 2)).hex_to_int()) / 255.0,
		float(("0x" + hex.substr(2, 2)).hex_to_int()) / 255.0,
		float(("0x" + hex.substr(4, 2)).hex_to_int()) / 255.0
	)


func _on_dirt_vision_changed(enabled: bool) -> void:
	for mat: ShaderMaterial in _materials:
		mat.set_shader_parameter("dirt_vision_enabled", enabled)
