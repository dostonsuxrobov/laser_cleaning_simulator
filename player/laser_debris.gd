extends GPUParticles3D
## Debris/rust flakes falling off when cleaning.

func _ready() -> void:
	emitting = false
	one_shot = false
	amount = 16
	lifetime = 0.8
	explosiveness = 0.0
	
	var mat := ParticleProcessMaterial.new()
	
	# Direction: mostly outward + up, then fall
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 45.0
	mat.initial_velocity_min = 0.5
	mat.initial_velocity_max = 1.5
	
	# Gravity
	mat.gravity = Vector3(0, -8, 0)
	
	# Size: small flakes
	mat.scale_min = 0.01
	mat.scale_max = 0.03
	
	# Rotation for tumbling
	mat.angular_velocity_min = -360.0
	mat.angular_velocity_max = 360.0
	
	# Color: rust brown to dark
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.5, 0.25, 0.1, 1.0))
	gradient.set_color(1, Color(0.3, 0.15, 0.05, 0.0))
	var gradient_tex := GradientTexture1D.new()
	gradient_tex.gradient = gradient
	mat.color_ramp = gradient_tex
	
	process_material = mat
	
	# Flat box mesh for flakes
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.02, 0.005, 0.02)
	draw_pass_1 = mesh
	
	# Rust colored material
	var mesh_mat := StandardMaterial3D.new()
	mesh_mat.albedo_color = Color(0.45, 0.22, 0.1)
	mesh_mat.roughness = 1.0
	mesh_mat.vertex_color_use_as_albedo = true
	draw_pass_1.surface_set_material(0, mesh_mat)


func start(pos: Vector3, normal: Vector3) -> void:
	global_position = pos
	
	var mat := process_material as ParticleProcessMaterial
	mat.direction = normal
	
	emitting = true


func stop() -> void:
	emitting = false
