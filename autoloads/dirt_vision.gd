extends Node
## Global dirt vision state - toggle with Q.

signal dirt_vision_changed(enabled: bool)

var enabled: bool = false


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("dirt_vision"):
		enabled = not enabled
		emit_signal("dirt_vision_changed", enabled)
		print("Dirt Vision: ", "ON" if enabled else "OFF")