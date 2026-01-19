extends Node3D
## Laser beam - heat distortion with inspector controls.

@export_group("Heat Distortion")
@export_range(0.0, 0.15, 0.005) var distortion_strength: float = 0.03
@export_range(0.0, 1.0, 0.05) var visibility: float = 0.7
@export_range(0.01, 0.2, 0.01) var beam_width: float = 0.08

@export_group("Animation")
@export_range(5.0, 80.0, 1.0) var wave_speed: float = 25.0
@export_range(10.0, 100.0, 1.0) var wave_frequency: float = 40.0

var _mesh: MeshInstance3D
var _material: ShaderMaterial
var _cone: CylinderMesh


func _ready() -> void:
	_setup_mesh()
	visible = false


func _setup_mesh() -> void:
	_mesh = MeshInstance3D.new()
	add_child(_mesh)
	
	_cone = CylinderMesh.new()
	_cone.top_radius = 0.005
	_cone.bottom_radius = beam_width
	_cone.height = 1.0
	_mesh.mesh = _cone
	
	_mesh.rotation.x = deg_to_rad(90)
	_mesh.position.z = -0.5
	
	var shader := load("res://gun/heat_distortion.gdshader") as Shader
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.render_priority = 1
	_mesh.material_override = _material
	
	_apply_settings()


func _apply_settings() -> void:
	if not _material:
		return
	_material.set_shader_parameter("distortion_strength", distortion_strength)
	_material.set_shader_parameter("wave_speed", wave_speed)
	_material.set_shader_parameter("wave_frequency", wave_frequency)
	_material.set_shader_parameter("visibility", visibility)
	
	if _cone:
		_cone.bottom_radius = beam_width


func _process(_delta: float) -> void:
	# Live update in editor and runtime
	_apply_settings()


func show_beam(from: Vector3, to: Vector3) -> void:
	var distance := from.distance_to(to)
	if distance < 0.01:
		return
	
	global_position = from
	look_at(to)
	_mesh.scale.z = distance
	visible = true


func hide_beam() -> void:
	visible = false
