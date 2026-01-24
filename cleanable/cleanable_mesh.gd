extends StaticBody3D
## Cleanable Mesh - CPU painting with zone-based completion.

signal zone_completed(zone_color: Color, world_position: Vector3)
signal object_completed

@export_group("Texture")
@export var texture_size: int = 256
@export var zone_map: Texture2D

@export_group("Cleaning Speed")
@export_range(0.1, 5.0, 0.1) var laser_power: float = 1.0
@export_range(0.1, 5.0, 0.1) var rust_resistance: float = 1.0
@export_range(0.1, 5.0, 0.1) var metal_resistance: float = 1.5

@export_group("Completion")
@export_range(0.5, 1.0, 0.05) var auto_complete_threshold: float = 0.85
@export var flash_fade_speed: float = 2.0

var _dirt_image: Image
var _dirt_texture: ImageTexture
var _flash_image: Image
var _flash_texture: ImageTexture
var _zone_image: Image
var _material: ShaderMaterial
var _mesh_instance: MeshInstance3D
var _mesh_data: MeshDataTool

var _zones: Dictionary = {}
var _completed_pixels: Dictionary = {}
var _flashing_zones: Dictionary = {}


func _ready() -> void:
	_mesh_instance = _find_mesh_instance()
	if _mesh_instance:
		_setup_mesh_data()
		_setup_textures()
		_setup_zones()


func _process(delta: float) -> void:
	if _flashing_zones.is_empty():
		return
	
	var zones_to_remove: Array = []
	
	for zone_key in _flashing_zones:
		_flashing_zones[zone_key] -= delta * flash_fade_speed
		
		if _flashing_zones[zone_key] <= 0.0:
			_flashing_zones[zone_key] = 0.0
			zones_to_remove.append(zone_key)
	
	_update_flash_texture()
	
	for zone_key in zones_to_remove:
		_flashing_zones.erase(zone_key)


func _find_mesh_instance() -> MeshInstance3D:
	for child in get_children():
		if child is MeshInstance3D:
			return child
	return null


func _setup_mesh_data() -> void:
	_mesh_data = MeshDataTool.new()
	var mesh: Mesh = _mesh_instance.mesh
	if mesh:
		var array_mesh: ArrayMesh
		if mesh is ArrayMesh:
			array_mesh = mesh
		else:
			array_mesh = ArrayMesh.new()
			array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.get_mesh_arrays())
		_mesh_data.create_from_surface(array_mesh, 0)


func _setup_textures() -> void:
	_dirt_image = Image.create(texture_size, texture_size, false, Image.FORMAT_RG8)
	_dirt_image.fill(Color(1.0, 1.0, 0.0))
	_dirt_texture = ImageTexture.create_from_image(_dirt_image)
	
	_flash_image = Image.create(texture_size, texture_size, false, Image.FORMAT_R8)
	_flash_image.fill(Color(0.0, 0.0, 0.0))
	_flash_texture = ImageTexture.create_from_image(_flash_image)
	
	_material = _mesh_instance.get_surface_override_material(0) as ShaderMaterial
	if _material:
		_material.set_shader_parameter("dirt_mask", _dirt_texture)
		_material.set_shader_parameter("flash_mask", _flash_texture)


func _update_flash_texture() -> void:
	_flash_image.fill(Color(0.0, 0.0, 0.0))
	
	for zone_key in _flashing_zones:
		var intensity: float = _flashing_zones[zone_key]
		if intensity <= 0.0:
			continue
		
		var zone = _zones[zone_key]
		for pixel in zone["pixels"]:
			_flash_image.set_pixel(pixel.x, pixel.y, Color(intensity, 0.0, 0.0))
	
	_flash_texture.update(_flash_image)


func _setup_zones() -> void:
	if not zone_map:
		return
	
	_zone_image = zone_map.get_image()
	_zone_image.convert(Image.FORMAT_RGB8)
	
	if _zone_image.get_size() != Vector2i(texture_size, texture_size):
		_zone_image.resize(texture_size, texture_size, Image.INTERPOLATE_NEAREST)
	
	for y in texture_size:
		for x in texture_size:
			var color := _zone_image.get_pixel(x, y)
			
			if color.r < 0.1 and color.g < 0.1 and color.b < 0.1:
				continue
			
			var zone_key := _color_to_key(color)
			
			if not _zones.has(zone_key):
				_zones[zone_key] = {
					"color": color,
					"total": 0,
					"cleaned": 0,
					"completed": false,
					"pixels": [],
					"sum_x": 0,
					"sum_y": 0
				}
			
			_zones[zone_key]["total"] += 1
			_zones[zone_key]["pixels"].append(Vector2i(x, y))
			_zones[zone_key]["sum_x"] += x
			_zones[zone_key]["sum_y"] += y
	
	for zone_key in _zones:
		var zone = _zones[zone_key]
		var center_x: float = zone["sum_x"] / float(zone["total"]) / texture_size
		var center_y: float = zone["sum_y"] / float(zone["total"]) / texture_size
		zone["center_uv"] = Vector2(center_x, center_y)
	
	print("Zones found: ", _zones.size())


func _color_to_key(color: Color) -> String:
	var r: int = 1 if color.r > 0.5 else 0
	var g: int = 1 if color.g > 0.5 else 0
	var b: int = 1 if color.b > 0.5 else 0
	return "%d,%d,%d" % [r, g, b]


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
	_paint_square(pixel_x, pixel_y, strength, brush_size)
	_dirt_texture.update(_dirt_image)


func _paint_square(cx: int, cy: int, strength: float, brush_size: int) -> void:
	var half: int = brush_size / 2
	
	for y in range(cy - half, cy + half + 1):
		for x in range(cx - half, cx + half + 1):
			var px: int = posmod(x, texture_size)
			var py: int = posmod(y, texture_size)
			_clean_pixel(px, py, strength)


func _clean_pixel(px: int, py: int, strength: float) -> void:
	var pixel_key: int = px + py * texture_size
	
	if _completed_pixels.has(pixel_key):
		return
	
	var current: Color = _dirt_image.get_pixel(px, py)
	var rust: float = current.r
	var grey: float = current.g
	
	if rust > 0.01:
		var amount: float = strength / rust_resistance
		rust = max(0.0, rust - amount)
		_dirt_image.set_pixel(px, py, Color(rust, grey, 0.0))
	elif grey > 0.01:
		var amount: float = strength / metal_resistance
		grey = max(0.0, grey - amount)
		_dirt_image.set_pixel(px, py, Color(0.0, grey, 0.0))
	
	var is_chrome: bool = rust <= 0.01 and grey <= 0.01
	if is_chrome:
		_completed_pixels[pixel_key] = true
		_on_pixel_completed(px, py)


func _on_pixel_completed(px: int, py: int) -> void:
	if not _zone_image:
		return
	
	var color := _zone_image.get_pixel(px, py)
	
	if color.r < 0.1 and color.g < 0.1 and color.b < 0.1:
		return
	
	var zone_key := _color_to_key(color)
	
	if not _zones.has(zone_key):
		return
	
	var zone = _zones[zone_key]
	
	if zone["completed"]:
		return
	
	zone["cleaned"] += 1
	
	var progress: float = float(zone["cleaned"]) / float(zone["total"])
	
	if progress >= auto_complete_threshold:
		_complete_zone(zone_key)


func _complete_zone(zone_key: String) -> void:
	var zone = _zones[zone_key]
	
	if zone["completed"]:
		return
	
	zone["completed"] = true
	
	for pixel in zone["pixels"]:
		var pixel_key: int = pixel.x + pixel.y * texture_size
		_completed_pixels[pixel_key] = true
		_dirt_image.set_pixel(pixel.x, pixel.y, Color(0.0, 0.0, 0.0))
	
	_dirt_texture.update(_dirt_image)
	
	emit_signal("zone_completed", zone["color"], global_position)
	print("Zone completed: ", zone_key)
	
	_check_object_completed()
	
	_flashing_zones[zone_key] = 1.0


func _check_object_completed() -> void:
	for zone_key in _zones:
		if not _zones[zone_key]["completed"]:
			return
	
	emit_signal("object_completed")
	print("Object fully completed!")


func _find_uv_at_position(local_pos: Vector3) -> Vector2:
	if not _mesh_data:
		return Vector2(-1, -1)
	
	var closest_uv: Vector2 = Vector2(-1, -1)
	var closest_dist: float = INF
	var face_count: int = _mesh_data.get_face_count()
	
	for face_idx in face_count:
		var v0_idx := _mesh_data.get_face_vertex(face_idx, 0)
		var v1_idx := _mesh_data.get_face_vertex(face_idx, 1)
		var v2_idx := _mesh_data.get_face_vertex(face_idx, 2)
		
		var v0 := _mesh_data.get_vertex(v0_idx)
		var v1 := _mesh_data.get_vertex(v1_idx)
		var v2 := _mesh_data.get_vertex(v2_idx)
		
		var closest_on_tri := _closest_point_on_triangle(local_pos, v0, v1, v2)
		var dist := local_pos.distance_to(closest_on_tri)
		
		if dist < closest_dist:
			closest_dist = dist
			var bary := _barycentric(closest_on_tri, v0, v1, v2)
			var uv0 := _mesh_data.get_vertex_uv(v0_idx)
			var uv1 := _mesh_data.get_vertex_uv(v1_idx)
			var uv2 := _mesh_data.get_vertex_uv(v2_idx)
			closest_uv = uv0 * bary.x + uv1 * bary.y + uv2 * bary.z
	
	return closest_uv


func _closest_point_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denom := 1.0 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)


func _barycentric(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var denom := d00 * d11 - d01 * d01
	if abs(denom) < 0.0001:
		return Vector3(1, 0, 0)
	var v := (d11 * d20 - d01 * d21) / denom
	var w := (d00 * d21 - d01 * d20) / denom
	return Vector3(1.0 - v - w, v, w)
