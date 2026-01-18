extends StaticBody3D
## Cleanable mesh - two-layer rust removal with scan line pattern.

@export var texture_size: int = 256

# Scan line shape (thin and wide, like real laser)
@export var scan_width: int = 24    # wide sweep
@export var scan_height: int = 2    # thin line

# Much slower rates - requires dwelling
@export var rust_clean_rate: float = 0.8
@export var metal_clean_rate: float = 0.5

var _dirt_image: Image
var _dirt_texture: ImageTexture
var _material: ShaderMaterial
var _mesh_instance: MeshInstance3D
var _mesh_data: MeshDataTool


func _ready() -> void:
	_mesh_instance = _find_mesh_instance()
	if _mesh_instance:
		_setup_mesh_data()
		_setup_dirt_texture()


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


func _setup_dirt_texture() -> void:
	_dirt_image = Image.create(texture_size, texture_size, false, Image.FORMAT_RG8)
	_dirt_image.fill(Color(1.0, 1.0, 0.0))
	_dirt_texture = ImageTexture.create_from_image(_dirt_image)
	
	_material = _mesh_instance.get_surface_override_material(0) as ShaderMaterial
	if _material:
		_material.set_shader_parameter("dirt_mask", _dirt_texture)


func clean_at(world_pos: Vector3, _radius: float, _normal: Vector3, distance: float, delta: float) -> void:
	if distance > 8.0:
		return
	
	# Closer = more effective (but not by much)
	var distance_factor: float = clamp(1.0 - (distance - 1.0) / 7.0, 0.3, 1.0)
	
	var local_pos: Vector3 = _mesh_instance.to_local(world_pos)
	var uv: Vector2 = _find_uv_at_position(local_pos)
	
	if uv.x < 0:
		return
	
	var pixel_x: int = int(uv.x * texture_size) % texture_size
	var pixel_y: int = int(uv.y * texture_size) % texture_size
	
	var strength: float = delta * distance_factor
	_clean_scanline(pixel_x, pixel_y, strength)
	_dirt_texture.update(_dirt_image)


func _clean_scanline(cx: int, cy: int, strength: float) -> void:
	var half_w: int = scan_width / 2
	var half_h: int = scan_height / 2
	
	for y in range(cy - half_h, cy + half_h + 1):
		for x in range(cx - half_w, cx + half_w + 1):
			var px: int = posmod(x, texture_size)
			var py: int = posmod(y, texture_size)
			
			# Falloff from center (stronger in middle of line)
			var dx: float = abs(x - cx) / float(half_w) if half_w > 0 else 0.0
			var falloff: float = 1.0 - dx * dx  # quadratic falloff
			
			_clean_pixel(px, py, strength * falloff)


func _clean_pixel(px: int, py: int, strength: float) -> void:
	var current: Color = _dirt_image.get_pixel(px, py)
	
	var rust: float = current.r
	var grey: float = current.g
	
	if rust > 0.01:
		# Layer 1: Peel rust (must clear this first)
		rust = max(0.0, rust - strength * rust_clean_rate)
		_dirt_image.set_pixel(px, py, Color(rust, grey, 0.0))
	elif grey > 0.01:
		# Layer 2: Polish to chrome (only when rust fully gone)
		grey = max(0.0, grey - strength * metal_clean_rate)
		_dirt_image.set_pixel(px, py, Color(0.0, grey, 0.0))


func _find_uv_at_position(local_pos: Vector3) -> Vector2:
	if not _mesh_data:
		return Vector2(-1, -1)
	
	var closest_uv: Vector2 = Vector2(-1, -1)
	var closest_dist: float = INF
	
	var face_count: int = _mesh_data.get_face_count()
	
	for face_idx in face_count:
		var v0_idx: int = _mesh_data.get_face_vertex(face_idx, 0)
		var v1_idx: int = _mesh_data.get_face_vertex(face_idx, 1)
		var v2_idx: int = _mesh_data.get_face_vertex(face_idx, 2)
		
		var v0: Vector3 = _mesh_data.get_vertex(v0_idx)
		var v1: Vector3 = _mesh_data.get_vertex(v1_idx)
		var v2: Vector3 = _mesh_data.get_vertex(v2_idx)
		
		var closest_on_tri: Vector3 = _closest_point_on_triangle(local_pos, v0, v1, v2)
		var dist: float = local_pos.distance_to(closest_on_tri)
		
		if dist < closest_dist:
			closest_dist = dist
			var bary: Vector3 = _barycentric(closest_on_tri, v0, v1, v2)
			var uv0: Vector2 = _mesh_data.get_vertex_uv(v0_idx)
			var uv1: Vector2 = _mesh_data.get_vertex_uv(v1_idx)
			var uv2: Vector2 = _mesh_data.get_vertex_uv(v2_idx)
			closest_uv = uv0 * bary.x + uv1 * bary.y + uv2 * bary.z
	
	return closest_uv


func _closest_point_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab: Vector3 = b - a
	var ac: Vector3 = c - a
	var ap: Vector3 = p - a
	
	var d1: float = ab.dot(ap)
	var d2: float = ac.dot(ap)
	if d1 <= 0 and d2 <= 0:
		return a
	
	var bp: Vector3 = p - b
	var d3: float = ab.dot(bp)
	var d4: float = ac.dot(bp)
	if d3 >= 0 and d4 <= d3:
		return b
	
	var vc: float = d1 * d4 - d3 * d2
	if vc <= 0 and d1 >= 0 and d3 <= 0:
		var v: float = d1 / (d1 - d3)
		return a + ab * v
	
	var cp: Vector3 = p - c
	var d5: float = ab.dot(cp)
	var d6: float = ac.dot(cp)
	if d6 >= 0 and d5 <= d6:
		return c
	
	var vb: float = d5 * d2 - d1 * d6
	if vb <= 0 and d2 >= 0 and d6 <= 0:
		var w: float = d2 / (d2 - d6)
		return a + ac * w
	
	var va: float = d3 * d6 - d5 * d4
	if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0:
		var w: float = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w
	
	var denom: float = 1.0 / (va + vb + vc)
	var v2: float = vb * denom
	var w2: float = vc * denom
	return a + ab * v2 + ac * w2


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
	var u: float = 1.0 - v - w
	
	return Vector3(u, v, w)
