extends CanvasLayer
## Applies green night-vision overlay when dirt vision is active.
## Sits below the HUD layers, so only the 3D view is tinted.

@onready var _overlay: ColorRect = $Overlay
var _material: ShaderMaterial


func _ready() -> void:
	_material = _overlay.material as ShaderMaterial
	DirtVision.dirt_vision_changed.connect(_on_dirt_vision_changed)
	_on_dirt_vision_changed(DirtVision.enabled)


func _on_dirt_vision_changed(enabled: bool) -> void:
	_material.set_shader_parameter("enabled", enabled)
	# Hidden while off: no screen copy, no chance of altering the normal view.
	_overlay.visible = enabled
