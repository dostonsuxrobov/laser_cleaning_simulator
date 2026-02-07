extends Node
## Records gameplay from a fixed camera for replay.
## Frames stored as compressed PNG bytes to avoid RAM blowup.

signal recording_started
signal recording_stopped

@export var max_frames: int = 600
@export var frame_interval: float = 0.3
@export var record_resolution: Vector2i = Vector2i(480, 270)

var is_recording: bool = false

var _frames: Array[PackedByteArray] = []
var _timer: float = 0.0
var _base_frame_interval: float = 0.0
var _viewport: SubViewport
var _camera: Camera3D
var _replay_camera: Camera3D


func _ready() -> void:
	_base_frame_interval = frame_interval


func setup_camera(camera: Camera3D) -> void:
	_replay_camera = camera
	
	if _viewport:
		_viewport.queue_free()
	
	_viewport = SubViewport.new()
	_viewport.size = record_resolution
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.transparent_bg = false
	add_child(_viewport)
	
	_camera = Camera3D.new()
	_camera.fov = _replay_camera.fov
	_viewport.add_child(_camera)
	
	print("Replay camera setup complete")


func start_recording() -> void:
	if not _replay_camera:
		push_warning("No replay camera set!")
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
	
	if not _replay_camera:
		return
	
	if _camera and _replay_camera:
		_camera.global_transform = _replay_camera.global_transform
		_camera.fov = _replay_camera.fov
	
	_timer += delta
	
	if _timer >= frame_interval:
		_timer = 0.0
		_capture_frame()


func _capture_frame() -> void:
	if _frames.size() >= max_frames:
		_thin_frames()
	
	if not _viewport:
		return
	
	var img := _viewport.get_texture().get_image()
	if img:
		_frames.append(img.save_png_to_buffer())


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
