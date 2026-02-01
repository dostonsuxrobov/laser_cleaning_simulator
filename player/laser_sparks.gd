extends GPUParticles3D
## Sparks effect at laser impact point.

func _ready() -> void:
	emitting = false
	one_shot = false
	amount = 32
	lifetime = 0.3
	explosiveness = 0.2
	
	var mat := ParticleProcessMaterial.new()
	
	# Direction: spray outward from surface
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 60.0
	mat.initial_velocity_min = 3.0
	mat.initial_velocity_max = 6.0
	
	# Gravity pulls down
	mat.gravity = Vector3(0, -15, 0)
	
	# Size
	mat.scale_min = 0.02
	mat.scale_max = 0.05
	
	# Color: hot orange to yellow
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 0.8, 0.3, 1.0))
	gradient.set_color(1, Color(1.0, 0.3, 0.0, 0.0))
	var gradient_tex := GradientTexture1D.new()
	gradient_tex.gradient = gradient
	mat.color_ramp = gradient_tex
	
	# Emission color (bright)
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINT
	mat.color = Color(1.0, 0.7, 0.3, 1.0)
	
	process_material = mat
	
	# Simple mesh for particles
	var mesh := SphereMesh.new()
	mesh.radius = 0.015
	mesh.height = 0.03
	draw_pass_1 = mesh
	
	# Material with emission for glow
	var mesh_mat := StandardMaterial3D.new()
	mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_mat.albedo_color = Color(1.0, 0.8, 0.4)
	mesh_mat.emission_enabled = true
	mesh_mat.emission = Color(1.0, 0.6, 0.2)
	mesh_mat.emission_energy_multiplier = 3.0
	mesh_mat.vertex_color_use_as_albedo = true
	draw_pass_1.surface_set_material(0, mesh_mat)


func start(pos: Vector3, normal: Vector3) -> void:
	global_position = pos
	
	# Orient sparks to fly away from surface
	var mat := process_material as ParticleProcessMaterial
	mat.direction = normal
	
	emitting = true


func stop() -> void:
	emitting = false
