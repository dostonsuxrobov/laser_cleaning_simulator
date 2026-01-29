extends CanvasLayer
## Progress UI - shows target zone name and progress.

var _zone_label: Label
var _progress_label: Label
var _container: HBoxContainer

var _target_cleanable: Node3D
var _display_progress: float = 0.0
var _target_progress: float = 0.0
var _has_target: bool = false
var _sprayer: Node3D


func _ready() -> void:
	_setup_ui()
	_find_sprayer()


func _setup_ui() -> void:
	# Container for zone info (top right)
	_container = HBoxContainer.new()
	_container.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_container.position = Vector2(-200, 20)
	_container.add_theme_constant_override("separation", 8)
	add_child(_container)
	
	# Zone name label
	_zone_label = Label.new()
	_zone_label.text = ""
	_zone_label.add_theme_font_size_override("font_size", 28)
	_zone_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	_zone_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.7))
	_zone_label.add_theme_constant_override("shadow_offset_x", 2)
	_zone_label.add_theme_constant_override("shadow_offset_y", 2)
	_container.add_child(_zone_label)
	
	# Progress label
	_progress_label = Label.new()
	_progress_label.text = ""
	_progress_label.add_theme_font_size_override("font_size", 28)
	_progress_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_progress_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.7))
	_progress_label.add_theme_constant_override("shadow_offset_x", 2)
	_progress_label.add_theme_constant_override("shadow_offset_y", 2)
	_container.add_child(_progress_label)
	
	_container.visible = false


func _find_sprayer() -> void:
	await get_tree().process_frame
	
	# Find sprayer in player
	_sprayer = _find_node_with_signal(get_tree().root, "target_changed")
	
	if _sprayer:
		_sprayer.target_changed.connect(_on_target_changed)
		_sprayer.target_lost.connect(_on_target_lost)


func _find_node_with_signal(node: Node, signal_name: String) -> Node:
	if node.has_signal(signal_name):
		return node
	for child in node.get_children():
		var result := _find_node_with_signal(child, signal_name)
		if result:
			return result
	return null


func _on_target_changed(zone_name: String, progress: float, completed: bool) -> void:
	_has_target = true
	_target_progress = progress if not completed else 1.0
	_zone_label.text = zone_name + ":"
	_container.visible = true
	
	if completed:
		_zone_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	else:
		_zone_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))


func _on_target_lost() -> void:
	_has_target = false
	_container.visible = false


func _process(delta: float) -> void:
	if not _has_target:
		return
	
	# Smooth progress animation
	_display_progress = lerp(_display_progress, _target_progress, delta * 15.0)
	
	var percent: int = int(_display_progress * 100.0)
	_progress_label.text = "%d%%" % percent
	
	# Color based on progress
	if _display_progress >= 1.0:
		_progress_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	elif _display_progress >= 0.5:
		_progress_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.5))
	else:
		_progress_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
