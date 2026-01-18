extends Node3D
## Sprayer - casts ray and tells cleanable objects to clean at hit point.

@export var spray_range: float = 10.0
@export var spray_radius: float = 0.15

var _camera: Camera3D
var _laser_beam: Node3D


func _ready() -> void:
	_camera = get_viewport().get_camera_3d()
	_laser_beam = $LaserBeam


func _physics_process(delta: float) -> void:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_spray(delta)
	else:
		_laser_beam.hide_beam()


func _spray(delta: float) -> void:
	var space_state := get_world_3d().direct_space_state
	
	var ray_from := _camera.global_position
	var ray_to := ray_from + (-_camera.global_basis.z) * spray_range
	
	var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	var result := space_state.intersect_ray(query)
	
	var beam_end: Vector3
	
	if result.is_empty():
		beam_end = ray_to
	else:
		beam_end = result.position
		var hit_object: Node3D = result.collider as Node3D
		var distance: float = ray_from.distance_to(result.position)
		
		if hit_object.has_method("clean_at"):
			hit_object.clean_at(result.position, spray_radius, result.normal, distance, delta)
	
	_laser_beam.show_beam(global_position, beam_end)
