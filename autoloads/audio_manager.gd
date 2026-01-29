extends Node
## Handles all game audio. Autoload singleton.

@onready var _ding_player: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var _fanfare_player: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var _contact_player: AudioStreamPlayer = AudioStreamPlayer.new()

var ding_sound: AudioStream
var fanfare_sound: AudioStream
var contact_sound: AudioStream

@export var ding_delay: float = 0.3

var _contact_playing: bool = false


func _ready() -> void:
	_setup_players()
	_load_sounds()


func _setup_players() -> void:
	_ding_player.bus = "Master"
	_fanfare_player.bus = "Master"
	_contact_player.bus = "Master"
	
	add_child(_ding_player)
	add_child(_fanfare_player)
	add_child(_contact_player)


func _load_sounds() -> void:
	ding_sound = load("res://audio/ding.mp3")
	contact_sound = load("res://audio/cracle_contact.mp3")
	# fanfare_sound = load("res://audio/fanfare.mp3")
	
	if contact_sound:
		_contact_player.stream = contact_sound
		_contact_player.volume_db = -16.0


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


func start_contact() -> void:
	if _contact_playing:
		return
	
	if contact_sound:
		_contact_player.play()
		_contact_playing = true


func stop_contact() -> void:
	if not _contact_playing:
		return
	
	_contact_player.stop()
	_contact_playing = false
