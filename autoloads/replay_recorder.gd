extends Node
## Records gameplay from a fixed camera for replay.

signal recording_started
signal recording_stopped

@export var frame_interval: float = 0.2  # Capture every 0.2 seconds
@export var record_resolution: Vector2i = Vector2i(640, 360)

var is_recording: bool = false
var frames: Array[Image] = []

var _timer: float = 0.0
var _viewport: SubViewport
var _camera: Camera3D
var _replay_camera: Camera3D


func setup_camera(camera: Camera3D) -> void:
	_replay_camera = camera
	
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
	
	frames.clear()
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
	print("Replay recording stopped. Frames: ", frames.size())


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
	if not _viewport:
		return
	
	var img := _viewport.get_texture().get_image()
	if img:
		frames.append(img)


func get_frames() -> Array[Image]:
	return frames


func get_frame_count() -> int:
	return frames.size()


func clear() -> void:
	frames.clear()
	is_recording = false
