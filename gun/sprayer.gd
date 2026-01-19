extends Node3D
## Sprayer - casts ray and tells cleanable objects to clean at hit point.

@export_group("Laser Settings")
@export var spray_range: float = 10.0
@export_range(0.1, 5.0, 0.1) var laser_intensity: float = 1.0

@export_group("Distance Falloff")
@export var optimal_distance: float = 2.0
@export var max_distance: float = 8.0

var _camera: Camera3D
var _laser_beam: Node3D
var _laser_impact: Node3D


func _ready() -> void:
	_camera = get_viewport().get_camera_3d()
	_laser_beam = $LaserBeam
	_laser_impact = $LaserImpact


func _physics_process(delta: float) -> void:
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_spray(delta)
	else:
		_laser_beam.hide_beam()
		_laser_impact.hide_impact()


func _spray(delta: float) -> void:
	var space_state := get_world_3d().direct_space_state
	
	var ray_from := _camera.global_position
	var ray_to := ray_from + (-_camera.global_basis.z) * spray_range
	
	var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	var result := space_state.intersect_ray(query)
	
	var beam_end: Vector3
	
	if result.is_empty():
		beam_end = ray_to
		_laser_impact.hide_impact()
	else:
		beam_end = result.position
		var hit_normal: Vector3 = result.normal
		var hit_object: Node3D = result.collider as Node3D
		var distance: float = ray_from.distance_to(result.position)
		
		_laser_impact.show_impact(beam_end, hit_normal)
		
		if hit_object.has_method("clean_at"):
			var effectiveness := _calculate_effectiveness(distance)
			hit_object.clean_at(result.position, hit_normal, laser_intensity, effectiveness, delta)
	
	_laser_beam.show_beam(global_position, beam_end)


func _calculate_effectiveness(distance: float) -> float:
	if distance > max_distance:
		return 0.0
	if distance <= optimal_distance:
		return 1.0
	
	var falloff_range: float = max_distance - optimal_distance
	var distance_past_optimal: float = distance - optimal_distance
	return 1.0 - (distance_past_optimal / falloff_range)
