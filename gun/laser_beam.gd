extends Node3D
## Laser beam visual - renders a line from origin to target.

var _mesh: MeshInstance3D


func _ready() -> void:
	_setup_mesh()
	visible = false


func _setup_mesh() -> void:
	_mesh = MeshInstance3D.new()
	add_child(_mesh)
	
	var box := BoxMesh.new()
	box.size = Vector3(0.008, 0.008, 1.0)
	_mesh.mesh = box
	_mesh.position.z = -0.5  # pivot at start, not center
	
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.1, 0.1)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.2, 0.1)
	mat.emission_energy_multiplier = 3.0
	_mesh.material_override = mat


func show_beam(from: Vector3, to: Vector3) -> void:
	if from.distance_to(to) < 0.01:
		return
	
	global_position = from
	look_at(to)
	_mesh.scale.z = from.distance_to(to)
	visible = true


func hide_beam() -> void:
	visible = false
