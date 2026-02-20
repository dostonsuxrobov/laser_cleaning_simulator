extends CenterContainer
## Minimal center dot - visible only when aiming at dirty surface.

@onready var _dot: ColorRect = $Dot

var _sprayer: Node3D


func _ready() -> void:
	_dot.modulate = Color(1, 1, 1, 0.0)
	_find_sprayer()


func _find_sprayer() -> void:
	await get_tree().process_frame
	var sprayers := get_tree().get_nodes_in_group("sprayer")
	if sprayers.size() > 0:
		_sprayer = sprayers[0] as Node3D
		_sprayer.hit_dirty_surface.connect(_on_hit_dirty_surface)


func _on_hit_dirty_surface(is_dirty: bool) -> void:
	_dot.modulate = Color(1, 1, 1, 0.4) if is_dirty else Color(1, 1, 1, 0.0)
