extends Node
## Game Flow - manages intro and complete screens.

@export var job_name: String = "The Cube"
@export var cleanable_path: NodePath
@export var replay_camera_path: NodePath  # Add this

var _cleanable: Node3D
var _intro_ui: CanvasLayer
var _complete_ui: CanvasLayer


func _ready() -> void:
	if cleanable_path:
		_cleanable = get_node(cleanable_path)
	
	# Setup replay camera
	if replay_camera_path:
		var replay_cam: Camera3D = get_node(replay_camera_path)
		if replay_cam:
			ReplayRecorder.setup_camera(replay_cam)
	
	GameManager.set_job(_cleanable, job_name)
	GameManager.job_completed.connect(_on_job_completed)
	
	if _cleanable and _cleanable.has_signal("object_completed"):
		_cleanable.object_completed.connect(_on_object_completed)
	
	_show_intro()


func _show_intro() -> void:
	var intro_script := preload("res://ui/job_intro_ui.gd")
	_intro_ui = CanvasLayer.new()
	_intro_ui.set_script(intro_script)
	add_child(_intro_ui)


func _on_object_completed() -> void:
	GameManager.complete_job()


func _on_job_completed(stats: Dictionary) -> void:
	_show_complete(stats)


func _show_complete(stats: Dictionary) -> void:
	var complete_script := preload("res://ui/job_complete_ui.gd")
	_complete_ui = CanvasLayer.new()
	_complete_ui.set_script(complete_script)
	add_child(_complete_ui)
	_complete_ui.show_results(stats)
