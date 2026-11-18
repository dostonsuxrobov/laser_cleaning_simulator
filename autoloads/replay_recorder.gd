extends Node
## Records gameplay from switching camera angles around the object.
## 1 SubViewport, 4 positions. Renders one frame per capture. Near-zero cost.

signal recording_started
signal recording_stopped

@export var max_frames: int = 600
@export var frame_interval: float = 1.5
@export var record_resolution: Vector2i = Vector2i(480, 270)
@export var camera_fov: float = 50.0

var is_recording: bool = false

# Each frame is {"img": Image} right after capture and becomes {"png": bytes}
# once a worker thread has compressed it (PNG encoding on the main thread
# caused a visible hitch every capture).
var _frames: Array[Dictionary] = []
var _frames_mutex := Mutex.new()
var _compress_tasks: Array[int] = []
var _timer: float = 0.0
var _base_frame_interval: float = 0.0

var _viewport: SubViewport
var _camera: Camera3D
var _camera_points: Array[Marker3D] = []
var _cleanable: Node3D
var _player: Node3D
var _is_capturing: bool = false


func _ready() -> void:
	_base_frame_interval = frame_interval


func setup(cleanable: Node3D, player: Node3D, camera_markers: Array[Marker3D]) -> void:
	_cleanable = cleanable
	_player = player
	_camera_points = camera_markers

	_setup_viewport()


func _setup_viewport() -> void:
	if _viewport:
		_viewport.queue_free()

	_viewport = SubViewport.new()
	_viewport.size = record_resolution
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.transparent_bg = false
	_viewport.world_3d = get_viewport().world_3d
	add_child(_viewport)

	_camera = Camera3D.new()
	_camera.fov = camera_fov
	_viewport.add_child(_camera)

	print("Replay viewport ready (%dx%d)" % [record_resolution.x, record_resolution.y])


func start_recording() -> void:
	if _camera_points.is_empty():
		push_warning("No camera markers set!")
		return

	_frames_mutex.lock()
	_frames = []
	_frames_mutex.unlock()
	frame_interval = _base_frame_interval
	is_recording = true
	_timer = 0.0

	_capture_frame()

	emit_signal("recording_started")
	print("Replay recording started")


func stop_recording() -> void:
	if not is_recording:
		return

	is_recording = false
	_capture_frame()

	emit_signal("recording_stopped")
	print("Replay recording stopped. Frames: ", _frames.size())


func _process(delta: float) -> void:
	if not is_recording:
		return

	_timer += delta
	if _timer >= frame_interval:
		_timer = 0.0
		_capture_frame()


func _capture_frame() -> void:
	if _is_capturing:
		return

	if _frames.size() >= max_frames:
		_thin_frames()

	if not _viewport or not _camera or not _cleanable:
		return

	_is_capturing = true

	# Move camera to best angle
	_camera.global_transform = _pick_camera_angle()

	# Render one frame
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

	# Wait for it to actually render
	await RenderingServer.frame_post_draw

	var img := _viewport.get_texture().get_image()
	if img:
		var frame: Dictionary = {"img": img}
		_frames_mutex.lock()
		_frames.append(frame)
		_frames_mutex.unlock()
		_collect_finished_tasks()
		_compress_tasks.append(WorkerThreadPool.add_task(_compress_frame.bind(frame)))

	# Back to idle
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_is_capturing = false


## Every pool task has to be collected once it is done.
func _collect_finished_tasks() -> void:
	var still_running: Array[int] = []
	for task: int in _compress_tasks:
		if WorkerThreadPool.is_task_completed(task):
			WorkerThreadPool.wait_for_task_completion(task)
		else:
			still_running.append(task)
	_compress_tasks = still_running


## Never let a worker outlive this node (quitting right after a capture).
func _exit_tree() -> void:
	for task: int in _compress_tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_compress_tasks.clear()


## Worker thread: swap the raw image for its PNG bytes.
func _compress_frame(frame: Dictionary) -> void:
	var img: Image = frame.get("img")
	if not img:
		return
	var png: PackedByteArray = img.save_png_to_buffer()
	_frames_mutex.lock()
	frame["png"] = png
	frame.erase("img")
	_frames_mutex.unlock()


func _pick_camera_angle() -> Transform3D:
	if _camera_points.is_empty() or not _player or not _cleanable:
		return Transform3D.IDENTITY

	var cleanable_center: Vector3 = _cleanable.global_position
	var player_pos: Vector3 = _player.global_position
	var player_dir: Vector3 = (player_pos - cleanable_center).normalized()

	# Find marker on same side as the player
	var best_marker: Marker3D = _camera_points[0]
	var best_dot: float = -INF

	for marker: Marker3D in _camera_points:
		var marker_dir: Vector3 = (marker.global_position - cleanable_center).normalized()
		var dot: float = player_dir.dot(marker_dir)
		if dot > best_dot:
			best_dot = dot
			best_marker = marker

	# Use marker position, always look at the object
	var t := Transform3D()
	t.origin = best_marker.global_position
	t = t.looking_at(cleanable_center, Vector3.UP)
	return t


func _thin_frames() -> void:
	_frames_mutex.lock()
	var new_frames: Array[Dictionary] = []
	for i: int in range(0, _frames.size(), 2):
		new_frames.append(_frames[i])
	_frames = new_frames
	_frames_mutex.unlock()
	frame_interval *= 2


func get_frame(index: int) -> Image:
	if index < 0 or index >= _frames.size():
		return null

	_frames_mutex.lock()
	var frame: Dictionary = _frames[index]
	var raw: Image = frame.get("img")
	var png: PackedByteArray = frame.get("png", PackedByteArray())
	_frames_mutex.unlock()

	if raw:
		return raw  # not compressed yet
	if png.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(png) != OK:
		return null
	return img


func get_frame_count() -> int:
	return _frames.size()


func clear() -> void:
	_frames_mutex.lock()
	_frames = []
	_frames_mutex.unlock()
	is_recording = false
