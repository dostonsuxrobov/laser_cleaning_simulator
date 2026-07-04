extends Node
## Manages a SubViewport for GPU-based dirt painting.
## Single responsibility: apply world-space brush passes and image draws to the
## dirt mask, expose the result. Position/normal lookup textures come from
## SurfaceBaker via set_surface_maps().

var _viewport: SubViewport
var _brush_material: ShaderMaterial
var _texture_size: int
var _initialized: bool = false
var _maps_ready: bool = false


func setup(texture_size: int, rust_resistance: float, metal_resistance: float) -> void:
	_texture_size = texture_size
	_create_viewport()
	_create_brush_material(rust_resistance, metal_resistance)
	fill_black()
	_initialized = true


func _create_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(_texture_size, _texture_size)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	_viewport.transparent_bg = false
	_viewport.disable_3d = true
	# Float target: sub-1/255 laser strengths still accumulate instead of rounding to zero
	_viewport.use_hdr_2d = true
	add_child(_viewport)


func _create_brush_material(rust_resistance: float, metal_resistance: float) -> void:
	var shader := load("res://cleanable/world_brush.gdshader") as Shader
	_brush_material = ShaderMaterial.new()
	_brush_material.shader = shader
	_brush_material.set_shader_parameter("rust_resistance", rust_resistance)
	_brush_material.set_shader_parameter("metal_resistance", metal_resistance)


## Baked lookup textures (body-local position + normal per texel).
func set_surface_maps(position_tex: Texture2D, normal_tex: Texture2D) -> void:
	_brush_material.set_shader_parameter("position_map", position_tex)
	_brush_material.set_shader_parameter("normal_map", normal_tex)
	_maps_ready = true


## Clean along the world-space segment from->to (body-local coords).
## Each call adds one transient full-texture brush pass this frame, so several
## stamps can accumulate in a single render.
func paint_world(from: Vector3, to: Vector3, radius: float, dir: Vector3, strength: float) -> void:
	if not _initialized or not _maps_ready:
		return

	var mat := _brush_material.duplicate() as ShaderMaterial
	mat.set_shader_parameter("brush_from", from)
	mat.set_shader_parameter("brush_to", to)
	mat.set_shader_parameter("beam_dir", dir)
	mat.set_shader_parameter("brush_radius", radius)
	mat.set_shader_parameter("strength", strength)

	var rect := ColorRect.new()
	rect.size = Vector2(_texture_size, _texture_size)
	rect.material = mat
	_viewport.add_child(rect)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.frame_post_draw.connect(rect.queue_free, CONNECT_ONE_SHOT)


## Draw an image over the dirt mask (alpha-blended). Optionally clear to black
## first, in the same render, to fully replace the current state.
func draw_image(img: Image, clear_first: bool = false) -> void:
	if not _initialized:
		return
	if clear_first:
		_add_transient_fill()

	var scaled := img
	if img.get_size() != Vector2i(_texture_size, _texture_size):
		scaled = img.duplicate()
		scaled.resize(_texture_size, _texture_size, Image.INTERPOLATE_NEAREST)

	var sprite := Sprite2D.new()
	sprite.texture = ImageTexture.create_from_image(scaled)
	sprite.centered = false
	_viewport.add_child(sprite)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.frame_post_draw.connect(sprite.queue_free, CONNECT_ONE_SHOT)


func fill_black() -> void:
	_add_transient_fill()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _add_transient_fill() -> void:
	var fill := ColorRect.new()
	fill.color = Color(0.0, 0.0, 0.0, 1.0)
	fill.size = Vector2(_texture_size, _texture_size)
	_viewport.add_child(fill)
	RenderingServer.frame_post_draw.connect(fill.queue_free, CONNECT_ONE_SHOT)


func get_viewport_texture() -> ViewportTexture:
	if not _viewport:
		return null
	return _viewport.get_texture()


func get_snapshot() -> Image:
	if not _viewport:
		return null
	return _viewport.get_texture().get_image()


func debug_save(path: String) -> void:
	var img := get_snapshot()
	if img:
		img.save_png(path)
		print("Viewport saved to: ", path)
