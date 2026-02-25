extends CanvasLayer
## Shows one-time gameplay hints. Each dismisses when the player performs the action.

static var _already_shown: bool = false

var _label: Label
var _icon: TextureRect
var _panel: PanelContainer
var _current_index: int = -1
var _is_active: bool = false
var _tween: Tween

var _hints: Array[Dictionary] = []

const ICON_SIZE := Vector2(28, 28)


func _ready() -> void:
	if _already_shown:
		queue_free()
		return
	_already_shown = true

	_define_hints()
	_setup_ui()

	var t := create_tween()
	t.tween_callback(_show_next).set_delay(2.0)


func _define_hints() -> void:
	_hints = [
		{
			"text": "Fire Laser",
			"icon": "res://ui/left_click.png",
			"type": "mouse_button",
			"button": MOUSE_BUTTON_LEFT,
		},
		{
			"text": "Toggle Laser",
			"icon": "res://ui/right_click.png",
			"type": "mouse_button",
			"button": MOUSE_BUTTON_RIGHT,
		},
		{
			"text": "Brush Size",
			"icon": "res://ui/mouse_scroll.png",
			"type": "mouse_scroll",
		},
		{
			"text": "Dirt Vision",
			"icon": "res://ui/Q_key.png",
			"type": "action",
			"actions": ["dirt_vision"],
		},
		{
			"text": "Pause / Finish Job",
			"icon": "res://ui/esc_key.png",
			"type": "action",
			"actions": ["ui_cancel"],
		},
	]

func _setup_ui() -> void:
	var anchor := Control.new()
	anchor.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	anchor.offset_top = -100
	anchor.offset_bottom = -60
	add_child(anchor)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	anchor.add_child(center)

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.55)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_panel.add_child(hbox)

	_icon = TextureRect.new()
	_icon.custom_minimum_size = ICON_SIZE
	_icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.visible = false
	hbox.add_child(_icon)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.85))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hbox.add_child(_label)

	_panel.modulate = Color(1, 1, 1, 0)


func _input(event: InputEvent) -> void:
	if not _is_active:
		return

	if _current_index < 0 or _current_index >= _hints.size():
		return

	if _check_dismiss(event):
		_dismiss_current()


func _check_dismiss(event: InputEvent) -> bool:
	var hint: Dictionary = _hints[_current_index]

	match hint["type"]:
		"action":
			for action: String in hint["actions"]:
				if event.is_action_pressed(action):
					return true
		"mouse_button":
			if event is InputEventMouseButton:
				if event.button_index == hint["button"] and event.pressed:
					return true
		"mouse_scroll":
			if event is InputEventMouseButton:
				if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
					return true
				if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
					return true

	return false


func _show_next() -> void:
	_current_index += 1

	if _current_index >= _hints.size():
		_finish()
		return

	var hint: Dictionary = _hints[_current_index]
	_label.text = hint["text"]

	var icon_path: String = hint["icon"]
	if icon_path != "":
		var tex := load(icon_path) as Texture2D
		if tex:
			_icon.texture = tex
			_icon.visible = true
		else:
			_icon.visible = false
	else:
		_icon.visible = false

	_is_active = true

	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate", Color(1, 1, 1, 1), 0.3)


func _dismiss_current() -> void:
	_is_active = false

	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate", Color(1, 1, 1, 0), 0.25)
	_tween.tween_callback(_show_next).set_delay(1.2)


func _finish() -> void:
	_is_active = false

	_kill_tween()
	_tween = create_tween()
	_tween.tween_property(_panel, "modulate", Color(1, 1, 1, 0), 0.3)
	_tween.tween_callback(queue_free).set_delay(0.5)


func _kill_tween() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
		_tween = null
