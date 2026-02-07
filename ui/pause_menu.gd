extends CanvasLayer
## Pause menu - shows zone progress, overall progress, and actions.
## When overall > 97%, ESC triggers win instead.

const WIN_THRESHOLD: float = 0.97

var _is_open: bool = false
var _is_finished: bool = false
var _cleanable: Node3D

var _overlay: ColorRect
var _panel: PanelContainer
var _zone_list: VBoxContainer
var _overall_bar: Control
var _overall_label: Label

const BAR_WIDTH: float = 280.0
const BAR_HEIGHT: float = 8.0
const BAR_BG: Color = Color(0.2, 0.2, 0.2, 1.0)
const BAR_FILL: Color = Color(1.0, 1.0, 1.0, 0.9)
const BAR_COMPLETE: Color = Color(0.3, 1.0, 0.3, 1.0)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_find_cleanable()
	GameManager.job_completed.connect(_on_job_completed)


func _on_job_completed(_stats: Dictionary) -> void:
	_is_finished = true
	if _is_open:
		_close()


func _find_cleanable() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var cleanables: Array[Node] = get_tree().get_nodes_in_group("cleanable")
	if cleanables.size() > 0:
		_cleanable = cleanables[0] as Node3D


func _input(event: InputEvent) -> void:
	if _is_finished:
		return
	
	if event.is_action_pressed("ui_cancel"):
		if _is_open:
			_close()
		else:
			_try_open()
		get_viewport().set_input_as_handled()


func _try_open() -> void:
	# Check win condition
	var progress: float = 0.0
	if _cleanable and _cleanable.has_method("get_total_progress"):
		progress = _cleanable.get_total_progress()
	
	if progress >= WIN_THRESHOLD:
		# Win! Trigger end screen directly
		GameManager.complete_job()
		return
	
	_open()


func _open() -> void:
	_is_open = true
	get_tree().paused = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_build_ui()


func _close() -> void:
	_is_open = false
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	if _overlay:
		_overlay.queue_free()
		_overlay = null
	if _panel:
		_panel.queue_free()
		_panel = null


func _build_ui() -> void:
	# Dark overlay
	_overlay = ColorRect.new()
	_overlay.color = Color(0.0, 0.0, 0.0, 0.7)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)
	
	# Center container
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)
	
	# Panel
	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.08, 0.95)
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.content_margin_left = 40
	style.content_margin_right = 40
	style.content_margin_top = 32
	style.content_margin_bottom = 32
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)
	
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	_panel.add_child(vbox)
	
	# Title
	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	vbox.add_child(title)
	
	# Separator
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 8)
	vbox.add_child(sep)
	
	# Zone progress list
	_zone_list = VBoxContainer.new()
	_zone_list.add_theme_constant_override("separation", 10)
	vbox.add_child(_zone_list)
	
	_populate_zones()
	
	# Separator before overall
	var sep2 := HSeparator.new()
	sep2.add_theme_constant_override("separation", 8)
	vbox.add_child(sep2)
	
	# Overall progress
	var overall_row := _create_progress_row("OVERALL", 0.0, true)
	vbox.add_child(overall_row)
	
	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)
	
	# Buttons
	var btn_box := HBoxContainer.new()
	btn_box.add_theme_constant_override("separation", 12)
	btn_box.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_box)
	
	btn_box.add_child(_create_button("CONTINUE", _on_continue, Color(0.2, 0.2, 0.2)))
	btn_box.add_child(_create_button("RESTART", _on_restart, Color(0.15, 0.15, 0.15)))
	btn_box.add_child(_create_button("QUIT", _on_quit, Color(0.15, 0.15, 0.15)))
	
	# Update bars with real data
	_update_progress()


func _populate_zones() -> void:
	if not _cleanable or not _cleanable.has_method("get_zones_state"):
		return
	
	var zones: Dictionary = _cleanable.get_zones_state()
	
	for zone_key: String in zones:
		var zone: Dictionary = zones[zone_key]
		var row: Control = _create_progress_row(zone["name"], zone["progress"], false, zone["completed"])
		_zone_list.add_child(row)


func _create_progress_row(label_text: String, progress: float, is_overall: bool, completed: bool = false) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	
	# Label
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(100, 0)
	label.add_theme_font_size_override("font_size", 14 if is_overall else 13)
	
	if completed or (is_overall and progress >= 0.99):
		label.add_theme_color_override("font_color", BAR_COMPLETE)
	else:
		label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7) if not is_overall else Color(1.0, 1.0, 1.0))
	
	row.add_child(label)
	
	# Progress bar (custom drawn)
	var bar := Control.new()
	bar.custom_minimum_size = Vector2(BAR_WIDTH, BAR_HEIGHT + 4)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var bar_progress: float = progress
	var bar_completed: bool = completed
	var bar_is_overall: bool = is_overall
	
	bar.draw.connect(func() -> void:
		var rect := Rect2(0, 2, BAR_WIDTH, BAR_HEIGHT)
		bar.draw_rect(rect, BAR_BG)
		
		if bar_progress > 0.001:
			var fill_rect := Rect2(0, 2, BAR_WIDTH * bar_progress, BAR_HEIGHT)
			var fill_color: Color = BAR_COMPLETE if (bar_completed or (bar_is_overall and bar_progress >= 0.99)) else BAR_FILL
			bar.draw_rect(fill_rect, fill_color)
	)
	
	row.add_child(bar)
	
	# Percent text
	var pct := Label.new()
	var pct_val: int = 100 if (completed or (is_overall and progress >= 0.99)) else int(progress * 100.0)
	pct.text = "%d%%" % pct_val
	pct.custom_minimum_size = Vector2(40, 0)
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pct.add_theme_font_size_override("font_size", 13)
	
	if completed or (is_overall and progress >= 0.99):
		pct.add_theme_color_override("font_color", BAR_COMPLETE)
	else:
		pct.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	
	row.add_child(pct)
	
	if is_overall:
		_overall_label = pct
		_overall_bar = bar
	
	return row


func _update_progress() -> void:
	if not _cleanable or not _cleanable.has_method("get_total_progress"):
		return
	
	var total: float = _cleanable.get_total_progress()
	var pct_val: int = 100 if total >= 0.99 else int(total * 100.0)
	
	if _overall_label:
		_overall_label.text = "%d%%" % pct_val
	if _overall_bar:
		_overall_bar.queue_redraw()


func _create_button(text: String, callback: Callable, bg_color: Color) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(120, 40)
	btn.add_theme_font_size_override("font_size", 14)
	btn.pressed.connect(callback)
	
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	btn.add_theme_stylebox_override("normal", style)
	
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = bg_color.lightened(0.15)
	btn.add_theme_stylebox_override("hover", hover)
	
	var pressed := style.duplicate() as StyleBoxFlat
	pressed.bg_color = bg_color.darkened(0.1)
	btn.add_theme_stylebox_override("pressed", pressed)
	
	btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	
	return btn


func _on_continue() -> void:
	_close()


func _on_restart() -> void:
	_close()
	GameManager.restart_job()


func _on_quit() -> void:
	get_tree().quit()
