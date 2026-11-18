extends Node
## Owns the GPU dirt mask.
## Single responsibility: apply brush passes, fills and wipes to the mask and
## expose the result - both as a texture for the surface shader and as a small
## box-filtered "measure" image for cheap progress read-back.
##
## The mask is a float SubViewport that is never cleared. Every operation is a
## transient full-texture canvas item that lives for exactly one rendered frame.

const BRUSH_SHADER: Shader = preload("res://cleanable/world_brush.gdshader")
const FILL_SHADER: Shader = preload("res://cleanable/dirt_fill.gdshader")
const MEASURE_SHADER: Shader = preload("res://cleanable/dirt_measure.gdshader")

var _viewport: SubViewport
var _measure_viewport: SubViewport
var _measure_material: ShaderMaterial

var _mask_size: int = 1024
var _measure_size: int = 256
var _initialized: bool = false
var _maps_ready: bool = false

var _rust_resistance: float = 1.0
var _metal_resistance: float = 1.5
var _position_tex: Texture2D
var _normal_tex: Texture2D
var _zone_tex: Texture2D
var _zone_colors := PackedVector3Array()
var _zone_count: int = 0

# Brush passes are pooled: one ColorRect + material per stamp, reused each frame.
var _stamps: Array[ColorRect] = []
var _stamps_used: int = 0
# One-frame items (fills, wipes, image draws) are simply freed after drawing.
var _transients: Array[CanvasItem] = []


func setup(mask_size: int, measure_size: int, rust_resistance: float, metal_resistance: float) -> void:
	_mask_size = mask_size
	_measure_size = measure_size
	_rust_resistance = rust_resistance
	_metal_resistance = metal_resistance

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(_mask_size, _mask_size)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	_viewport.transparent_bg = false
	_viewport.disable_3d = true
	# Float target: sub-1/255 laser strengths still accumulate instead of rounding to zero
	_viewport.use_hdr_2d = true
	add_child(_viewport)

	_measure_viewport = SubViewport.new()
	_measure_viewport.size = Vector2i(_measure_size, _measure_size)
	_measure_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_measure_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_measure_viewport.transparent_bg = false
	_measure_viewport.disable_3d = true
	add_child(_measure_viewport)

	_measure_material = ShaderMaterial.new()
	_measure_material.shader = MEASURE_SHADER
	_measure_material.set_shader_parameter("dirt_mask", _viewport.get_texture())
	@warning_ignore("integer_division")
	_measure_material.set_shader_parameter("ratio", maxi(_mask_size / _measure_size, 1))
	var measure_rect := ColorRect.new()
	measure_rect.size = Vector2(_measure_size, _measure_size)
	measure_rect.material = _measure_material
	_measure_viewport.add_child(measure_rect)

	RenderingServer.frame_post_draw.connect(_on_frame_drawn)
	fill_black()
	_initialized = true


func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_frame_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_frame_drawn)


## Zone map + reference colors, shared with the surface shader's classification.
func set_zones(zone_tex: Texture2D, zone_colors: PackedVector3Array, zone_count: int) -> void:
	_zone_tex = zone_tex
	_zone_colors = zone_colors
	_zone_count = zone_count


## Baked lookup textures (body-local position + normal per mask texel).
func set_surface_maps(position_tex: Texture2D, normal_tex: Texture2D) -> void:
	_position_tex = position_tex
	_normal_tex = normal_tex
	for rect: ColorRect in _stamps:
		var mat := rect.material as ShaderMaterial
		mat.set_shader_parameter("position_map", position_tex)
		mat.set_shader_parameter("normal_map", normal_tex)
	_maps_ready = true


## Clean inside the laser beam swept from `from` to `to` (body-local axis
## points). Several stamps may be queued per rendered frame; they accumulate.
func paint_beam(from: Vector3, to: Vector3, dir: Vector3, radius: float, depth_front: float, depth_back: float, strength: float) -> void:
	if not _initialized or not _maps_ready:
		return

	var rect: ColorRect
	if _stamps_used < _stamps.size():
		rect = _stamps[_stamps_used]
	else:
		rect = _create_stamp()
		_stamps.append(rect)
	_stamps_used += 1

	var mat := rect.material as ShaderMaterial
	mat.set_shader_parameter("beam_from", from)
	mat.set_shader_parameter("beam_to", to)
	mat.set_shader_parameter("beam_dir", dir)
	mat.set_shader_parameter("brush_radius", radius)
	mat.set_shader_parameter("depth_front", depth_front)
	mat.set_shader_parameter("depth_back", depth_back)
	mat.set_shader_parameter("strength", strength)
	rect.visible = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _create_stamp() -> ColorRect:
	var mat := ShaderMaterial.new()
	mat.shader = BRUSH_SHADER
	mat.set_shader_parameter("rust_resistance", _rust_resistance)
	mat.set_shader_parameter("metal_resistance", _metal_resistance)
	mat.set_shader_parameter("position_map", _position_tex)
	mat.set_shader_parameter("normal_map", _normal_tex)

	var rect := ColorRect.new()
	rect.size = Vector2(_mask_size, _mask_size)
	rect.material = mat
	rect.visible = false
	_viewport.add_child(rect)
	return rect


## Reset the mask: every zone texel becomes fully dirty, the rest clean.
## With use_coverage, zone texels with no surface behind them stay clean.
func fill_zone_dirt(use_coverage: bool) -> void:
	if not _initialized:
		return
	_add_fill_pass(0, use_coverage and _maps_ready)


## Remove all remaining dirt of one zone (1-based id), at full mask resolution.
func wipe_zone(zone_id: int) -> void:
	if not _initialized or zone_id <= 0:
		return
	_add_fill_pass(zone_id, false)


func _add_fill_pass(wipe_zone_id: int, use_coverage: bool) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = FILL_SHADER
	mat.set_shader_parameter("zone_map", _zone_tex)
	mat.set_shader_parameter("zone_colors", _zone_colors)
	mat.set_shader_parameter("zone_count", _zone_count)
	mat.set_shader_parameter("wipe_zone", wipe_zone_id)
	mat.set_shader_parameter("use_coverage", use_coverage)
	if _position_tex:
		mat.set_shader_parameter("position_map", _position_tex)

	var rect := ColorRect.new()
	rect.size = Vector2(_mask_size, _mask_size)
	rect.material = mat
	_add_transient(rect)


## Draw an image over the dirt mask (alpha-blended). Optionally clear to black
## first, in the same render, to fully replace the current state.
func draw_image(img: Image, clear_first: bool = false) -> void:
	if not _initialized or not img:
		return
	if clear_first:
		_add_black_rect()

	var scaled := img
	if img.get_size() != Vector2i(_mask_size, _mask_size):
		scaled = img.duplicate()
		scaled.resize(_mask_size, _mask_size, Image.INTERPOLATE_NEAREST)

	var sprite := Sprite2D.new()
	sprite.texture = ImageTexture.create_from_image(scaled)
	sprite.centered = false
	_add_transient(sprite)


func fill_black() -> void:
	_add_black_rect()


func _add_black_rect() -> void:
	var fill := ColorRect.new()
	fill.color = Color(0.0, 0.0, 0.0, 1.0)
	fill.size = Vector2(_mask_size, _mask_size)
	_add_transient(fill)


func _add_transient(item: CanvasItem) -> void:
	_viewport.add_child(item)
	# Fills must land before this frame's brush stamps, never on top of them.
	_viewport.move_child(item, _transients.size())
	_transients.append(item)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## Everything queued this frame has now been drawn into the mask.
func _on_frame_drawn() -> void:
	if _stamps_used > 0:
		for i: int in range(_stamps_used):
			_stamps[i].visible = false
		_stamps_used = 0
	if not _transients.is_empty():
		for item: CanvasItem in _transients:
			item.queue_free()
		_transients.clear()


## Ask for a fresh measure image; it is valid after the next rendered frame.
func request_measure() -> void:
	if _measure_viewport:
		_measure_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## Progress grid: R = rust, G = base layer, each the exact average of the mask
## texels inside that cell. RGBA8, measure_size x measure_size.
func get_measure_image() -> Image:
	if not _measure_viewport:
		return null
	return _measure_viewport.get_texture().get_image()


func get_viewport_texture() -> ViewportTexture:
	if not _viewport:
		return null
	return _viewport.get_texture()


## Full-resolution mask read-back. Slow (float texture) - tests and debugging only.
func get_snapshot() -> Image:
	if not _viewport:
		return null
	return _viewport.get_texture().get_image()


func debug_save(path: String) -> void:
	var img := get_snapshot()
	if img:
		img.save_png(path)
		print("Viewport saved to: ", path)
