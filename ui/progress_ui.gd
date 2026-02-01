extends CanvasLayer
## Progress UI - circular progress indicator for current zone.

var _container: Control
var _background: Control
var _progress_ring: Control
var _zone_label: Label
var _percent_label: Label

var _target_progress: float = 0.0
var _display_progress: float = 0.0
var _has_target: bool = false
var _is_completed: bool = false
var _sprayer: Node3D

# Settings
const RING_SIZE: float = 100.0
const RING_THICKNESS: float = 6.0
const RING_THICKNESS_COMPLETE: float = 3.0
const BG_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)
const RING_COLOR: Color = Color(1.0, 1.0, 1.0, 1.0)
const RING_COLOR_COMPLETE: Color = Color(0.3, 1.0, 0.3, 1.0)
const RING_BG_COLOR: Color = Color(1.0, 1.0, 1.0, 0.15)


func _ready() -> void:
	_setup_ui()
	_find_sprayer()


func _setup_ui() -> void:
	# Main container (top right)
	_container = Control.new()
	_container.custom_minimum_size = Vector2(RING_SIZE + 40, RING_SIZE + 40)
	_container.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_container.position = Vector2(-RING_SIZE - 60, 20)
	_container.visible = false
	add_child(_container)
	
	# Background circle
	_background = Control.new()
	_background.custom_minimum_size = Vector2(RING_SIZE + 40, RING_SIZE + 40)
	_background.draw.connect(_draw_background)
	_container.add_child(_background)
	
	# Progress ring
	_progress_ring = Control.new()
	_progress_ring.custom_minimum_size = Vector2(RING_SIZE + 40, RING_SIZE + 40)
	_progress_ring.draw.connect(_draw_progress_ring)
	_container.add_child(_progress_ring)
	
	# Zone name label
	_zone_label = Label.new()
	_zone_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zone_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_zone_label.add_theme_font_size_override("font_size", 14)
	_zone_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_zone_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_zone_label.position.y = -12
	_container.add_child(_zone_label)
	
	# Percent label
	_percent_label = Label.new()
	_percent_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_percent_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_percent_label.add_theme_font_size_override("font_size", 24)
	_percent_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_percent_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_percent_label.position.y = 10
	_container.add_child(_percent_label)


func _draw_background() -> void:
	var center := Vector2(RING_SIZE + 40, RING_SIZE + 40) / 2.0
	var radius := RING_SIZE / 2.0
	
	# Dark circle background
	_background.draw_circle(center, radius + 8, BG_COLOR)


func _draw_progress_ring() -> void:
	var center := Vector2(RING_SIZE + 40, RING_SIZE + 40) / 2.0
	var radius := RING_SIZE / 2.0
	
	var thickness := RING_THICKNESS_COMPLETE if _is_completed else RING_THICKNESS
	var color := RING_COLOR_COMPLETE if _is_completed else RING_COLOR
	
	# Background ring (subtle)
	_draw_arc_ring(_progress_ring, center, radius, 0.0, 1.0, RING_BG_COLOR, thickness)
	
	# Progress ring
	if _display_progress > 0.001:
		_draw_arc_ring(_progress_ring, center, radius, 0.0, _display_progress, color, thickness)


func _draw_arc_ring(control: Control, center: Vector2, radius: float, start_pct: float, end_pct: float, color: Color, thickness: float) -> void:
	var start_angle := -PI / 2.0 + start_pct * TAU
	var end_angle := -PI / 2.0 + end_pct * TAU
	
	var point_count := int(64 * abs(end_pct - start_pct)) + 8
	point_count = max(point_count, 4)
	
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	
	# Outer edge
	for i in range(point_count + 1):
		var angle := start_angle + (end_angle - start_angle) * float(i) / float(point_count)
		points.append(center + Vector2(cos(angle), sin(angle)) * (radius + thickness / 2.0))
		colors.append(color)
	
	# Inner edge (reverse order)
	for i in range(point_count, -1, -1):
		var angle := start_angle + (end_angle - start_angle) * float(i) / float(point_count)
		points.append(center + Vector2(cos(angle), sin(angle)) * (radius - thickness / 2.0))
		colors.append(color)
	
	if points.size() >= 3:
		control.draw_polygon(points, colors)


func _find_sprayer() -> void:
	await get_tree().process_frame
	
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
	_is_completed = completed or progress >= 0.95
	_target_progress = 1.0 if _is_completed else progress
	_zone_label.text = zone_name
	_container.visible = true
	
	# Update colors based on completion
	if _is_completed:
		_zone_label.add_theme_color_override("font_color", RING_COLOR_COMPLETE)
		_percent_label.add_theme_color_override("font_color", RING_COLOR_COMPLETE)
	else:
		_zone_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_percent_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))


func _on_target_lost() -> void:
	_has_target = false
	_container.visible = false


func _process(delta: float) -> void:
	if not _has_target:
		return
	
	# Smooth progress animation
	_display_progress = lerp(_display_progress, _target_progress, delta * 12.0)
	
	# Snap to target if close
	if abs(_display_progress - _target_progress) < 0.005:
		_display_progress = _target_progress
	
	# Update percent text
	var display_percent: int
	if _is_completed:
		display_percent = 100
	else:
		display_percent = int(_display_progress * 100.0)
	
	_percent_label.text = "%d%%" % display_percent
	
	# Redraw progress ring
	_progress_ring.queue_redraw()
