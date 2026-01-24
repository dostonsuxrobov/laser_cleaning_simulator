extends CanvasLayer
## Applies green night-vision overlay when dirt vision is active.

@onready var _overlay: ColorRect = $Overlay
var _material: ShaderMaterial


func _ready() -> void:
	_material = _overlay.material as ShaderMaterial
	DirtVision.dirt_vision_changed.connect(_on_dirt_vision_changed)
	_material.set_shader_parameter("enabled", false)


func _on_dirt_vision_changed(enabled: bool) -> void:
	_material.set_shader_parameter("enabled", enabled)