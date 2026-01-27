extends Node
## Handles all game audio. Autoload singleton.

@onready var _ding_player: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var _fanfare_player: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var _spray_player: AudioStreamPlayer = AudioStreamPlayer.new()

var ding_sound: AudioStream
var fanfare_sound: AudioStream
var spray_sound: AudioStream

@export var ding_delay: float = 0.3

var _spray_playing: bool = false


func _ready() -> void:
	_setup_players()
	_load_sounds()


func _setup_players() -> void:
	_ding_player.bus = "Master"
	_fanfare_player.bus = "Master"
	_spray_player.bus = "Master"
	
	add_child(_ding_player)
	add_child(_fanfare_player)
	add_child(_spray_player)


func _load_sounds() -> void:
	ding_sound = load("res://audio/ding.mp3")
	spray_sound = load("res://audio/process_audio.mp3")
	# fanfare_sound = load("res://audio/fanfare.mp3")
	
	if spray_sound:
		_spray_player.stream = spray_sound
		_spray_player.volume_db = -3.0


func play_ding() -> void:
	if ding_sound:
		var timer := get_tree().create_timer(ding_delay)
		timer.timeout.connect(_play_ding_now)


func _play_ding_now() -> void:
	_ding_player.stream = ding_sound
	_ding_player.pitch_scale = randf_range(0.95, 1.05)
	_ding_player.play()


func play_fanfare() -> void:
	if fanfare_sound:
		_fanfare_player.stream = fanfare_sound
		_fanfare_player.play()


func start_spray() -> void:
	if _spray_playing:
		return
	
	if spray_sound:
		_spray_player.play()
		_spray_playing = true


func stop_spray() -> void:
	if not _spray_playing:
		return
	
	_spray_player.stop()
	_spray_playing = false


func set_spray_pitch(pitch: float) -> void:
	_spray_player.pitch_scale = clamp(pitch, 0.5, 2.0)
