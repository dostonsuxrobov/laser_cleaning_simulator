extends Node3D
## Sprayer - casts ray and tells cleanable objects to clean at hit point.

signal target_changed(zone_name: String, progress: float, completed: bool)
signal target_lost()
signal brush_size_changed(new_size: int)
signal hit_dirty_surface(is_dirty: bool)

@export_group("Laser Settings")
@export var spray_range: float = 10.0
@export_range(0.1, 5.0, 0.1) var laser_intensity: float = 1.0

@export_group("Brush Size")
@export var min_brush_size: int = 4
@export var max_brush_size: int = 16
@export var brush_scroll_step: int = 2

@export_group("Distance Falloff")
@export var optimal_distance: float = 2.0
@export var max_distance: float = 8.0

var _camera: Camera3D
var _laser_beam: Node3D
var _laser_impact: Node3D
var _laser_particles: Node3D
var _laser_active: bool = false
var _current_brush_size: int = 8
var _is_contacting: bool = false

var _current_zone_key: String = ""
var _current_cleanable: Node3D = null
var _is_aiming_at_cleanable: bool = false

var _last_hit_position: Vector3 = Vector3.ZERO
var _last_hit_normal: Vector3 = Vector3.UP
var _last_hit_object: Node3D = null
var _miss_frames: int = 0
const MAX_MISS_FRAMES: int = 2


func _ready() -> void:
	add_to_group("sprayer")
	_camera = get_viewport().get_camera_3d()
	_laser_beam = $LaserBeam
	_laser_impact = $LaserImpact
	_setup_particles()


func _setup_particles() -> void:
	var particles_scene := preload("res://player/laser_particles.tscn")
	_laser_particles = particles_scene.instantiate()
	add_child(_laser_particles)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_laser_active = not _laser_active

			if not _laser_active:
				_laser_beam.hide_beam()
				_hide_particles()
				_stop_contact()
				_last_hit_object = null
				_miss_frames = 0

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_current_brush_size = min(_current_brush_size + brush_scroll_step, max_brush_size)
			emit_signal("brush_size_changed", _current_brush_size)


		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_current_brush_size = max(_current_brush_size - brush_scroll_step, min_brush_size)
			emit_signal("brush_size_changed", _current_brush_size)



func _physics_process(delta: float) -> void:
	_update_target()

	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_spray(delta)
	elif _laser_active:
		_spray(delta)
	else:
		_laser_beam.hide_beam()
		_laser_impact.set_firing(false)
		_hide_particles()
		_stop_contact()


func _update_target() -> void:
	var space_state := get_world_3d().direct_space_state
	var ray_from := _camera.global_position
	var ray_to := ray_from + (-_camera.global_basis.z) * spray_range

	var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	var result := space_state.intersect_ray(query)

	if result.is_empty():
		_clear_target()
		_laser_impact.hide_impact()
		_is_aiming_at_cleanable = false
		emit_signal("hit_dirty_surface", false)
		return

	var hit_object: Node3D = result.collider as Node3D

	if hit_object.has_method("get_zone_at_position"):
		var zone_info: Dictionary = hit_object.get_zone_at_position(result.position)

		if not zone_info.is_empty():
			var zone_key: String = zone_info["key"]
			var zone_name: String = zone_info["name"]
			var progress: float = zone_info["progress"]
			var completed: bool = zone_info["completed"]

			_current_cleanable = hit_object
			_current_zone_key = zone_key
			_is_aiming_at_cleanable = true

			_laser_impact.show_impact(result.position, result.normal, _current_brush_size)

			emit_signal("target_changed", zone_name, progress, completed)
			emit_signal("hit_dirty_surface", not completed)
		else:
			var has_dirt: bool = false
			if hit_object.has_method("has_dirt_at"):
				has_dirt = hit_object.has_dirt_at(result.position)

			_clear_target()
			_laser_impact.hide_impact()
			_is_aiming_at_cleanable = false
			emit_signal("hit_dirty_surface", has_dirt)
	else:
		_clear_target()
		_laser_impact.hide_impact()
		_is_aiming_at_cleanable = false
		emit_signal("hit_dirty_surface", false)


func _clear_target() -> void:
	if _current_zone_key != "":
		_current_zone_key = ""
		_current_cleanable = null
		emit_signal("target_lost")


func _spray(delta: float) -> void:
	var space_state := get_world_3d().direct_space_state

	var ray_from := _camera.global_position
	var ray_to := ray_from + (-_camera.global_basis.z) * spray_range

	var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	var result := space_state.intersect_ray(query)

	var beam_end: Vector3
	var hit_position: Vector3
	var hit_normal: Vector3
	var hit_object: Node3D

	if not result.is_empty():
		hit_position = result.position
		hit_normal = result.normal
		hit_object = result.collider as Node3D
		_last_hit_position = hit_position
		_last_hit_normal = hit_normal
		_last_hit_object = hit_object
		_miss_frames = 0
	elif _miss_frames < MAX_MISS_FRAMES and _last_hit_object:
		hit_position = _last_hit_position
		hit_normal = _last_hit_normal
		hit_object = _last_hit_object
		_miss_frames += 1
	else:
		beam_end = ray_to
		_hide_particles()
		_stop_contact()
		_laser_beam.show_beam(global_position, beam_end)
		_laser_impact.set_firing(false)
		_last_hit_object = null
		return

	beam_end = hit_position
	var distance: float = ray_from.distance_to(hit_position)

	if hit_object.has_method("clean_at"):
		var effectiveness := _calculate_effectiveness(distance)
		var pressure := _get_pressure_multiplier()
		hit_object.clean_at(hit_position, hit_normal, laser_intensity, effectiveness, delta, _current_brush_size, pressure)
		_start_contact()
		_show_particles(beam_end, hit_normal)
		_laser_impact.set_firing(true)
	else:
		_stop_contact()
		_hide_particles()
		_laser_impact.set_firing(false)

	_laser_beam.show_beam(global_position, beam_end)


func _start_contact() -> void:
	if not _is_contacting:
		_is_contacting = true
		AudioManager.start_contact()


func _stop_contact() -> void:
	if _is_contacting:
		_is_contacting = false
		AudioManager.stop_contact()


func _calculate_effectiveness(distance: float) -> float:
	if distance > max_distance:
		return 0.0
	if distance <= optimal_distance:
		return 1.0

	var falloff_range: float = max_distance - optimal_distance
	var distance_past_optimal: float = distance - optimal_distance
	return 1.0 - (distance_past_optimal / falloff_range)


func _get_pressure_multiplier() -> float:
	var size_range: float = max_brush_size - min_brush_size
	var normalized: float = (_current_brush_size - min_brush_size) / size_range
	return lerp(2.0, 0.5, normalized)


func _hide_particles() -> void:
	if _laser_particles and _laser_particles.has_method("hide_particles"):
		_laser_particles.hide_particles()


func _show_particles(pos: Vector3, normal: Vector3) -> void:
	if _laser_particles and _laser_particles.has_method("show_particles"):
		_laser_particles.show_particles(pos, normal)
