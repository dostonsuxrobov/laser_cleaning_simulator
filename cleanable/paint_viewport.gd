extends Node
## Manages a SubViewport for GPU-based texture painting.
## Single responsibility: stamp brush at UV coordinates, expose the result.

var _viewport: SubViewport
var _brush: Sprite2D
var _brush_material: ShaderMaterial
var _texture_size: int
var _initialized: bool = false


func setup(texture_size: int, rust_resistance: float, metal_resistance: float) -> void:
	_texture_size = texture_size
	_create_viewport()
	_create_brush(rust_resistance, metal_resistance)
	_fill_initial_clean()
	_initialized = true


func _create_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(_texture_size, _texture_size)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	_viewport.transparent_bg = false
	_viewport.disable_3d = true
	add_child(_viewport)


func _fill_initial_clean() -> void:
	var fill := ColorRect.new()
	fill.color = Color(0.0, 0.0, 0.0, 1.0)
	fill.size = Vector2(_texture_size, _texture_size)
	_viewport.add_child(fill)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.frame_post_draw.connect(fill.queue_free, CONNECT_ONE_SHOT)


func _create_brush(rust_resistance: float, metal_resistance: float) -> void:
	var shader := load("res://cleanable/paint_brush.gdshader") as Shader
	_brush_material = ShaderMaterial.new()
	_brush_material.shader = shader
	_brush_material.set_shader_parameter("rust_resistance", rust_resistance)
	_brush_material.set_shader_parameter("metal_resistance", metal_resistance)

	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var tex := ImageTexture.create_from_image(img)

	_brush = Sprite2D.new()
	_brush.texture = tex
	_brush.material = _brush_material
	_brush.visible = false
	_viewport.add_child(_brush)


func fill_zone_dirt(zone_pixels: Dictionary, tex_size: int) -> void:
	_brush.visible = false
	var img := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 1))
	for pixel_key: int in zone_pixels:
		var x: int = pixel_key % tex_size
		var y: int = pixel_key / tex_size
		img.set_pixel(x, y, Color(1, 1, 0, 1))
	var tex := ImageTexture.create_from_image(img)
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.centered = false
	_viewport.add_child(sprite)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.frame_post_draw.connect(sprite.queue_free, CONNECT_ONE_SHOT)


func stamp(uv: Vector2, brush_size: int, strength: float) -> void:
	if not _initialized:
		return
	_brush.visible = true
	_brush.position = Vector2(uv.x * _texture_size, uv.y * _texture_size)
	_brush.scale = Vector2(brush_size, brush_size)
	_brush_material.set_shader_parameter("strength", strength)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func clear_zone(pixels: Array, tex_size: int) -> void:
	_brush.visible = false

	var img := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for pixel: Vector2i in pixels:
		img.set_pixel(pixel.x, pixel.y, Color(0, 0, 0, 1))

	var tex := ImageTexture.create_from_image(img)
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.centered = false
	_viewport.add_child(sprite)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.frame_post_draw.connect(sprite.queue_free, CONNECT_ONE_SHOT)


func clear_all() -> void:
	_brush.visible = false
	var fill := ColorRect.new()
	fill.color = Color(0.0, 0.0, 0.0, 1.0)
	fill.size = Vector2(_texture_size, _texture_size)
	_viewport.add_child(fill)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.frame_post_draw.connect(fill.queue_free, CONNECT_ONE_SHOT)


func restore_state(img: Image) -> void:
	_brush.visible = false

	var tex := ImageTexture.create_from_image(img)
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.centered = false
	_viewport.add_child(sprite)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.frame_post_draw.connect(sprite.queue_free, CONNECT_ONE_SHOT)


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
