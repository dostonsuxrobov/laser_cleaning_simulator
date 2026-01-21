extends Node3D
## Flash effect when zone completes.

var _light: OmniLight3D
var _tween: Tween


func _ready() -> void:
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 1.0, 1.0)
	_light.light_energy = 0.0
	_light.omni_range = 3.0
	_light.omni_attenuation = 1.0
	add_child(_light)


func flash(world_position: Vector3) -> void:
	global_position = world_position
	
	if _tween:
		_tween.kill()
	
	_tween = create_tween()
	_light.light_energy = 8.0
	_tween.tween_property(_light, "light_energy", 0.0, 0.4).set_ease(Tween.EASE_OUT)
