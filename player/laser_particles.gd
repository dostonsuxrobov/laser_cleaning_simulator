extends Node3D
## Laser impact particles - configurable sparks and debris.

@export_group("Sparks")
@export var sparks_enabled: bool = true
@export var sparks_amount: int = 32
@export_range(0.1, 2.0, 0.1) var sparks_lifetime: float = 0.4
@export_range(1.0, 20.0, 0.5) var sparks_speed_min: float = 3.0
@export_range(1.0, 20.0, 0.5) var sparks_speed_max: float = 8.0
@export_range(0.01, 0.2, 0.01) var sparks_size_min: float = 0.03
@export_range(0.01, 0.2, 0.01) var sparks_size_max: float = 0.08
@export_range(10.0, 90.0, 5.0) var sparks_spread: float = 50.0
@export var sparks_color_start: Color = Color(1.0, 0.9, 0.5, 1.0)
@export var sparks_color_end: Color = Color(1.0, 0.3, 0.0, 0.0)
@export_range(1.0, 10.0, 0.5) var sparks_glow: float = 4.0

@export_group("Debris")
@export var debris_enabled: bool = true
@export var debris_amount: int = 24
@export_range(0.1, 3.0, 0.1) var debris_lifetime: float = 1.0
@export_range(0.1, 5.0, 0.1) var debris_speed_min: float = 0.5
@export_range(0.1, 5.0, 0.1) var debris_speed_max: float = 2.0
@export_range(0.01, 0.1, 0.005) var debris_size_min: float = 0.015
@export_range(0.01, 0.1, 0.005) var debris_size_max: float = 0.04
@export_range(10.0, 90.0, 5.0) var debris_spread: float = 40.0
@export var debris_color_start: Color = Color(0.5, 0.25, 0.1, 1.0)
@export var debris_color_end: Color = Color(0.3, 0.15, 0.05, 0.0)
@export_range(0.0, 20.0, 1.0) var debris_gravity: float = 10.0

var _sparks: GPUParticles3D
var _debris: GPUParticles3D
var _is_active: bool = false


func _ready() -> void:
	_setup_sparks()
	_setup_debris()


func _setup_sparks() -> void:
	_sparks = GPUParticles3D.new()
	_sparks.emitting = false
	_sparks.one_shot = false
	add_child(_sparks)
	_update_sparks()


func _setup_debris() -> void:
	_debris = GPUParticles3D.new()
	_debris.emitting = false
	_debris.one_shot = false
	add_child(_debris)
	_update_debris()


func _update_sparks() -> void:
	_sparks.amount = sparks_amount
	_sparks.lifetime = sparks_lifetime
	_sparks.explosiveness = 0.1
	
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = sparks_spread
	mat.initial_velocity_min = sparks_speed_min
	mat.initial_velocity_max = sparks_speed_max
	mat.gravity = Vector3(0, -12, 0)
	mat.scale_min = sparks_size_min
	mat.scale_max = sparks_size_max
	
	var gradient := Gradient.new()
	gradient.set_color(0, sparks_color_start)
	gradient.set_color(1, sparks_color_end)
	var gradient_tex := GradientTexture1D.new()
	gradient_tex.gradient = gradient
	mat.color_ramp = gradient_tex
	
	_sparks.process_material = mat
	
	# Mesh
	var mesh := SphereMesh.new()
	mesh.radius = 0.02
	mesh.height = 0.04
	_sparks.draw_pass_1 = mesh
	
	# Glowing material
	var mesh_mat := StandardMaterial3D.new()
	mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_mat.albedo_color = sparks_color_start
	mesh_mat.emission_enabled = true
	mesh_mat.emission = sparks_color_start
	mesh_mat.emission_energy_multiplier = sparks_glow
	mesh_mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mesh_mat)


func _update_debris() -> void:
	_debris.amount = debris_amount
	_debris.lifetime = debris_lifetime
	_debris.explosiveness = 0.0
	
	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = debris_spread
	mat.initial_velocity_min = debris_speed_min
	mat.initial_velocity_max = debris_speed_max
	mat.gravity = Vector3(0, -debris_gravity, 0)
	mat.scale_min = debris_size_min
	mat.scale_max = debris_size_max
	mat.angular_velocity_min = -360.0
	mat.angular_velocity_max = 360.0
	
	var gradient := Gradient.new()
	gradient.set_color(0, debris_color_start)
	gradient.set_color(1, debris_color_end)
	var gradient_tex := GradientTexture1D.new()
	gradient_tex.gradient = gradient
	mat.color_ramp = gradient_tex
	
	_debris.process_material = mat
	
	# Flat flake mesh
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.03, 0.008, 0.03)
	_debris.draw_pass_1 = mesh
	
	# Rust material
	var mesh_mat := StandardMaterial3D.new()
	mesh_mat.albedo_color = debris_color_start
	mesh_mat.roughness = 1.0
	mesh_mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mesh_mat)


func show_particles(pos: Vector3, normal: Vector3) -> void:
	global_position = pos
	
	if sparks_enabled:
		var sparks_mat := _sparks.process_material as ParticleProcessMaterial
		if sparks_mat:
			sparks_mat.direction = normal
		_sparks.global_position = pos
		if not _sparks.emitting:
			_sparks.emitting = true
	
	if debris_enabled:
		var debris_mat := _debris.process_material as ParticleProcessMaterial
		if debris_mat:
			debris_mat.direction = normal
		_debris.global_position = pos
		if not _debris.emitting:
			_debris.emitting = true
	
	_is_active = true


func hide_particles() -> void:
	if _is_active:
		_is_active = false
		_sparks.emitting = false
		_debris.emitting = false


## Call this to apply Inspector changes at runtime
func refresh() -> void:
	_update_sparks()
	_update_debris()
