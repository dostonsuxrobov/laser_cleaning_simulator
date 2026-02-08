extends StaticBody3D
## Cleanable Mesh - CPU painting with zone-based completion.

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
@export_range(0.05, 0.3, 0.01) var color_tolerance: float = 0.2
@export var min_zone_pixels: int = 100

# =============================================================================
# PRIVATE VARIABLES
# =============================================================================

var _dirt_image: Image
var _dirt_texture: ImageTexture
var _flash_data: PackedByteArray
var _flash_texture: ImageTexture
var _zone_image: Image
var _zone_mask_image: Image
var _zone_mask_texture: ImageTexture

var _material: ShaderMaterial
var _mesh_instance: MeshInstance3D
var _mesh_data: MeshDataTool

var _zones: Dictionary = {}
var _zone_auto_names: Dictionary = {}
var _pixel_to_zone: Dictionary = {}

var _face_grid: Dictionary = {}
var _face_cache: Array[Dictionary] = []
var _grid_cell_size: float = 1.0

var _dirt_dirty: bool = false
var _flash_active: bool = false

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	add_to_group("cleanable")
	
	_mesh_instance = _find_mesh_instance()
	if not _mesh_instance:
		push_warning("No MeshInstance3D found as child")
		return
	
	var t := Time.get_ticks_msec()
	_setup_mesh_data()
	print("Mesh data: %d ms" % (Time.get_ticks_msec() - t))
	
	t = Time.get_ticks_msec()
	_setup_textures()
	print("Textures: %d ms" % (Time.get_ticks_msec() - t))
	
	t = Time.get_ticks_msec()
	_setup_zones()
	print("Zones: %d ms" % (Time.get_ticks_msec() - t))
	
	if has_node("/root/DirtVision"):
		var dirt_vision: Node = get_node("/root/DirtVision")
		dirt_vision.dirt_vision_changed.connect(_on_dirt_vision_changed)


func _process(delta: float) -> void:
	if _dirt_dirty:
		_dirt_texture.update(_dirt_image)
		_dirt_dirty = false
	
	if _flash_active:
		_fade_flash(delta)


func _input(event: InputEvent) -> void:
	if OS.is_debug_build() and event is InputEventKey and event.pressed and event.keycode == KEY_P:
		_print_zone_progress()

# =============================================================================
# PUBLIC API
# =============================================================================

func clean_at(world_pos: Vector3, _normal: Vector3, intensity: float, effectiveness: float, delta: float, brush_size: int = 8, pressure: float = 1.0) -> void:
	if effectiveness <= 0.0:
		return
	
	var local_pos: Vector3 = _mesh_instance.to_local(world_pos)
	var uv: Vector2 = _find_uv_at_position(local_pos)
	
	if uv.x < 0:
		return
	
	var pixel_x: int = int(uv.x * texture_size) % texture_size
	var pixel_y: int = int(uv.y * texture_size) % texture_size
	var strength: float = laser_power * intensity * effectiveness * pressure * delta
	
	_paint_circle(pixel_x, pixel_y, strength, brush_size)
	_dirt_dirty = true


func get_zone_at_position(world_pos: Vector3) -> Dictionary:
	var local_pos: Vector3 = _mesh_instance.to_local(world_pos)
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
	var progress: float = _calculate_zone_progress(zone)
	
	return {
		"key": zone_key,
		"name": _get_zone_display_name(zone_key),
		"progress": progress,
		"completed": zone["completed"]
	}


func get_total_progress() -> float:
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
	
	var rust_progress: float = 1.0 - (remaining_rust / total_rust)
	var metal_progress: float = 1.0 - (remaining_metal / total_metal)
	
	return (rust_progress + metal_progress) / 2.0


func get_zones_state() -> Dictionary:
	var state: Dictionary = {}
	
	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		var progress: float = _calculate_zone_progress(zone)
		
		state[zone_key] = {
			"name": _get_zone_display_name(zone_key),
			"completed": zone["completed"],
			"progress": progress
		}
	
	return state


func get_dirt_image() -> Image:
	return _dirt_image


func set_dirt_image(img: Image) -> void:
	if img and _dirt_image:
		_dirt_image.copy_from(img)
		_dirt_dirty = true

# =============================================================================
# SETUP
# =============================================================================

func _find_mesh_instance() -> MeshInstance3D:
	for child: Node in get_children():
		if child is MeshInstance3D:
			return child
	return null


func _setup_mesh_data() -> void:
	_mesh_data = MeshDataTool.new()
	var mesh: Mesh = _mesh_instance.mesh
	
	if not mesh:
		push_warning("No mesh found")
		return
	
	var surface_count: int = mesh.get_surface_count()
	print("Mesh has %d surfaces, using surface %d" % [surface_count, surface_index])
	
	if surface_index >= surface_count:
		push_warning("Surface index %d out of range (max %d)" % [surface_index, surface_count - 1])
		surface_index = 0
	
	var array_mesh: ArrayMesh
	if mesh is ArrayMesh:
		array_mesh = mesh
	else:
		array_mesh = ArrayMesh.new()
		for i: int in range(mesh.get_surface_count()):
			var arrays: Array = mesh.surface_get_arrays(i)
			array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	var error: int = _mesh_data.create_from_surface(array_mesh, surface_index)
	if error != OK:
		push_warning("Failed to create mesh data from surface %d" % surface_index)
		return
	
	_build_face_grid()


func _build_face_grid() -> void:
	var face_count: int = _mesh_data.get_face_count()
	print("Building spatial grid for %d faces..." % face_count)
	
	_face_cache.clear()
	_face_grid.clear()
	
	var mesh_min := Vector3(INF, INF, INF)
	var mesh_max := Vector3(-INF, -INF, -INF)
	
	for face_idx: int in range(face_count):
		var v0_idx: int = _mesh_data.get_face_vertex(face_idx, 0)
		var v1_idx: int = _mesh_data.get_face_vertex(face_idx, 1)
		var v2_idx: int = _mesh_data.get_face_vertex(face_idx, 2)
		
		var v0: Vector3 = _mesh_data.get_vertex(v0_idx)
		var v1: Vector3 = _mesh_data.get_vertex(v1_idx)
		var v2: Vector3 = _mesh_data.get_vertex(v2_idx)
		
		var uv0: Vector2 = _mesh_data.get_vertex_uv(v0_idx)
		var uv1: Vector2 = _mesh_data.get_vertex_uv(v1_idx)
		var uv2: Vector2 = _mesh_data.get_vertex_uv(v2_idx)
		
		var face_data: Dictionary = {
			"v0": v0, "v1": v1, "v2": v2,
			"uv0": uv0, "uv1": uv1, "uv2": uv2
		}
		_face_cache.append(face_data)
		
		for v: Vector3 in [v0, v1, v2]:
			mesh_min.x = min(mesh_min.x, v.x)
			mesh_min.y = min(mesh_min.y, v.y)
			mesh_min.z = min(mesh_min.z, v.z)
			mesh_max.x = max(mesh_max.x, v.x)
			mesh_max.y = max(mesh_max.y, v.y)
			mesh_max.z = max(mesh_max.z, v.z)
	
	var mesh_extent: Vector3 = mesh_max - mesh_min
	var longest_axis: float = max(mesh_extent.x, max(mesh_extent.y, mesh_extent.z))
	
	if longest_axis > 0.0:
		_grid_cell_size = longest_axis / 20.0
	else:
		_grid_cell_size = 1.0
	
	print("Mesh bounds: %s to %s (extent: %s)" % [mesh_min, mesh_max, mesh_extent])
	print("Auto grid cell size: %.3f" % _grid_cell_size)
	
	for face_idx: int in range(face_count):
		var face: Dictionary = _face_cache[face_idx]
		_add_face_to_grid_cells(face_idx, face.v0, face.v1, face.v2)
	
	print("Spatial grid built: %d cells" % _face_grid.size())


func _add_face_to_grid_cells(face_idx: int, v0: Vector3, v1: Vector3, v2: Vector3) -> void:
	var min_pos := Vector3(
		min(v0.x, min(v1.x, v2.x)),
		min(v0.y, min(v1.y, v2.y)),
		min(v0.z, min(v1.z, v2.z))
	)
	var max_pos := Vector3(
		max(v0.x, max(v1.x, v2.x)),
		max(v0.y, max(v1.y, v2.y)),
		max(v0.z, max(v1.z, v2.z))
	)
	
	var min_cell := Vector3i(
		int(floor(min_pos.x / _grid_cell_size)),
		int(floor(min_pos.y / _grid_cell_size)),
		int(floor(min_pos.z / _grid_cell_size))
	)
	var max_cell := Vector3i(
		int(floor(max_pos.x / _grid_cell_size)),
		int(floor(max_pos.y / _grid_cell_size)),
		int(floor(max_pos.z / _grid_cell_size))
	)
	
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
	_dirt_image = Image.create(texture_size, texture_size, false, Image.FORMAT_RG8)
	_dirt_image.fill(Color(1.0, 1.0, 0.0))
	_dirt_texture = ImageTexture.create_from_image(_dirt_image)
	
	# Flash mask — raw byte array, uploaded as R8 texture
	var pixel_count: int = texture_size * texture_size
	_flash_data = PackedByteArray()
	_flash_data.resize(pixel_count)
	_flash_data.fill(0)
	var flash_image: Image = Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_R8, _flash_data)
	_flash_texture = ImageTexture.create_from_image(flash_image)
	
	_zone_mask_image = Image.create(texture_size, texture_size, false, Image.FORMAT_R8)
	_zone_mask_image.fill(Color(0.0, 0.0, 0.0))
	_zone_mask_texture = ImageTexture.create_from_image(_zone_mask_image)
	
	_material = _mesh_instance.get_surface_override_material(surface_index) as ShaderMaterial
	
	if not _material:
		var mesh: Mesh = _mesh_instance.mesh
		if mesh:
			_material = mesh.surface_get_material(surface_index) as ShaderMaterial
	
	if _material:
		_material.set_shader_parameter("dirt_mask", _dirt_texture)
		_material.set_shader_parameter("flash_mask", _flash_texture)
		_material.set_shader_parameter("zone_mask", _zone_mask_texture)
		print("Material found on surface %d" % surface_index)
	else:
		push_warning("No ShaderMaterial found on surface %d" % surface_index)


func _setup_zones() -> void:
	if not zone_map:
		push_warning("No zone_map assigned")
		return
	
	_zone_image = zone_map.get_image()
	_zone_image.convert(Image.FORMAT_RGB8)
	
	if _zone_image.get_size() != Vector2i(texture_size, texture_size):
		_zone_image.resize(texture_size, texture_size, Image.INTERPOLATE_NEAREST)
	
	var reference_colors: Array[Color] = []
	for key: Variant in zone_names.keys():
		if key is Color:
			reference_colors.append(key)
	
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
			var pixel_key: int = x + y * texture_size
			var zone_key: String = _find_zone_key_for_color(color, reference_colors)
			
			_pixel_to_zone[pixel_key] = zone_key
			_add_pixel_to_zone(zone_key, x, y)
	
	var zones_to_remove: Array[String] = []
	for zone_key: String in _zones:
		if _zones[zone_key]["total"] < min_zone_pixels:
			zones_to_remove.append(zone_key)
	
	for zone_key: String in zones_to_remove:
		var zone: Dictionary = _zones[zone_key]
		for pixel: Vector2i in zone["pixels"]:
			var pixel_key: int = pixel.x + pixel.y * texture_size
			_pixel_to_zone.erase(pixel_key)
		_zones.erase(zone_key)
	
	print("Removed %d noise zones (< %d pixels)" % [zones_to_remove.size(), min_zone_pixels])
	
	_finalize_zones()
	
	print("Zones found: ", _zones.size())
	_print_zone_colors()
	
	_build_zone_mask()


func _build_zone_mask() -> void:
	var data: PackedByteArray = PackedByteArray()
	data.resize(texture_size * texture_size)
	data.fill(0)
	
	for pixel_key: int in _pixel_to_zone:
		data[pixel_key] = 255
	
	_zone_mask_image = Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_R8, data)
	_zone_mask_texture.update(_zone_mask_image)
	
	if _material:
		_material.set_shader_parameter("zone_mask", _zone_mask_texture)
	
	print("Zone mask built: %d pixels in zones" % _pixel_to_zone.size())


func _add_pixel_to_zone(zone_key: String, x: int, y: int) -> void:
	if not _zones.has(zone_key):
		_zones[zone_key] = {
			"color": _hex_to_color(zone_key),
			"total": 0,
			"completed": false,
			"pixels": [],
			"sum_x": 0,
			"sum_y": 0,
			"rust_total": 0.0,
			"rust_remaining": 0.0,
			"metal_total": 0.0,
			"metal_remaining": 0.0
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
		
		var center_x: float = zone["sum_x"] / float(zone["total"]) / texture_size
		var center_y: float = zone["sum_y"] / float(zone["total"]) / texture_size
		zone["center_uv"] = Vector2(center_x, center_y)
		
		if not _has_zone_name(zone_key):
			_zone_auto_names[zone_key] = "Zone %d" % zone_index
		
		zone_index += 1

# =============================================================================
# CLEANING
# =============================================================================



func _paint_circle(cx: int, cy: int, strength: float, brush_size: int) -> void:
	var radius: float = brush_size / 2.0
	var radius_sq: float = radius * radius
	var half: int = int(ceil(radius))
	
	for y: int in range(cy - half, cy + half + 1):
		for x: int in range(cx - half, cx + half + 1):
			var dx: float = x - cx
			var dy: float = y - cy
			if dx * dx + dy * dy <= radius_sq:
				var px: int = posmod(x, texture_size)
				var py: int = posmod(y, texture_size)
				_clean_pixel(px, py, strength)


func _clean_pixel(px: int, py: int, strength: float) -> void:
	var pixel_key: int = px + py * texture_size
	
	var zone_key: String = ""
	var zone: Variant = null
	
	if _pixel_to_zone.has(pixel_key):
		zone_key = _pixel_to_zone[pixel_key]
		if _zones.has(zone_key):
			zone = _zones[zone_key]
			if zone["completed"]:
				return
	
	var current: Color = _dirt_image.get_pixel(px, py)
	var rust: float = current.r
	var grey: float = current.g
	
	if rust <= 0.01 and grey <= 0.01:
		return
	
	if rust > 0.01:
		var amount: float = strength / rust_resistance
		var actual_decrease: float = min(amount, rust)
		rust = max(0.0, rust - amount)
		_dirt_image.set_pixel(px, py, Color(rust, grey, 0.0))
		
		if zone:
			zone["rust_remaining"] = max(0.0, zone["rust_remaining"] - actual_decrease)
			_check_zone_completion(zone_key)
	
	elif grey > 0.01:
		var amount: float = strength / metal_resistance
		var actual_decrease: float = min(amount, grey)
		grey = max(0.0, grey - amount)
		_dirt_image.set_pixel(px, py, Color(0.0, grey, 0.0))
		
		if zone:
			zone["metal_remaining"] = max(0.0, zone["metal_remaining"] - actual_decrease)
			_check_zone_completion(zone_key)

# =============================================================================
# ZONE COMPLETION
# =============================================================================

func _check_zone_completion(zone_key: String) -> void:
	if not _zones.has(zone_key):
		return
	
	var zone: Dictionary = _zones[zone_key]
	
	if zone["completed"]:
		return
	
	var rust_cleaned_pct: float = 1.0 - (zone["rust_remaining"] / zone["rust_total"])
	var metal_cleaned_pct: float = 1.0 - (zone["metal_remaining"] / zone["metal_total"])
	
	if rust_cleaned_pct >= rust_complete_threshold and metal_cleaned_pct >= metal_complete_threshold:
		_complete_zone(zone_key)


func _complete_zone(zone_key: String) -> void:
	var zone: Dictionary = _zones[zone_key]
	
	if zone["completed"]:
		return
	
	zone["completed"] = true
	zone["rust_remaining"] = 0.0
	zone["metal_remaining"] = 0.0
	
	# Clear dirt pixels using raw bytes
	var dirt_data: PackedByteArray = _dirt_image.get_data()
	for pixel: Vector2i in zone["pixels"]:
		var idx: int = (pixel.x + pixel.y * texture_size) * 2
		dirt_data[idx] = 0
		dirt_data[idx + 1] = 0
	_dirt_image = Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_RG8, dirt_data)
	_dirt_dirty = true
	
	# Write this zone's pixels into flash mask at full brightness
	for pixel: Vector2i in zone["pixels"]:
		_flash_data[pixel.x + pixel.y * texture_size] = 255
	_flash_active = true
	
	AudioManager.play_ding()
	
	emit_signal("zone_completed", zone["color"], global_position)
	print("Zone completed: ", zone_key, " (", _get_zone_display_name(zone_key), ")")
	
	_check_object_completed()


func _check_object_completed() -> void:
	for zone_key: String in _zones:
		if not _zones[zone_key]["completed"]:
			return
	
	emit_signal("object_completed")
	print("Object fully completed!")

# =============================================================================
# FLASH
# =============================================================================

func _fade_flash(delta: float) -> void:
	var fade_amount: int = int(255.0 * flash_fade_speed * delta)
	fade_amount = max(fade_amount, 1)
	
	var any_active: bool = false
	var pixel_count: int = _flash_data.size()
	
	for i: int in range(pixel_count):
		if _flash_data[i] > 0:
			var val: int = _flash_data[i] - fade_amount
			if val < 0:
				val = 0
			_flash_data[i] = val
			if val > 0:
				any_active = true
	
	var flash_image: Image = Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_R8, _flash_data)
	_flash_texture.update(flash_image)
	
	if not any_active:
		_flash_active = false

# =============================================================================
# UV LOOKUP
# =============================================================================

func _find_uv_at_position(local_pos: Vector3) -> Vector2:
	if _face_cache.is_empty():
		return Vector2(-1, -1)
	return _grid_lookup(local_pos)


func _grid_lookup(local_pos: Vector3) -> Vector2:
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


func _find_zone_key_for_color(color: Color, reference_colors: Array[Color]) -> String:
	for ref_color: Color in reference_colors:
		if _colors_similar(color, ref_color, color_tolerance):
			return _color_to_hex(ref_color)
	
	for zone_key: String in _zones.keys():
		var zone_color: Color = _zones[zone_key]["color"]
		if _colors_similar(color, zone_color, color_tolerance):
			return zone_key
	
	return _color_to_hex(color)


func _has_zone_name(zone_key: String) -> bool:
	if zone_names.has(zone_key):
		return true
	
	for key: Variant in zone_names.keys():
		if key is Color:
			if _color_to_hex(key) == zone_key:
				return true
	
	return false


func _get_zone_display_name(zone_key: String) -> String:
	if zone_names.has(zone_key):
		return zone_names[zone_key]
	
	for key: Variant in zone_names.keys():
		if key is Color:
			if _color_to_hex(key) == zone_key:
				return zone_names[key]
	
	if _zone_auto_names.has(zone_key):
		return _zone_auto_names[zone_key]
	
	return zone_key


func _colors_similar(a: Color, b: Color, tolerance: float) -> bool:
	return abs(a.r - b.r) < tolerance and abs(a.g - b.g) < tolerance and abs(a.b - b.b) < tolerance


func _color_to_hex(color: Color) -> String:
	var r: int = int(round(color.r * 255))
	var g: int = int(round(color.g * 255))
	var b: int = int(round(color.b * 255))
	return "%02x%02x%02x" % [r, g, b]


func _hex_to_color(hex: String) -> Color:
	var r: float = float(("0x" + hex.substr(0, 2)).hex_to_int()) / 255.0
	var g: float = float(("0x" + hex.substr(2, 2)).hex_to_int()) / 255.0
	var b: float = float(("0x" + hex.substr(4, 2)).hex_to_int()) / 255.0
	return Color(r, g, b)

# =============================================================================
# DEBUG
# =============================================================================

func _print_zone_colors() -> void:
	print("--- Zone Colors Detected ---")
	for zone_key: String in _zones:
		var zone_name: String = _get_zone_display_name(zone_key)
		var zone: Dictionary = _zones[zone_key]
		print("  #%s -> \"%s\" (%d pixels)" % [zone_key, zone_name, zone["total"]])
	print("---")


func _print_zone_progress() -> void:
	print("=== ZONE PROGRESS ===")
	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		var rust_pct: float = 1.0 - (zone["rust_remaining"] / zone["rust_total"])
		var metal_pct: float = 1.0 - (zone["metal_remaining"] / zone["metal_total"])
		var zone_name: String = _get_zone_display_name(zone_key)
		print("%s: Rust %.1f%% | Metal %.1f%% | Complete: %s" % [
			zone_name,
			rust_pct * 100,
			metal_pct * 100,
			"YES" if zone["completed"] else "NO"
		])
	print("=====================")


func _on_dirt_vision_changed(enabled: bool) -> void:
	if _material:
		_material.set_shader_parameter("dirt_vision_enabled", enabled)
