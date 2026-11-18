extends Node
## Game Manager - handles game flow and state.

signal job_started
signal job_completed(stats: Dictionary)

enum State { INTRO, PLAYING, COMPLETED }

var current_state: State = State.INTRO
var job_start_time: float = 0.0
var job_name: String = "The Cube"

var _current_cleanable: Node3D


func set_job(cleanable: Node3D, job_title: String) -> void:
	_current_cleanable = cleanable
	job_name = job_title


func start_job() -> void:
	current_state = State.PLAYING
	job_start_time = Time.get_ticks_msec() / 1000.0
	ReplayRecorder.start_recording()
	emit_signal("job_started")


func complete_job() -> void:
	if current_state == State.COMPLETED:
		return
	
	current_state = State.COMPLETED
	ReplayRecorder.stop_recording()
	
	var elapsed: float = (Time.get_ticks_msec() / 1000.0) - job_start_time
	
	var stats := {
		"time": elapsed,
		"job_name": job_name
	}
	
	emit_signal("job_completed", stats)


func restart_job() -> void:
	current_state = State.INTRO
	job_start_time = 0.0
	ReplayRecorder.clear()
	AudioManager.stop_contact()
	get_tree().reload_current_scene()
