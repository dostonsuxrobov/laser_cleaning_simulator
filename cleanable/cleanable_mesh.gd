extends StaticBody3D
## Cleanable mesh - finds UV from world hit position using mesh triangles.
## Works with any UV-mapped mesh imported from Blender.

@export var texture_size: int = 256
@export var clean_strength: float = 0.6
@export var clean_radius_uv: float = 0.05

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
	# Find first MeshInstance3D child
	for child in get_children():
		if child is MeshInstance3D:
			return child
	return null


func _setup_mesh_data() -> void:
	# Load mesh data for UV lookups
	_mesh_data = MeshDataTool.new()
	var mesh: Mesh = _mesh_instance.mesh
	if mesh:
		var array_mesh: ArrayMesh
		if mesh is ArrayMesh:
			array_mesh = mesh
		else:
			# Convert to ArrayMesh if needed (e.g., from imported mesh)
			array_mesh = ArrayMesh.new()
			array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.get_mesh_arrays())
		_mesh_data.create_from_surface(array_mesh, 0)


func _setup_dirt_texture() -> void:
	_dirt_image = Image.create(texture_size, texture_size, false, Image.FORMAT_R8)
	_dirt_image.fill(Color.WHITE)
	_dirt_texture = ImageTexture.create_from_image(_dirt_image)
	
	# Get or create material
	_material = _mesh_instance.get_surface_override_material(0) as ShaderMaterial
	if _material:
		_material.set_shader_parameter("dirt_mask", _dirt_texture)


func clean_at(world_pos: Vector3, radius: float, _normal: Vector3) -> void:
	var local_pos: Vector3 = _mesh_instance.to_local(world_pos)
	var uv: Vector2 = _find_uv_at_position(local_pos)
	
	if uv.x < 0:
		return
	
	# Convert UV to pixel coordinates
	var pixel_x: int = int(uv.x * texture_size) % texture_size
	var pixel_y: int = int(uv.y * texture_size) % texture_size
	var pixel_radius: int = int(clean_radius_uv * texture_size)
	pixel_radius = max(pixel_radius, 3)
	
	_paint_circle(pixel_x, pixel_y, pixel_radius)
	_dirt_texture.update(_dirt_image)


func _find_uv_at_position(local_pos: Vector3) -> Vector2:
	if not _mesh_data:
		return Vector2(-1, -1)
	
	var closest_uv: Vector2 = Vector2(-1, -1)
	var closest_dist: float = INF
	
	# Search all triangles for closest hit
	var face_count: int = _mesh_data.get_face_count()
	
	for face_idx in face_count:
		var v0_idx: int = _mesh_data.get_face_vertex(face_idx, 0)
		var v1_idx: int = _mesh_data.get_face_vertex(face_idx, 1)
		var v2_idx: int = _mesh_data.get_face_vertex(face_idx, 2)
		
		var v0: Vector3 = _mesh_data.get_vertex(v0_idx)
		var v1: Vector3 = _mesh_data.get_vertex(v1_idx)
		var v2: Vector3 = _mesh_data.get_vertex(v2_idx)
		
		# Get closest point on triangle
		var closest_on_tri: Vector3 = _closest_point_on_triangle(local_pos, v0, v1, v2)
		var dist: float = local_pos.distance_to(closest_on_tri)
		
		if dist < closest_dist:
			closest_dist = dist
			
			# Compute barycentric coordinates
			var bary: Vector3 = _barycentric(closest_on_tri, v0, v1, v2)
			
			# Interpolate UV
			var uv0: Vector2 = _mesh_data.get_vertex_uv(v0_idx)
			var uv1: Vector2 = _mesh_data.get_vertex_uv(v1_idx)
			var uv2: Vector2 = _mesh_data.get_vertex_uv(v2_idx)
			
			closest_uv = uv0 * bary.x + uv1 * bary.y + uv2 * bary.z
	
	return closest_uv


func _closest_point_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	# Project point onto triangle plane and clamp to triangle
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


func _paint_circle(cx: int, cy: int, radius: int) -> void:
	for y in range(cy - radius, cy + radius + 1):
		for x in range(cx - radius, cx + radius + 1):
			var px: int = x % texture_size
			var py: int = y % texture_size
			if px < 0:
				px += texture_size
			if py < 0:
				py += texture_size
			
			var dist: float = sqrt(pow(x - cx, 2) + pow(y - cy, 2))
			if dist <= radius:
				var current: float = _dirt_image.get_pixel(px, py).r
				var falloff: float = 1.0 - (dist / radius)
				var new_val: float = max(0.0, current - clean_strength * falloff)
				_dirt_image.set_pixel(px, py, Color(new_val, 0, 0))
