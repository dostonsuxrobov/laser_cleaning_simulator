extends Node
## Player settings, kept between sessions in user://settings.cfg.
## Autoload singleton. Change values through the setters, then call
## save_settings() once the player is done (the pause menu does this on close).

signal changed

const PATH: String = "user://settings.cfg"
const SENSITIVITY_MIN: float = 0.2
const SENSITIVITY_MAX: float = 3.0

## Multiplier on the player's base mouse sensitivity (1.0 = default).
var mouse_sensitivity: float = 1.0
## Master volume, linear 0..1.
var master_volume: float = 1.0


func _ready() -> void:
	load_settings()


func set_mouse_sensitivity(value: float) -> void:
	mouse_sensitivity = clampf(value, SENSITIVITY_MIN, SENSITIVITY_MAX)
	changed.emit()


func set_master_volume(value: float) -> void:
	master_volume = clampf(value, 0.0, 1.0)
	_apply_volume()
	changed.emit()


func _apply_volume() -> void:
	var bus: int = AudioServer.get_bus_index("Master")
	if bus < 0:
		return
	AudioServer.set_bus_mute(bus, master_volume <= 0.001)
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(master_volume, 0.001)))


func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(PATH) == OK:
		mouse_sensitivity = clampf(float(config.get_value("controls", "mouse_sensitivity", 1.0)), SENSITIVITY_MIN, SENSITIVITY_MAX)
		master_volume = clampf(float(config.get_value("audio", "master_volume", 1.0)), 0.0, 1.0)
	_apply_volume()


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("controls", "mouse_sensitivity", mouse_sensitivity)
	config.set_value("audio", "master_volume", master_volume)
	config.save(PATH)
