extends Node3D
## Laser impact - subtle light + brush size indicator.

var _light: OmniLight3D
var _indicator: MeshInstance3D
var _indicator_material: StandardMaterial3D

var _time: float = 0.0
var _current_size: float = 0.1

@export_group("Light")
@export_range(0.5, 5.0, 0.1) var light_energy: float = 1.5
@export_range(0.1, 1.0, 0.1) var light_range: float = 0.3

@export_group("Indicator")
@export var indicator_color: Color = Color(1.0, 1.0, 1.0, 0.3)
@export var indicator_line_width: float = 0.008


func _ready() -> void:
	_setup_light()
	_setup_indicator()
	visible = false


func _setup_light() -> void:
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.7, 0.4)
	_light.light_energy = light_energy
	_light.omni_range = light_range
	_light.omni_attenuation = 1.5
	add_child(_light)


func _setup_indicator() -> void:
	_indicator = MeshInstance3D.new()
	
	# Create square outline using ImmediateMesh
	var mesh := ImmediateMesh.new()
	_indicator.mesh = mesh
	
	_indicator_material = StandardMaterial3D.new()
	_indicator_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_indicator_material.albedo_color = indicator_color
	_indicator_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_indicator_material.no_depth_test = true
	_indicator_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	
	_indicator.material_override = _indicator_material
	add_child(_indicator)


func _draw_square_outline(size: float) -> void:
	var mesh := _indicator.mesh as ImmediateMesh
	mesh.clear_surfaces()
	
	var half := size / 2.0
	var w := indicator_line_width
	
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Top edge
	_add_quad(mesh, Vector3(-half, half - w, 0), Vector3(half, half - w, 0), Vector3(half, half, 0), Vector3(-half, half, 0))
	# Bottom edge
	_add_quad(mesh, Vector3(-half, -half, 0), Vector3(half, -half, 0), Vector3(half, -half + w, 0), Vector3(-half, -half + w, 0))
	# Left edge
	_add_quad(mesh, Vector3(-half, -half, 0), Vector3(-half + w, -half, 0), Vector3(-half + w, half, 0), Vector3(-half, half, 0))
	# Right edge
	_add_quad(mesh, Vector3(half - w, -half, 0), Vector3(half, -half, 0), Vector3(half, half, 0), Vector3(half - w, half, 0))
	
	mesh.surface_end()


func _add_quad(mesh: ImmediateMesh, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	# Triangle 1
	mesh.surface_add_vertex(a)
	mesh.surface_add_vertex(b)
	mesh.surface_add_vertex(c)
	# Triangle 2
	mesh.surface_add_vertex(a)
	mesh.surface_add_vertex(c)
	mesh.surface_add_vertex(d)


func _process(delta: float) -> void:
	if not visible:
		return
	
	_time += delta * 50.0
	var flicker: float = 0.8 + randf() * 0.4
	_light.light_energy = light_energy * flicker
	_light.omni_range = light_range


func show_impact(hit_position: Vector3, normal: Vector3, brush_size: int = 8) -> void:
	global_position = hit_position + normal * 0.005
	
	# Convert brush pixel size to world size (approximate)
	var world_size: float = brush_size * 0.015
	
	if abs(world_size - _current_size) > 0.001:
		_current_size = world_size
		_draw_square_outline(world_size)
	
	visible = true


func hide_impact() -> void:
	visible = false
