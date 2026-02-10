extends Node
## Game Flow - manages game start and complete screen.

@export var job_name: String = "The Cube"
@export var cleanable_path: NodePath

var _cleanable: Node3D
var _complete_ui: CanvasLayer
var _pause_menu: CanvasLayer

const MAX_WAIT_FRAMES: int = 10


func _ready() -> void:
	_wait_for_cleanable()


func _wait_for_cleanable(attempts: int = 0) -> void:
	if cleanable_path:
		_cleanable = get_node_or_null(cleanable_path)

	if not _cleanable:
		_cleanable = _find_cleanable()

	if _cleanable:
		_initialize()
		return

	if attempts >= MAX_WAIT_FRAMES:
		push_error("Cleanable not found after %d frames!" % MAX_WAIT_FRAMES)
		return

	await get_tree().process_frame
	_wait_for_cleanable(attempts + 1)


func _initialize() -> void:
	var player := _find_player()
	var markers := _find_camera_markers()
	ReplayRecorder.setup(_cleanable, player, markers)

	GameManager.set_job(_cleanable, job_name)
	GameManager.job_completed.connect(_on_job_completed)

	var pause_script := preload("res://ui/pause_menu.gd")
	_pause_menu = CanvasLayer.new()
	_pause_menu.set_script(pause_script)
	add_child(_pause_menu)

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	GameManager.start_job()


func _find_cleanable() -> Node3D:
	var cleanables := get_tree().get_nodes_in_group("cleanable")
	if cleanables.size() > 0:
		return cleanables[0] as Node3D
	return null


func _find_player() -> Node3D:
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		return players[0] as Node3D
	return null


func _find_camera_markers() -> Array[Marker3D]:
	var markers: Array[Marker3D] = []
	for node: Node in get_tree().get_nodes_in_group("replay_camera_point"):
		if node is Marker3D:
			markers.append(node)
	return markers


func _on_job_completed(stats: Dictionary) -> void:
	_show_complete(stats)


func _show_complete(stats: Dictionary) -> void:
	var complete_script := preload("res://ui/job_complete_ui.gd")
	_complete_ui = CanvasLayer.new()
	_complete_ui.set_script(complete_script)
	add_child(_complete_ui)
	_complete_ui.show_results(stats)
