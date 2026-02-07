extends CanvasLayer
## Progress UI - dual ring progress indicator.
## No zone: single ring with overall % in center.
## Zone targeted: outer + inner ring, zone name + % in center.

var _container: Control
var _background: Control
var _rings: Control
var _center_label: Label
var _center_percent: Label

var _overall_progress: float = 0.0
var _display_overall: float = 0.0
var _zone_progress: float = 0.0
var _display_zone: float = 0.0
var _has_zone_target: bool = false
var _zone_completed: bool = false
var _is_job_finished: bool = false
var _current_zone_name: String = ""

var _sprayer: Node3D
var _cleanable: Node3D

const OUTER_RADIUS: float = 52.0
const OUTER_THICKNESS: float = 5.0
const INNER_RADIUS: float = 43.0
const INNER_THICKNESS: float = 4.0

const RING_COLOR: Color = Color(1.0, 1.0, 1.0, 0.9)
const RING_BG_COLOR: Color = Color(1.0, 1.0, 1.0, 0.1)
const COMPLETE_COLOR: Color = Color(0.3, 1.0, 0.3, 1.0)
const BG_COLOR: Color = Color(0.0, 0.0, 0.0, 0.75)
const LABEL_DIM: Color = Color(0.6, 0.6, 0.6)
const LABEL_BRIGHT: Color = Color(1.0, 1.0, 1.0)
const WIDGET_SIZE: float = 130.0


func _ready() -> void:
	_setup_ui()
	_find_sprayer()
	_find_cleanable()
	GameManager.job_completed.connect(_on_job_completed)


func _on_job_completed(_stats: Dictionary) -> void:
	_is_job_finished = true
	_container.visible = false


func _setup_ui() -> void:
	_container = Control.new()
	_container.custom_minimum_size = Vector2(WIDGET_SIZE, WIDGET_SIZE)
	_container.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_container.position = Vector2(-WIDGET_SIZE - 20, 20)
	add_child(_container)
	
	_background = Control.new()
	_background.custom_minimum_size = Vector2(WIDGET_SIZE, WIDGET_SIZE)
	_background.draw.connect(_draw_background)
	_container.add_child(_background)
	
	_rings = Control.new()
	_rings.custom_minimum_size = Vector2(WIDGET_SIZE, WIDGET_SIZE)
	_rings.draw.connect(_draw_rings)
	_container.add_child(_rings)
	
	_center_label = Label.new()
	_center_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_center_label.add_theme_font_size_override("font_size", 11)
	_center_label.add_theme_color_override("font_color", LABEL_DIM)
	_center_label.text = "OVERALL"
	_center_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center_label.position.y = -10
	_container.add_child(_center_label)
	
	_center_percent = Label.new()
	_center_percent.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center_percent.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_center_percent.add_theme_font_size_override("font_size", 22)
	_center_percent.add_theme_color_override("font_color", LABEL_BRIGHT)
	_center_percent.text = "0%"
	_center_percent.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center_percent.position.y = 8
	_container.add_child(_center_percent)


func _draw_background() -> void:
	var center := Vector2(WIDGET_SIZE, WIDGET_SIZE) / 2.0
	_background.draw_circle(center, OUTER_RADIUS + 8, BG_COLOR)


func _draw_rings() -> void:
	var center := Vector2(WIDGET_SIZE, WIDGET_SIZE) / 2.0
	
	if _has_zone_target:
		_draw_arc_ring(center, OUTER_RADIUS, 0.0, 1.0, RING_BG_COLOR, OUTER_THICKNESS)
		if _display_overall > 0.001:
			var color: Color = COMPLETE_COLOR if _display_overall >= 0.99 else RING_COLOR
			_draw_arc_ring(center, OUTER_RADIUS, 0.0, _display_overall, color, OUTER_THICKNESS)
		
		_draw_arc_ring(center, INNER_RADIUS, 0.0, 1.0, RING_BG_COLOR, INNER_THICKNESS)
		if _display_zone > 0.001:
			var color: Color = COMPLETE_COLOR if _zone_completed else RING_COLOR
			_draw_arc_ring(center, INNER_RADIUS, 0.0, _display_zone, color, INNER_THICKNESS)
	else:
		_draw_arc_ring(center, OUTER_RADIUS, 0.0, 1.0, RING_BG_COLOR, OUTER_THICKNESS)
		if _display_overall > 0.001:
			var color: Color = COMPLETE_COLOR if _display_overall >= 0.99 else RING_COLOR
			_draw_arc_ring(center, OUTER_RADIUS, 0.0, _display_overall, color, OUTER_THICKNESS)


func _draw_arc_ring(center: Vector2, radius: float, start_pct: float, end_pct: float, color: Color, thickness: float) -> void:
	var start_angle: float = -PI / 2.0 + start_pct * TAU
	var end_angle: float = -PI / 2.0 + end_pct * TAU
	
	var point_count: int = int(64 * abs(end_pct - start_pct)) + 8
	point_count = max(point_count, 4)
	
	var points := PackedVector2Array()
	var colors := PackedColorArray()
	
	for i: int in range(point_count + 1):
		var angle: float = start_angle + (end_angle - start_angle) * float(i) / float(point_count)
		points.append(center + Vector2(cos(angle), sin(angle)) * (radius + thickness / 2.0))
		colors.append(color)
	
	for i: int in range(point_count, -1, -1):
		var angle: float = start_angle + (end_angle - start_angle) * float(i) / float(point_count)
		points.append(center + Vector2(cos(angle), sin(angle)) * (radius - thickness / 2.0))
		colors.append(color)
	
	if points.size() >= 3:
		_rings.draw_polygon(points, colors)


func _find_sprayer() -> void:
	await get_tree().process_frame
	_sprayer = _find_node_with_signal(get_tree().root, "target_changed")
	if _sprayer:
		_sprayer.target_changed.connect(_on_target_changed)
		_sprayer.target_lost.connect(_on_target_lost)


func _find_cleanable() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var cleanables: Array[Node] = get_tree().get_nodes_in_group("cleanable")
	if cleanables.size() > 0:
		_cleanable = cleanables[0] as Node3D


func _find_node_with_signal(node: Node, signal_name: String) -> Node:
	if node.has_signal(signal_name):
		return node
	for child: Node in node.get_children():
		var result: Node = _find_node_with_signal(child, signal_name)
		if result:
			return result
	return null


func _on_target_changed(zone_name: String, progress: float, completed: bool) -> void:
	if _is_job_finished:
		return
	_has_zone_target = true
	_zone_completed = completed or progress >= 0.95
	_zone_progress = 1.0 if _zone_completed else progress
	_current_zone_name = zone_name


func _on_target_lost() -> void:
	_has_zone_target = false


func _process(delta: float) -> void:
	if _is_job_finished:
		return
	
	if _cleanable and _cleanable.has_method("get_total_progress"):
		_overall_progress = _cleanable.get_total_progress()
	
	_display_overall = lerp(_display_overall, _overall_progress, delta * 10.0)
	if abs(_display_overall - _overall_progress) < 0.003:
		_display_overall = _overall_progress
	
	if _has_zone_target:
		_display_zone = lerp(_display_zone, _zone_progress, delta * 12.0)
		if abs(_display_zone - _zone_progress) < 0.005:
			_display_zone = _zone_progress
	else:
		_display_zone = lerp(_display_zone, 0.0, delta * 8.0)
	
	if _has_zone_target:
		_center_label.text = _current_zone_name
		var zone_pct: int = 100 if _zone_completed else int(_display_zone * 100.0)
		_center_percent.text = "%d%%" % zone_pct
		
		if _zone_completed:
			_center_label.add_theme_color_override("font_color", COMPLETE_COLOR)
			_center_percent.add_theme_color_override("font_color", COMPLETE_COLOR)
		else:
			_center_label.add_theme_color_override("font_color", LABEL_DIM)
			_center_percent.add_theme_color_override("font_color", LABEL_BRIGHT)
	else:
		_center_label.text = "OVERALL"
		var overall_pct: int = int(_display_overall * 100.0)
		if _display_overall >= 0.99:
			overall_pct = 100
		_center_percent.text = "%d%%" % overall_pct
		
		if _display_overall >= 0.99:
			_center_label.add_theme_color_override("font_color", COMPLETE_COLOR)
			_center_percent.add_theme_color_override("font_color", COMPLETE_COLOR)
		else:
			_center_label.add_theme_color_override("font_color", LABEL_DIM)
			_center_percent.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	
	_rings.queue_redraw()
