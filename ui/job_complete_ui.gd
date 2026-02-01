extends CanvasLayer
## Job complete screen - shows replay and stats.

const REPLAY_SPEED_MULTIPLIER: float = 3.0  # 3x speed

var _replay_rect: TextureRect
var _time_label: Label
var _title_label: Label
var _replay_progress: ProgressBar
var _replay_time_label: Label

var _replay_frames: Array[Image] = []
var _replay_index: int = 0
var _replay_speed: float = 1.0
var _replay_timer: float = 0.0
var _is_replaying: bool = false
var _replay_texture: ImageTexture
var _replay_duration: float = 0.0
var _actual_time: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func show_results(stats: Dictionary) -> void:
	_replay_frames = ReplayRecorder.get_frames()
	_actual_time = stats.get("time", 0.0)
	
	# Replay duration = actual time / 3
	_replay_duration = _actual_time / REPLAY_SPEED_MULTIPLIER
	_replay_duration = max(_replay_duration, 1.0)  # Minimum 1 second
	
	# Calculate FPS to fit all frames in replay duration
	if _replay_frames.size() > 0:
		_replay_speed = float(_replay_frames.size()) / _replay_duration
		_replay_speed = max(_replay_speed, 1.0)
	
	get_tree().paused = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	_setup_ui(stats)
	
	await get_tree().create_timer(0.5).timeout
	_start_replay()


func _setup_ui(stats: Dictionary) -> void:
	# Dark overlay
	var overlay := ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.9)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)
	
	# Main container
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	add_child(margin)
	
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(vbox)
	
	# Title
	_title_label = Label.new()
	_title_label.text = "JOB COMPLETE"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 42)
	_title_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	vbox.add_child(_title_label)
	
	# Job name
	var job_label := Label.new()
	job_label.text = stats.get("job_name", "Unknown")
	job_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	job_label.add_theme_font_size_override("font_size", 20)
	job_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(job_label)
	
	# Replay container
	var replay_container := CenterContainer.new()
	replay_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(replay_container)
	
	var replay_vbox := VBoxContainer.new()
	replay_vbox.add_theme_constant_override("separation", 8)
	replay_container.add_child(replay_vbox)
	
	# Replay label
	var replay_label := Label.new()
	replay_label.text = "TIMELAPSE (%.0fx SPEED)" % REPLAY_SPEED_MULTIPLIER
	replay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	replay_label.add_theme_font_size_override("font_size", 14)
	replay_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	replay_vbox.add_child(replay_label)
	
	# Replay panel
	var replay_panel := PanelContainer.new()
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.1, 0.1, 0.1, 1.0)
	panel_style.border_color = Color(0.3, 0.3, 0.3)
	panel_style.border_width_left = 2
	panel_style.border_width_right = 2
	panel_style.border_width_top = 2
	panel_style.border_width_bottom = 2
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	replay_panel.add_theme_stylebox_override("panel", panel_style)
	replay_vbox.add_child(replay_panel)
	
	# Replay texture
	_replay_rect = TextureRect.new()
	_replay_rect.custom_minimum_size = Vector2(640, 360)
	_replay_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_replay_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	replay_panel.add_child(_replay_rect)
	
	if _replay_frames.size() > 0:
		_replay_texture = ImageTexture.create_from_image(_replay_frames[0])
		_replay_rect.texture = _replay_texture
	
	# Progress bar with time
	var progress_hbox := HBoxContainer.new()
	progress_hbox.add_theme_constant_override("separation", 10)
	replay_vbox.add_child(progress_hbox)
	
	_replay_progress = ProgressBar.new()
	_replay_progress.custom_minimum_size = Vector2(560, 6)
	_replay_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_replay_progress.min_value = 0.0
	_replay_progress.max_value = 1.0
	_replay_progress.value = 0.0
	_replay_progress.show_percentage = false
	progress_hbox.add_child(_replay_progress)
	
	# Format replay duration for display
	var replay_min: int = int(_replay_duration) / 60
	var replay_sec: int = int(_replay_duration) % 60
	
	_replay_time_label = Label.new()
	_replay_time_label.text = "0:00 / %d:%02d" % [replay_min, replay_sec]
	_replay_time_label.add_theme_font_size_override("font_size", 12)
	_replay_time_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_replay_time_label.custom_minimum_size = Vector2(80, 0)
	progress_hbox.add_child(_replay_time_label)
	
	# Actual time
	var time_seconds: float = stats.get("time", 0.0)
	var minutes: int = int(time_seconds) / 60
	var seconds: int = int(time_seconds) % 60
	
	_time_label = Label.new()
	_time_label.text = "Time: %d:%02d" % [minutes, seconds]
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_time_label.add_theme_font_size_override("font_size", 24)
	_time_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	vbox.add_child(_time_label)
	
	# Buttons
	var buttons_hbox := HBoxContainer.new()
	buttons_hbox.add_theme_constant_override("separation", 20)
	buttons_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(buttons_hbox)
	
	var replay_btn := Button.new()
	replay_btn.text = "REPLAY"
	replay_btn.custom_minimum_size = Vector2(140, 45)
	replay_btn.add_theme_font_size_override("font_size", 16)
	replay_btn.pressed.connect(_on_replay_pressed)
	buttons_hbox.add_child(replay_btn)
	
	var restart_button := Button.new()
	restart_button.text = "PLAY AGAIN"
	restart_button.custom_minimum_size = Vector2(140, 45)
	restart_button.add_theme_font_size_override("font_size", 16)
	restart_button.pressed.connect(_on_restart_pressed)
	restart_button.focus_mode = Control.FOCUS_ALL
	buttons_hbox.add_child(restart_button)
	
	var quit_button := Button.new()
	quit_button.text = "QUIT"
	quit_button.custom_minimum_size = Vector2(140, 45)
	quit_button.add_theme_font_size_override("font_size", 16)
	quit_button.pressed.connect(_on_quit_pressed)
	buttons_hbox.add_child(quit_button)
	
	restart_button.grab_focus()


func _start_replay() -> void:
	if _replay_frames.size() == 0:
		return
	
	_replay_index = 0
	_replay_timer = 0.0
	_is_replaying = true


func _process(delta: float) -> void:
	if not _is_replaying:
		return
	
	if _replay_frames.size() == 0:
		return
	
	_replay_timer += delta
	
	var frame_duration: float = 1.0 / _replay_speed
	
	if _replay_timer >= frame_duration:
		_replay_timer = 0.0
		_replay_index += 1
		
		if _replay_index >= _replay_frames.size():
			_replay_index = _replay_frames.size() - 1
			_is_replaying = false
			_loop_replay()
		
		_update_replay_display()


func _loop_replay() -> void:
	await get_tree().create_timer(2.0).timeout
	_start_replay()


func _update_replay_display() -> void:
	if _replay_index < 0 or _replay_index >= _replay_frames.size():
		return
	
	var frame: Image = _replay_frames[_replay_index]
	
	if _replay_texture:
		_replay_texture.update(frame)
	
	# Progress
	var progress: float = float(_replay_index) / float(max(_replay_frames.size() - 1, 1))
	_replay_progress.value = progress
	
	# Time display
	var current_time: float = progress * _replay_duration
	var current_min: int = int(current_time) / 60
	var current_sec: int = int(current_time) % 60
	var total_min: int = int(_replay_duration) / 60
	var total_sec: int = int(_replay_duration) % 60
	_replay_time_label.text = "%d:%02d / %d:%02d" % [current_min, current_sec, total_min, total_sec]


func _on_replay_pressed() -> void:
	_start_replay()


func _on_restart_pressed() -> void:
	get_tree().paused = false
	GameManager.restart_job()


func _on_quit_pressed() -> void:
	get_tree().quit()
