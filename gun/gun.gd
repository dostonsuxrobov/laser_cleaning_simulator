extends Node3D
## Gun sway controller - reacts to player movement states.
## Reads player state and applies appropriate visual feedback.

# Sway settings
@export var sway_amount: float = 0.02
@export var sway_speed: float = 5.0
@export var bob_amount: float = 0.03
@export var bob_speed: float = 10.0

# Jump/sit reaction
@export var jump_offset: Vector3 = Vector3(0, -0.1, 0.05)
@export var sit_offset: Vector3 = Vector3(0.05, -0.05, 0)

# Internal
var _base_position: Vector3
var _base_rotation: Vector3
var _bob_time: float = 0.0
var _player: CharacterBody3D


func _ready() -> void:
	_base_position = position
	_base_rotation = rotation
	_find_player()


func _find_player() -> void:
	# Wait one frame for player to register in group
	await get_tree().process_frame
	var players := get_tree().get_nodes_in_group("player")
	if players.size() > 0:
		_player = players[0] as CharacterBody3D
	else:
		push_warning("Gun: no node in 'player' group found")


func _process(delta: float) -> void:
	if not _player:
		return
	
	var target_pos := _base_position
	var target_rot := _base_rotation
	
	# Walking bob
	if _player.is_walking:
		_bob_time += delta * bob_speed
		target_pos.y += sin(_bob_time) * bob_amount
		target_pos.x += cos(_bob_time * 0.5) * bob_amount * 0.5
	else:
		_bob_time = 0.0
	
	# Jump reaction - gun dips down
	if _player.is_jumping:
		target_pos += jump_offset
		target_rot.x += 0.1
	
	# Sit reaction - gun tilts
	if _player.is_sitting:
		target_pos += sit_offset
		target_rot.z += 0.15
	
	# Mouse sway (subtle movement based on mouse input)
	var mouse_vel := Input.get_last_mouse_velocity() * 0.0001
	target_rot.y -= mouse_vel.x * sway_amount
	target_rot.x -= mouse_vel.y * sway_amount
	
	# Smooth interpolation
	position = position.lerp(target_pos, delta * sway_speed)
	rotation = rotation.lerp(target_rot, delta * sway_speed)
