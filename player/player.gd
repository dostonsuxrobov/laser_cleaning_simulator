extends CharacterBody3D
## Player controller - handles movement, jump, and sit states.

@export var walk_speed: float = 5.0
@export var jump_force: float = 5.0
@export var gravity: float = 15.0
@export var mouse_sensitivity: float = 0.002

var is_walking: bool = false
var is_jumping: bool = false
var is_sitting: bool = false
var move_direction: Vector3 = Vector3.ZERO

var _standing_height: float = 1.8
var _sitting_height: float = 0.9

@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var camera_pivot: Node3D = $CameraPivot


func _ready() -> void:
	add_to_group("player")
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sensitivity)
		camera_pivot.rotate_x(-event.relative.y * mouse_sensitivity)
		camera_pivot.rotation.x = clamp(camera_pivot.rotation.x, -1.5, 1.5)


func _physics_process(delta: float) -> void:
	_handle_gravity(delta)
	_handle_sit()
	_handle_jump()
	_handle_movement()

	move_and_slide()

	_update_states()


func _handle_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta


func _handle_sit() -> void:
	var want_sit: bool = Input.is_action_pressed("sit") and is_on_floor()

	if want_sit and not is_sitting:
		var shape: CapsuleShape3D = collision_shape.shape
		shape.height = _sitting_height
		collision_shape.position.y = -0.45
		camera_pivot.position.y = 0.1
		is_sitting = true
	elif not want_sit and is_sitting:
		var shape: CapsuleShape3D = collision_shape.shape
		shape.height = _standing_height
		collision_shape.position.y = 0.0
		camera_pivot.position.y = 0.6
		is_sitting = false


func _handle_jump() -> void:
	if Input.is_action_just_pressed("jump") and is_on_floor() and not is_sitting:
		velocity.y = jump_force


func _handle_movement() -> void:
	var input_dir := Vector2.ZERO
	input_dir.x = Input.get_axis("move_left", "move_right")
	input_dir.y = Input.get_axis("move_forward", "move_backward")

	move_direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	var speed: float = walk_speed * (0.5 if is_sitting else 1.0)

	if move_direction:
		velocity.x = move_direction.x * speed
		velocity.z = move_direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)


func _update_states() -> void:
	is_walking = move_direction.length() > 0.1 and is_on_floor()
	is_jumping = not is_on_floor()
