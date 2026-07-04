extends Node3D
## Laser impact - projects subtle circular decal onto surfaces with light.

var _light: OmniLight3D
var _decal: Decal
var _decal_texture: ImageTexture
var _camera: Camera3D

var _display_size: float = 0.2
var _target_size: float = 0.2
var _punch: float = 0.0
var _last_brush_radius: float = -1.0
var _is_firing: bool = false

const TEX_SIZE: int = 128
# The ring is drawn at 0.4 of the texture, so ring diameter = 0.8 * decal size.
# Scaling by 2.5 makes the visible ring match the cleaned world diameter exactly.
const RING_SCALE: float = 2.5
const PUNCH_AMOUNT: float = 0.04
const LERP_SPEED: float = 14.0
const PUNCH_DECAY: float = 10.0
const DECAL_DEPTH: float = 1.0

@export_group("Light")
@export_range(0.5, 5.0, 0.1) var light_energy: float = 1.5
@export_range(0.1, 1.0, 0.1) var light_range: float = 0.3

@export_group("Decal")
@export var decal_emission_energy: float = 1.0
@export var decal_modulate: Color = Color(1.0, 1.0, 1.0, 0.4)


func _ready() -> void:
	_camera = get_viewport().get_camera_3d()
	_setup_light()
	_decal_texture = _generate_circle_texture()
	_setup_decal()
	visible = false


func _setup_light() -> void:
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.7, 0.4)
	_light.light_energy = light_energy
	_light.omni_range = light_range
	_light.omni_attenuation = 1.5
	_light.visible = false
	add_child(_light)


func _setup_decal() -> void:
	_decal = Decal.new()
	_decal.texture_emission = _decal_texture
	_decal.emission_energy = decal_emission_energy
	_decal.modulate = decal_modulate
	_decal.size = Vector3(_display_size, DECAL_DEPTH, _display_size)
	_decal.upper_fade = 0.0
	_decal.lower_fade = 0.0
	add_child(_decal)


func _generate_circle_texture() -> ImageTexture:
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var center: float = TEX_SIZE / 2.0
	var radius: float = TEX_SIZE * 0.4
	var thickness: float = 1.5
	var col := Color(1, 1, 1, 0.6)

	for y: int in range(TEX_SIZE):
		for x: int in range(TEX_SIZE):
			var dx: float = x - center
			var dy: float = y - center
			var dist: float = sqrt(dx * dx + dy * dy)

			if abs(dist - radius) <= thickness:
				img.set_pixel(x, y, col)

	return ImageTexture.create_from_image(img)


func _process(delta: float) -> void:
	if not visible:
		return

	_display_size = lerp(_display_size, _target_size + _punch, delta * LERP_SPEED)
	_punch = lerp(_punch, 0.0, delta * PUNCH_DECAY)
	if abs(_punch) < 0.001:
		_punch = 0.0

	_decal.size = Vector3(_display_size, DECAL_DEPTH, _display_size)

	if _is_firing:
		var flicker: float = 0.8 + randf() * 0.4
		_light.light_energy = light_energy * flicker
		_light.visible = true
	else:
		_light.visible = false


func show_impact(hit_position: Vector3, normal: Vector3, brush_radius: float = 0.075) -> void:
	global_position = hit_position + normal * 0.005

	_orient_decal_to_camera(normal)

	_target_size = brush_radius * RING_SCALE

	if _last_brush_radius >= 0.0 and absf(brush_radius - _last_brush_radius) > 0.0001:
		_punch = PUNCH_AMOUNT
	_last_brush_radius = brush_radius

	visible = true


func set_firing(firing: bool) -> void:
	_is_firing = firing


func _orient_decal_to_camera(_normal: Vector3) -> void:
	if not _camera:
		_camera = get_viewport().get_camera_3d()
	if not _camera:
		return

	var cam_forward: Vector3 = -_camera.global_basis.z
	var cam_right: Vector3 = _camera.global_basis.x
	var cam_up: Vector3 = _camera.global_basis.y

	_decal.global_basis = Basis(cam_right, cam_forward, cam_up)


func hide_impact() -> void:
	visible = false
	_is_firing = false
