extends Node
## Game Manager - handles game flow and state.

signal job_started
signal job_completed(stats: Dictionary)

enum State { INTRO, PLAYING, COMPLETED }

var current_state: State = State.INTRO
var before_screenshot: Image
var after_screenshot: Image
var job_start_time: float = 0.0
var job_name: String = "The Cube"

var _current_cleanable: Node3D


func set_job(cleanable: Node3D, name: String) -> void:
	_current_cleanable = cleanable
	job_name = name


func start_job() -> void:
	current_state = State.PLAYING
	job_start_time = Time.get_ticks_msec() / 1000.0
	
	# Start replay recording
	ReplayRecorder.start_recording()
	
	# Capture before screenshot
	before_screenshot = await _capture_screenshot()
	
	emit_signal("job_started")


func complete_job() -> void:
	if current_state == State.COMPLETED:
		return
	
	current_state = State.COMPLETED
	
	# Stop replay recording
	ReplayRecorder.stop_recording()
	
	# Capture after screenshot
	after_screenshot = await _capture_screenshot()
	
	var elapsed: float = (Time.get_ticks_msec() / 1000.0) - job_start_time
	
	var stats := {
		"time": elapsed,
		"job_name": job_name
	}
	
	emit_signal("job_completed", stats)


func restart_job() -> void:
	ReplayRecorder.clear()
	get_tree().reload_current_scene()


func _capture_screenshot() -> Image:
	await RenderingServer.frame_post_draw
	var viewport := get_viewport()
	var img := viewport.get_texture().get_image()
	return img
