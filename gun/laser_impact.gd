extends Node3D
## Laser impact - flickering hot light where the beam lands.
## (The aiming ring itself is drawn by the cleanable's surface shader, using
## the exact beam the brush cleans with - see cleanable/dirt.gdshader.)

var _light: OmniLight3D
var _is_firing: bool = false

@export_group("Light")
@export_range(0.5, 5.0, 0.1) var light_energy: float = 1.5
@export_range(0.1, 1.0, 0.1) var light_range: float = 0.3
## Extra reach per metre of brush radius, so a wide beam lights a wide patch.
@export var light_range_per_radius: float = 2.0


func _ready() -> void:
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.7, 0.4)
	_light.light_energy = light_energy
	_light.omni_range = light_range
	_light.omni_attenuation = 1.5
	_light.visible = false
	add_child(_light)
	visible = false


func _process(_delta: float) -> void:
	if not visible:
		return

	if _is_firing:
		_light.light_energy = light_energy * (0.8 + randf() * 0.4)
		_light.visible = true
	else:
		_light.visible = false


func show_impact(hit_position: Vector3, normal: Vector3, brush_radius: float = 0.075) -> void:
	global_position = hit_position + normal * 0.03
	_light.omni_range = light_range + brush_radius * light_range_per_radius
	visible = true


func set_firing(firing: bool) -> void:
	_is_firing = firing


func hide_impact() -> void:
	visible = false
	_is_firing = false
