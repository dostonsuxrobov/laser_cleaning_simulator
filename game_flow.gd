extends Node
## Game Flow - manages game start and complete screen.

@export var job_name: String = "The Cube"
@export var cleanable_path: NodePath

var _cleanable: Node3D
var _complete_ui: CanvasLayer
var _pause_menu: CanvasLayer
var _initialized: bool = false

const POLL_INTERVAL: float = 0.5
const MAX_POLL_TIME: float = 30.0
var _poll_elapsed: float = 0.0


func _ready() -> void:
	_setup_pause_menu()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if cleanable_path:
		_cleanable = get_node_or_null(cleanable_path)

	if _cleanable:
		_initialize()
	else:
		set_process(true)


func _process(delta: float) -> void:
	if _initialized:
		set_process(false)
		return

	_poll_elapsed += delta

	_cleanable = _find_cleanable()

	if _cleanable:
		_initialize()
		set_process(false)
		return

	if _poll_elapsed >= MAX_POLL_TIME:
		push_warning("No cleanable found after %.0fs — running without one." % MAX_POLL_TIME)
		_initialize_without_cleanable()
		set_process(false)


func _initialize() -> void:
	if _initialized:
		return
	_initialized = true

	var player := _find_player()
	var markers := _find_camera_markers()
	ReplayRecorder.setup(_cleanable, player, markers)

	GameManager.set_job(_cleanable, job_name)
	GameManager.job_completed.connect(_on_job_completed)
	GameManager.start_job()


func _initialize_without_cleanable() -> void:
	if _initialized:
		return
	_initialized = true

	var player := _find_player()
	GameManager.set_job(null, job_name)
	GameManager.job_completed.connect(_on_job_completed)
	GameManager.start_job()


func _setup_pause_menu() -> void:
	var pause_script := preload("res://ui/pause_menu.gd")
	_pause_menu = CanvasLayer.new()
	_pause_menu.set_script(pause_script)
	add_child(_pause_menu)


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
	# Clean remaining dirt (matters for ESC shortcut path where zones aren't all individually done)
	if _cleanable and _cleanable.has_method("clean_all"):
		_cleanable.clean_all()
		await RenderingServer.frame_post_draw
	_show_complete(stats)


func _show_complete(stats: Dictionary) -> void:
	var complete_script := preload("res://ui/job_complete_ui.gd")
	_complete_ui = CanvasLayer.new()
	_complete_ui.set_script(complete_script)
	add_child(_complete_ui)
	_complete_ui.show_results(stats)
