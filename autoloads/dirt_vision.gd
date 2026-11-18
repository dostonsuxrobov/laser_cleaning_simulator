extends Node
## Global dirt vision state - toggle with Q.

signal dirt_vision_changed(enabled: bool)

var enabled: bool = false


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("dirt_vision"):
		set_enabled(not enabled)


## The one place the state changes, so every listener stays in sync.
func set_enabled(value: bool) -> void:
	if enabled == value:
		return
	enabled = value
	dirt_vision_changed.emit(enabled)
