extends Node3D
## Laser impact - subtle light only, no distracting visuals.

var _light: OmniLight3D
var _time: float = 0.0

@export_group("Light")
@export_range(0.5, 5.0, 0.1) var light_energy: float = 1.5
@export_range(0.1, 1.0, 0.1) var light_range: float = 0.3


func _ready() -> void:
	_setup_light()
	visible = false


func _setup_light() -> void:
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.7, 0.4)
	_light.light_energy = light_energy
	_light.omni_range = light_range
	_light.omni_attenuation = 1.5
	add_child(_light)


func _process(delta: float) -> void:
	if not visible:
		return
	
	_time += delta * 50.0
	var flicker: float = 0.8 + randf() * 0.4
	_light.light_energy = light_energy * flicker
	_light.omni_range = light_range


func show_impact(hit_position: Vector3, normal: Vector3) -> void:
	global_position = hit_position + normal * 0.01
	visible = true


func hide_impact() -> void:
	visible = false
