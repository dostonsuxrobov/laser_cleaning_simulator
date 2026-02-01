extends CanvasLayer
## Job intro screen - shows job name and start button.

signal start_pressed

var _panel: PanelContainer
var _title_label: Label
var _subtitle_label: Label
var _start_button: Button


func _ready() -> void:
	_setup_ui()
	
	# Pause game during intro
	get_tree().paused = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	
	# Release mouse for UI interaction
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _setup_ui() -> void:
	# Dark overlay
	var overlay := ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.7)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)
	
	# Center container
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	
	# Panel
	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.1, 0.95)
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.content_margin_left = 60
	style.content_margin_right = 60
	style.content_margin_top = 40
	style.content_margin_bottom = 40
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)
	
	# VBox
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 20)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_panel.add_child(vbox)
	
	# Subtitle
	_subtitle_label = Label.new()
	_subtitle_label.text = "JOB"
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_label.add_theme_font_size_override("font_size", 16)
	_subtitle_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	vbox.add_child(_subtitle_label)
	
	# Title
	_title_label = Label.new()
	_title_label.text = GameManager.job_name
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 48)
	_title_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	vbox.add_child(_title_label)
	
	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(spacer)
	
	# Start button
	_start_button = Button.new()
	_start_button.text = "START"
	_start_button.custom_minimum_size = Vector2(200, 50)
	_start_button.add_theme_font_size_override("font_size", 20)
	_start_button.pressed.connect(_on_start_pressed)
	_start_button.focus_mode = Control.FOCUS_ALL
	vbox.add_child(_start_button)
	
	# Auto-focus the button
	_start_button.grab_focus()


func _on_start_pressed() -> void:
	# Capture mouse again for gameplay
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	get_tree().paused = false
	GameManager.start_job()
	emit_signal("start_pressed")
	queue_free()


func set_job_name(name: String) -> void:
	if _title_label:
		_title_label.text = name
