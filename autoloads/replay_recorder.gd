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

var _frames: Array[PackedByteArray] = []
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

	_frames.clear()
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
		_frames.append(img.save_png_to_buffer())

	# Back to idle
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_is_capturing = false


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
	var new_frames: Array[PackedByteArray] = []
	for i: int in range(0, _frames.size(), 2):
		new_frames.append(_frames[i])
	_frames = new_frames
	frame_interval *= 2


func get_frame(index: int) -> Image:
	if index < 0 or index >= _frames.size():
		return null
	var img := Image.new()
	img.load_png_from_buffer(_frames[index])
	return img


func get_frame_count() -> int:
	return _frames.size()


func clear() -> void:
	_frames.clear()
	is_recording = false
