extends StaticBody3D
## Cleanable Mesh - world-space GPU painting with zone-based completion.
## Supports both simple meshes (direct child) and armature models (multiple meshes).
## Job: own the dirt texture, track zones, trigger victory when all zones clean.
##
## How cleaning works:
##  1. At load, a worker thread rasterizes every face into UV space, producing a
##     per-texel map of body-local surface positions + normals (SurfaceBaker).
##  2. Each laser hit runs a brush pass over the dirt mask: a texel is cleaned
##     only if its baked 3D position lies within the brush's world-space radius
##     of the hit point (and it faces the beam). What you aim at is what cleans.
## This is independent of UV layout, texel density, and island boundaries.

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
## Resolution of zone bookkeeping, progress tracking and the flash overlay.
@export var texture_size: int = 256
## Resolution of the dirt mask + baked surface maps. Higher = finer brush edges.
@export var paint_size: int = 512
## How far (in paint texels) surface data grows past UV island edges.
@export_range(2, 16) var dilate_radius: int = 8
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
var _totals_initialized: bool = false

# Baked surface data (world-space brush)
var _bake_faces: PackedFloat32Array
var _bake_thread: Thread
var _bake_ready: bool = false
var _position_texture: ImageTexture
var _normal_texture: ImageTexture
var _position_image: Image  # kept for diagnostics/tests
var _normal_image: Image
var _coverage: PackedByteArray  # texture_size grid, 1 = surface behind this texel

# Brush sweep state (continuous strokes between physics frames)
var _prev_paint_pos: Vector3 = Vector3.ZERO
var _last_paint_ms: int = -100000

# Spatial grid for fast UV lookup from world position (zone display / dirt checks)
var _face_grid: Dictionary = {}
var _face_cache: Array[Dictionary] = []
var _grid_cell_size: float = 1.0

const PROGRESS_INTERVAL: float = 0.3
const STROKE_GAP_MS: int = 200
const MAX_SWEEP_RADII: float = 10.0
const FACE_TIE_EPS: float = 0.003

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

	# Visual dirt appears immediately; brush activates when the bake finishes.
	_fill_zone_dirt()
	_start_bake()

	if has_node("/root/DirtVision"):
		get_node("/root/DirtVision").dirt_vision_changed.connect(_on_dirt_vision_changed)


func _exit_tree() -> void:
	if _bake_thread and _bake_thread.is_started():
		_bake_thread.wait_to_finish()


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

## Paint dirt away around a world position. Called every physics frame by the
## sprayer. brush_radius is in WORLD units - the cleaned spot always matches
## the aiming ring, on every part of the model.
func clean_at(world_pos: Vector3, beam_dir: Vector3, intensity: float, effectiveness: float, delta: float, brush_radius: float = 0.075, pressure: float = 1.0) -> void:
	if not _bake_ready or effectiveness <= 0.0:
		return

	var local_pos: Vector3 = to_local(world_pos)
	var inv_basis: Basis = global_transform.basis.inverse()
	var local_dir: Vector3 = (inv_basis * beam_dir).normalized()

	var s: Vector3 = global_transform.basis.get_scale()
	var scale_avg: float = maxf((s.x + s.y + s.z) / 3.0, 0.0001)
	var local_radius: float = brush_radius / scale_avg

	# Sweep from last frame's hit for gap-free strokes; jump if too far apart.
	var now: int = Time.get_ticks_msec()
	var from: Vector3 = local_pos
	if now - _last_paint_ms <= STROKE_GAP_MS \
			and _prev_paint_pos.distance_to(local_pos) <= local_radius * MAX_SWEEP_RADII:
		from = _prev_paint_pos
	_prev_paint_pos = local_pos
	_last_paint_ms = now

	var strength: float = laser_power * intensity * effectiveness * pressure * delta
	_paint_viewport.paint_world(from, local_pos, local_radius, local_dir, strength)
	_paint_dirty = true


## Instantly clear all dirt. Used by ESC-shortcut win path.
func clean_all() -> void:
	_paint_viewport.fill_black()

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
## Pass the raycast normal to disambiguate thin double-sided geometry.
func get_zone_at_position(world_pos: Vector3, world_normal: Vector3 = Vector3.ZERO) -> Dictionary:
	var uv: Vector2 = _uv_from_world(world_pos, world_normal)
	if uv.x < 0:
		return {}

	var pixel_x: int = clampi(int(uv.x * texture_size), 0, texture_size - 1)
	var pixel_y: int = clampi(int(uv.y * texture_size), 0, texture_size - 1)
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
func has_dirt_at(world_pos: Vector3, world_normal: Vector3 = Vector3.ZERO) -> bool:
	var uv: Vector2 = _uv_from_world(world_pos, world_normal)
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
		_paint_viewport.draw_image(img, true)
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
	_paint_viewport.setup(paint_size, rust_resistance, metal_resistance)


func _setup_mesh_data() -> void:
	_face_cache.clear()
	_face_grid.clear()
	_bake_faces = PackedFloat32Array()

	var mesh_min := Vector3(INF, INF, INF)
	var mesh_max := Vector3(-INF, -INF, -INF)
	var inv_basis: Basis = global_transform.basis.inverse()

	# Collect faces from ALL mesh instances into one unified grid.
	# All vertices transformed to StaticBody3D local space.
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

		var normal_basis: Basis = inv_basis * mesh_instance.global_transform.basis

		for face_idx: int in range(mdt.get_face_count()):
			var v0_idx: int = mdt.get_face_vertex(face_idx, 0)
			var v1_idx: int = mdt.get_face_vertex(face_idx, 1)
			var v2_idx: int = mdt.get_face_vertex(face_idx, 2)

			var v0: Vector3 = to_local(mesh_instance.to_global(mdt.get_vertex(v0_idx)))
			var v1: Vector3 = to_local(mesh_instance.to_global(mdt.get_vertex(v1_idx)))
			var v2: Vector3 = to_local(mesh_instance.to_global(mdt.get_vertex(v2_idx)))

			var n0: Vector3 = (normal_basis * mdt.get_vertex_normal(v0_idx)).normalized()
			var n1: Vector3 = (normal_basis * mdt.get_vertex_normal(v1_idx)).normalized()
			var n2: Vector3 = (normal_basis * mdt.get_vertex_normal(v2_idx)).normalized()

			var uv0: Vector2 = mdt.get_vertex_uv(v0_idx)
			var uv1: Vector2 = mdt.get_vertex_uv(v1_idx)
			var uv2: Vector2 = mdt.get_vertex_uv(v2_idx)

			_face_cache.append({
				"v0": v0, "v1": v1, "v2": v2,
				"uv0": uv0, "uv1": uv1, "uv2": uv2
			})

			# Flat layout for the threaded baker: 9 pos + 9 normal + 6 uv floats
			_bake_faces.append_array(PackedFloat32Array([
				v0.x, v0.y, v0.z, v1.x, v1.y, v1.z, v2.x, v2.y, v2.z,
				n0.x, n0.y, n0.z, n1.x, n1.y, n1.z, n2.x, n2.y, n2.z,
				uv0.x, uv0.y, uv1.x, uv1.y, uv2.x, uv2.y
			]))

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

	# Register the face in EVERY cell its bbox spans. Collapsing large faces to a
	# block around their center makes edge/corner hits unfindable - never do that.
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
# SURFACE BAKE — threaded position/normal map rasterization
# =============================================================================

func _start_bake() -> void:
	if _bake_faces.is_empty():
		return
	_bake_thread = Thread.new()
	_bake_thread.start(_bake_worker)


func _bake_worker() -> void:
	var result: Dictionary = SurfaceBaker.bake(_bake_faces, paint_size, dilate_radius)
	call_deferred("_on_bake_done", result)


func _on_bake_done(result: Dictionary) -> void:
	if _bake_thread:
		_bake_thread.wait_to_finish()
		_bake_thread = null

	var pos_img := Image.create_from_data(
		paint_size, paint_size, false, Image.FORMAT_RGBAF, result["position"].to_byte_array()
	)
	var nrm_img := Image.create_from_data(
		paint_size, paint_size, false, Image.FORMAT_RGBAF, result["normal"].to_byte_array()
	)
	_position_image = pos_img
	_normal_image = nrm_img
	_position_texture = ImageTexture.create_from_image(pos_img)
	_normal_texture = ImageTexture.create_from_image(nrm_img)
	_paint_viewport.set_surface_maps(_position_texture, _normal_texture)

	_coverage = _downsample_coverage(result["coverage"])
	_apply_coverage_to_zones()
	_build_zone_mask()

	# Replace the provisional fill with the coverage-corrected one, then measure
	# the true initial dirt so completion thresholds are always reachable.
	_fill_zone_dirt()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	_recalculate_progress()
	_bake_ready = true


## paint_size coverage → texture_size grid. A cell counts as covered if ANY of
## its sub-texels has surface data behind it.
func _downsample_coverage(cov: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(texture_size * texture_size)
	out.fill(0)
	var ratio: int = maxi(paint_size / texture_size, 1)

	for y: int in range(texture_size):
		for x: int in range(texture_size):
			var covered: bool = false
			for sy: int in range(ratio):
				var row: int = (y * ratio + sy) * paint_size
				for sx: int in range(ratio):
					if cov[row + x * ratio + sx] != 0:
						covered = true
						break
				if covered:
					break
			if covered:
				out[x + y * texture_size] = 1
	return out


## Drop zone pixels that have no surface behind them - the brush can never
## reach those, and counting them would make zones impossible to complete.
func _apply_coverage_to_zones() -> void:
	var removed_zones: Array[String] = []

	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		var kept: Array = []
		var pidx := PackedInt32Array()
		var sum_x: int = 0
		var sum_y: int = 0

		for pixel: Vector2i in zone["pixels"]:
			var key: int = pixel.x + pixel.y * texture_size
			if _coverage[key] != 0:
				kept.append(pixel)
				pidx.append(key)
				sum_x += pixel.x
				sum_y += pixel.y
			else:
				_pixel_to_zone.erase(key)

		if kept.size() < min_zone_pixels:
			for pixel: Vector2i in kept:
				_pixel_to_zone.erase(pixel.x + pixel.y * texture_size)
			removed_zones.append(zone_key)
			continue

		zone["pixels"] = kept
		zone["pidx"] = pidx
		zone["total"] = kept.size()
		zone["center_uv"] = Vector2(
			sum_x / float(kept.size()) / texture_size,
			sum_y / float(kept.size()) / texture_size
		)

	for zone_key: String in removed_zones:
		_zones.erase(zone_key)

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


## Paint dirt on every zone pixel (upscaled to paint resolution).
func _fill_zone_dirt() -> void:
	var img := Image.create(texture_size, texture_size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 1))
	for pixel_key: int in _pixel_to_zone:
		@warning_ignore("integer_division")
		img.set_pixel(pixel_key % texture_size, pixel_key / texture_size, Color(1, 1, 0, 1))
	_paint_viewport.draw_image(img, true)


func _add_pixel_to_zone(zone_key: String, x: int, y: int) -> void:
	if not _zones.has(zone_key):
		_zones[zone_key] = {
			"color": _hex_to_color(zone_key), "total": 0, "completed": false,
			"pixels": [], "pidx": PackedInt32Array(), "sum_x": 0, "sum_y": 0,
			"rust_total": 0.0, "rust_remaining": 0.0,
			"metal_total": 0.0, "metal_remaining": 0.0
		}

	var zone: Dictionary = _zones[zone_key]
	zone["total"] += 1
	zone["pixels"].append(Vector2i(x, y))
	zone["pidx"].append(x + y * texture_size)
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

	snapshot.convert(Image.FORMAT_RGBA8)
	if snapshot.get_size() != Vector2i(texture_size, texture_size):
		snapshot.resize(texture_size, texture_size, Image.INTERPOLATE_BILINEAR)
	_last_snapshot = snapshot

	var data: PackedByteArray = snapshot.get_data()
	var stride: int = 4

	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		if zone["completed"]:
			continue

		var rust_sum: float = 0.0
		var metal_sum: float = 0.0
		for pixel_key: int in zone["pidx"]:
			var idx: int = pixel_key * stride
			rust_sum += data[idx]
			metal_sum += data[idx + 1]
		rust_sum /= 255.0
		metal_sum /= 255.0

		if not _totals_initialized:
			# First measurement after the corrected fill = ground truth for 100% dirty
			zone["rust_total"] = maxf(rust_sum, 0.001)
			zone["metal_total"] = maxf(metal_sum, 0.001)
			zone["rust_remaining"] = rust_sum
			zone["metal_remaining"] = metal_sum
		else:
			zone["rust_remaining"] = rust_sum
			zone["metal_remaining"] = metal_sum
			_check_zone_completion(zone_key)

	if not _totals_initialized:
		_totals_initialized = true

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

	# Wipe the zone's remaining dirt speckles
	var img := Image.create(texture_size, texture_size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for pixel: Vector2i in zone["pixels"]:
		img.set_pixel(pixel.x, pixel.y, Color(0, 0, 0, 1))
	_paint_viewport.draw_image(img)

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
# (used for zone display and dirt checks; painting no longer depends on this)
# =============================================================================

func _uv_from_world(world_pos: Vector3, world_normal: Vector3 = Vector3.ZERO) -> Vector2:
	var local_pos: Vector3 = to_local(world_pos)
	var local_normal: Vector3 = Vector3.ZERO
	if world_normal != Vector3.ZERO:
		local_normal = (global_transform.basis.inverse() * world_normal).normalized()
	return _find_uv_at_position(local_pos, local_normal)


func _find_uv_at_position(local_pos: Vector3, hint_normal: Vector3 = Vector3.ZERO) -> Vector2:
	if _face_cache.is_empty():
		return Vector2(-1, -1)

	var closest_uv: Vector2 = Vector2(-1, -1)
	var closest_dist: float = INF
	var closest_dot: float = -2.0
	var use_hint: bool = hint_normal != Vector3.ZERO

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

			# Among near-tied faces (thin walls, coplanar seams), prefer the one
			# whose facing matches the raycast normal. Godot winds front faces
			# clockwise, so the OUTWARD normal is cross(v2-v0, v1-v0).
			var face_dot: float = 0.0
			if use_hint:
				var fn: Vector3 = (face.v2 - face.v0).cross(face.v1 - face.v0)
				if fn.length_squared() > 1e-12:
					face_dot = fn.normalized().dot(hint_normal)

			var better: bool = dist < closest_dist - FACE_TIE_EPS
			if not better and use_hint and dist < closest_dist + FACE_TIE_EPS and face_dot > closest_dot:
				better = true

			if better:
				closest_dist = dist
				closest_dot = face_dot
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
