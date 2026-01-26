extends Node
## Handles all game audio. Autoload singleton.

# UI sounds (non-positional)
@onready var _ding_player: AudioStreamPlayer = AudioStreamPlayer.new()
@onready var _fanfare_player: AudioStreamPlayer = AudioStreamPlayer.new()

# Spray sound (will be attached to laser tool)
var spray_sound: AudioStream

# Preloaded sounds
var ding_sound: AudioStream
var fanfare_sound: AudioStream

# Settings
@export var ding_delay: float = 0.3  # 300ms delay per research


func _ready() -> void:
	_setup_players()
	_load_sounds()


func _setup_players() -> void:
	_ding_player.bus = "SFX"
	_fanfare_player.bus = "SFX"
	add_child(_ding_player)
	add_child(_fanfare_player)


func _load_sounds() -> void:
	ding_sound = load("res://audio/ding.mp3")
	# Add these when you have the files:
	# fanfare_sound = load("res://audio/fanfare.mp3")
	# spray_sound = load("res://audio/spray_loop.mp3")


func play_ding() -> void:
	if ding_sound:
		# Delay for stronger psychological impact (per research)
		var timer := get_tree().create_timer(ding_delay)
		timer.timeout.connect(_play_ding_now)


func _play_ding_now() -> void:
	_ding_player.stream = ding_sound
	_ding_player.pitch_scale = randf_range(0.95, 1.05)  # Slight variation
	_ding_player.play()


func play_fanfare() -> void:
	if fanfare_sound:
		_fanfare_player.stream = fanfare_sound
		_fanfare_player.play()
