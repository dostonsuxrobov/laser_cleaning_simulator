extends StaticBody3D
## Cleanable Mesh - laser-beam GPU painting with zone-based completion.
## Supports both simple meshes (direct child) and armature models (multiple meshes).
## Job: own the dirt mask, track zones, trigger victory when all zones are clean.
##
## How cleaning works:
##  1. At load, a worker thread rasterizes every face into UV space, producing a
##     per-texel map of body-local surface positions + normals (SurfaceBaker).
##  2. Each laser tick runs a brush pass over the dirt mask: a texel is cleaned
##     only if its baked 3D position lies inside the laser beam (a cylinder of
##     brush radius around the beam axis) and faces the beam.
##  3. The surface shader draws the aiming ring with the same beam test, so the
##     ring always outlines exactly what will be cleaned.
## This is independent of UV layout, texel density, and island boundaries.

# =============================================================================
# SIGNALS
# =============================================================================

signal zone_completed(zone_color: Color, world_position: Vector3)
signal object_completed
## Emitted once the surface bake finished and the laser can clean.
signal surface_ready

# =============================================================================
# EXPORTS
# =============================================================================

@export_group("Mesh")
@export var surface_index: int = 0

@export_group("Texture")
## Resolution of zone bookkeeping and progress tracking.
@export var texture_size: int = 256
## Resolution of the dirt mask + baked surface maps. Higher = finer brush edges.
## Must be a multiple of texture_size.
@export var paint_size: int = 1024
## How far (in mask texels) surface data grows past UV island edges.
@export_range(1, 16) var dilate_radius: int = 4
@export var zone_map: Texture2D

@export_group("Zone Names")
@export var zone_names: Dictionary = {}

@export_group("Cleaning Speed")
@export_range(0.1, 5.0, 0.1) var laser_power: float = 1.0
@export_range(0.1, 5.0, 0.1) var rust_resistance: float = 1.0
@export_range(0.1, 5.0, 0.1) var metal_resistance: float = 1.5

@export_group("Completion")
## Share of a zone's rust / base layer that must be removed before the zone
## counts as done (the last specks are then wiped automatically).
@export_range(0.8, 1.0, 0.01) var rust_complete_threshold: float = 0.97
@export_range(0.8, 1.0, 0.01) var metal_complete_threshold: float = 0.97
@export var flash_fade_speed: float = 3.0
@export var min_zone_pixels: int = 100

@export_group("Zone Discovery")
@export_range(0.3, 0.9, 0.05) var brightness_threshold: float = 0.5
@export_range(0.05, 0.5, 0.05) var seed_merge_distance: float = 0.15

@export_group("Dirt Vision")
## Highlight for dirt that still has rust on it / only the base layer left.
@export var vision_rust_color: Color = Color(1.0, 0.5, 0.12)
@export var vision_base_color: Color = Color(0.35, 0.65, 1.0)
@export_range(0.0, 1.0, 0.01) var vision_dirt_opacity: float = 0.9
## The see-through shell the object turns into.
@export var vision_ghost_color: Color = Color(0.75, 0.86, 1.0)
@export_range(0.0, 1.0, 0.01) var vision_ghost_opacity: float = 0.1
## How fast and how much the highlight breathes.
@export_range(0.0, 10.0, 0.1) var vision_pulse_speed: float = 2.5
@export_range(0.0, 0.5, 0.01) var vision_pulse_amount: float = 0.18

@export_group("Victory Animation")
@export var victory_animation_name: String = "victory_dance"

# =============================================================================
# PRIVATE STATE
# =============================================================================

const MAX_ZONES: int = 16
const PROGRESS_INTERVAL: float = 0.2
const STROKE_GAP_MS: int = 200
const MAX_SWEEP_RADII: float = 10.0
const DEFAULT_DEPTH_RADII: float = 3.0
const FACE_TIE_EPS: float = 0.003
# A face counts as badly unwrapped when its texture density is this many times
# the model's median AND it is this much more stretched one way than the other.
const STRETCH_LIMIT: float = 6.0
const STRETCH_ANISOTROPY: float = 6.0
const DIRT_EPSILON: float = 0.04
const XRAY_SHADER: Shader = preload("res://cleanable/dirt_xray.gdshader")

enum Measure { IDLE, WAIT_PAINT, WAIT_READBACK }

var _paint_viewport: Node
var _paint_dirty: bool = false
var _progress_timer: float = 0.0
var _victory_triggered: bool = false

var _materials: Array[ShaderMaterial] = []
var _mesh_instances: Array[MeshInstance3D] = []

# Dirt vision: per mesh instance, the material to swap in and a shadow-only
# stand-in (the see-through material casts no shadow of its own).
var _vision_slots: Array[Dictionary] = []
var _aim_materials: Array[ShaderMaterial] = []  # normal + dirt-vision materials
var _vision_on: bool = false

# Zones
var _zones: Dictionary = {}            # hex key -> zone data
var _zone_order: Array[String] = []    # zone id - 1 -> hex key
var _zone_auto_names: Dictionary = {}
var _pixel_to_zone: Dictionary = {}    # progress-grid cell index -> hex key
var _zone_image: Image
var _zone_texture: ImageTexture        # exact (uncompressed) zone map for the shaders
var _zone_colors := PackedVector3Array()
var _zone_flash := PackedFloat32Array()
var _flash_active: bool = false
var _totals_initialized: bool = false

# Progress read-back
var _measure_state: Measure = Measure.IDLE
var _measure_queued: bool = false
var _last_snapshot: Image              # progress grid: R = rust, G = base layer

# Baked surface data
var _bake_faces: PackedFloat32Array
var _bake_thread: Thread
var _bake_cancel: Array = [false]
var _bake_ready: bool = false
var _position_texture: ImageTexture
var _normal_texture: ImageTexture
var _position_image: Image  # kept for diagnostics/tests
var _normal_image: Image
var _coverage: PackedByteArray  # progress grid, 1 = surface behind this cell

# Stroke state (continuous strokes between physics frames)
var _prev_paint_pos: Vector3 = Vector3.ZERO
var _last_paint_ms: int = -100000
var _stroke_active: bool = false

# Aim ring state (avoid re-sending identical uniforms)
var _aim_shown: bool = false

# Face data for hit -> UV lookup. Three entries per face.
var _face_verts := PackedVector3Array()
var _face_uvs := PackedVector2Array()
var _mesh_face_ranges: Array[Vector2i] = []   # per mesh instance: (first face, face count)
var _shape_face_offsets: Dictionary = {}      # physics shape index -> first face, or -1
var _face_grid: Dictionary = {}
var _grid_cell_size: float = 1.0

# =============================================================================
# LIFECYCLE
# =============================================================================

func _ready() -> void:
	add_to_group("cleanable")
	_validate_collision_shapes()

	_mesh_instances = _find_all_mesh_instances()
	if _mesh_instances.is_empty():
		push_warning("No MeshInstance3D found in subtree")
		return

	@warning_ignore("integer_division")
	var ratio: int = maxi(paint_size / texture_size, 1)
	paint_size = texture_size * ratio

	_setup_mesh_data()
	_setup_zones()
	_setup_paint_viewport()
	_setup_materials()

	# Visual dirt appears immediately; the brush activates when the bake finishes.
	_paint_viewport.fill_zone_dirt(false)
	_start_bake()

	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
	if has_node("/root/DirtVision"):
		var dirt_vision: Node = get_node("/root/DirtVision")
		dirt_vision.dirt_vision_changed.connect(_on_dirt_vision_changed)
		_on_dirt_vision_changed(dirt_vision.enabled)


func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_on_frame_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_frame_post_draw)
	_bake_cancel[0] = true
	if _bake_thread and _bake_thread.is_started():
		_bake_thread.wait_to_finish()
	_bake_thread = null


func _process(delta: float) -> void:
	if _flash_active:
		_fade_flash(delta)

	if _paint_dirty and _bake_ready:
		_progress_timer += delta
		if _progress_timer >= PROGRESS_INTERVAL:
			_progress_timer = 0.0
			_paint_dirty = false
			_request_measure()

# =============================================================================
# PUBLIC API — called by sprayer and game systems
# =============================================================================

## True once the surface bake is done and clean_at() has an effect.
func is_surface_ready() -> bool:
	return _bake_ready


## Burn dirt away inside the laser beam. Called every physics frame by the
## sprayer while firing.
##   world_pos    point on the beam axis where the beam lands
##   beam_dir     direction the light travels (normalized)
##   brush_radius beam radius in WORLD units - identical to the aiming ring
##   depth_front / depth_back  how far the lit surface extends toward / away
##                from the laser around world_pos (negative = sensible default)
func clean_at(world_pos: Vector3, beam_dir: Vector3, intensity: float, effectiveness: float, delta: float, brush_radius: float = 0.075, pressure: float = 1.0, depth_front: float = -1.0, depth_back: float = -1.0) -> void:
	if not _bake_ready or _victory_triggered or effectiveness <= 0.0 or brush_radius <= 0.0:
		return

	var inv: Transform3D = global_transform.affine_inverse()
	var local_pos: Vector3 = inv * world_pos
	var local_dir: Vector3 = (inv.basis * beam_dir).normalized()

	var inv_scale: float = 1.0 / _average_scale()
	var local_radius: float = brush_radius * inv_scale
	var front: float = (depth_front if depth_front >= 0.0 else brush_radius * DEFAULT_DEPTH_RADII) * inv_scale
	var back: float = (depth_back if depth_back >= 0.0 else brush_radius * DEFAULT_DEPTH_RADII) * inv_scale

	# Continue the stroke from last tick's hit for gap-free sweeps; start a
	# fresh stamp if the beam jumped (new part, big depth change, long pause).
	var now: int = Time.get_ticks_msec()
	var from: Vector3 = local_pos
	var sweep_len: float = 0.0
	if _stroke_active and now - _last_paint_ms <= STROKE_GAP_MS:
		var seg: Vector3 = _prev_paint_pos - local_pos
		var seg_depth: float = seg.dot(local_dir)
		var across: float = (seg - local_dir * seg_depth).length()
		if across <= local_radius * MAX_SWEEP_RADII and absf(seg_depth) <= maxf(front, back) + local_radius * 2.0:
			from = _prev_paint_pos
			sweep_len = across
	_prev_paint_pos = local_pos
	_last_paint_ms = now
	_stroke_active = true

	# One tick delivers a fixed amount of energy. A fast flick spreads it along
	# the whole stroke instead of cleaning the entire path at full power.
	var strength: float = laser_power * intensity * effectiveness * pressure * delta
	var diameter: float = local_radius * 2.0
	if sweep_len > diameter:
		strength *= diameter / sweep_len

	_paint_viewport.paint_beam(from, local_pos, local_dir, local_radius, front, back, strength)
	_paint_dirty = true


## Ends the current stroke, so the next clean_at() starts a new stamp instead
## of sweeping from the previous hit.
func end_stroke() -> void:
	_stroke_active = false


## Show the aiming ring: the outline of what clean_at() with the same
## arguments would clean. `firing` adds the hot glow under the beam.
func set_aim(world_pos: Vector3, beam_dir: Vector3, brush_radius: float, depth_front: float, depth_back: float, firing: bool) -> void:
	if _victory_triggered:
		return  # nothing left to aim at
	_aim_shown = true
	for mat: ShaderMaterial in _aim_materials:
		mat.set_shader_parameter("aim_visible", 1.0)
		mat.set_shader_parameter("aim_firing", 1.0 if firing else 0.0)
		mat.set_shader_parameter("aim_point", world_pos)
		mat.set_shader_parameter("aim_dir", beam_dir)
		mat.set_shader_parameter("aim_radius", brush_radius)
		mat.set_shader_parameter("aim_depth_front", depth_front)
		mat.set_shader_parameter("aim_depth_back", depth_back)


func clear_aim() -> void:
	if not _aim_shown:
		return
	_aim_shown = false
	for mat: ShaderMaterial in _aim_materials:
		mat.set_shader_parameter("aim_visible", 0.0)
		mat.set_shader_parameter("aim_firing", 0.0)


## Instantly clear all dirt. Used by ESC-shortcut win path.
func clean_all() -> void:
	if not _paint_viewport:
		return
	_paint_viewport.fill_black()

	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		zone["rust_remaining"] = 0.0
		zone["metal_remaining"] = 0.0
		zone["completed"] = true

	_paint_dirty = false
	_last_snapshot = null
	clear_aim()


## Returns zone info at a world position. Used by sprayer for UI display.
## Pass the raycast normal to disambiguate thin double-sided geometry, and the
## raycast's shape + face_index (when available) for an exact, instant lookup.
func get_zone_at_position(world_pos: Vector3, world_normal: Vector3 = Vector3.ZERO, shape_index: int = -1, face_index: int = -1) -> Dictionary:
	var cell: int = _cell_from_world(world_pos, world_normal, shape_index, face_index)
	if cell < 0 or not _pixel_to_zone.has(cell):
		return {}

	var zone_key: String = _pixel_to_zone[cell]
	if not _zones.has(zone_key):
		return {}

	var zone: Dictionary = _zones[zone_key]
	return {
		"key": zone_key,
		"name": _get_zone_display_name(zone_key),
		"progress": _calculate_zone_progress(zone),
		"completed": zone["completed"]
	}


## Returns true if there's still dirt at a world position. Used by crosshair
## and laser feedback.
func has_dirt_at(world_pos: Vector3, world_normal: Vector3 = Vector3.ZERO, shape_index: int = -1, face_index: int = -1) -> bool:
	var cell: int = _cell_from_world(world_pos, world_normal, shape_index, face_index)
	if cell < 0 or not _pixel_to_zone.has(cell):
		return false

	var zone_key: String = _pixel_to_zone[cell]
	if _zones.has(zone_key) and _zones[zone_key]["completed"]:
		return false
	if not _last_snapshot:
		return true

	@warning_ignore("integer_division")
	var color: Color = _last_snapshot.get_pixel(cell % texture_size, cell / texture_size)
	return color.r > DIRT_EPSILON or color.g > DIRT_EPSILON


## Overall cleaning progress 0.0–1.0. Used by pause menu and progress UI.
## Cheap: returns the latest measurement, never triggers a read-back.
func get_total_progress() -> float:
	var total_rust: float = 0.0
	var total_metal: float = 0.0
	var remaining_rust: float = 0.0
	var remaining_metal: float = 0.0

	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		total_rust += zone["rust_total"]
		total_metal += zone["metal_total"]
		remaining_rust += zone["rust_remaining"]
		remaining_metal += zone["metal_remaining"]

	if total_rust <= 0.0 or total_metal <= 0.0:
		return 0.0

	var progress: float = ((1.0 - remaining_rust / total_rust) + (1.0 - remaining_metal / total_metal)) / 2.0
	return clampf(progress, 0.0, 1.0)


## Per-zone state for pause menu display.
func get_zones_state() -> Dictionary:
	var state: Dictionary = {}
	for zone_key: String in _zone_order:
		var zone: Dictionary = _zones[zone_key]
		state[zone_key] = {
			"name": _get_zone_display_name(zone_key),
			"completed": zone["completed"],
			"progress": _calculate_zone_progress(zone)
		}
	return state


## Full-resolution dirt mask (float). Slow read-back: saves/tests only.
func get_dirt_image() -> Image:
	return _paint_viewport.get_snapshot() if _paint_viewport else null


func set_dirt_image(img: Image) -> void:
	if img and _paint_viewport:
		_paint_viewport.draw_image(img, true)
		_paint_dirty = true

# =============================================================================
# SETUP — runs once in _ready
# =============================================================================

func _validate_collision_shapes() -> void:
	for child: Node in get_children():
		if child is CollisionShape3D:
			assert(
				child.shape is ConcavePolygonShape3D,
				"Cleanable '%s' has '%s' using %s. Must be ConcavePolygonShape3D." % [name, child.name, child.shape.get_class()]
			)


func _find_all_mesh_instances() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	_collect_mesh_instances(self, result)
	return result


func _collect_mesh_instances(node: Node, result: Array[MeshInstance3D]) -> void:
	for child: Node in node.get_children():
		if child is MeshInstance3D:
			result.append(child)
		_collect_mesh_instances(child, result)


func _find_animation_player() -> AnimationPlayer:
	return _find_anim_recursive(self)


func _find_anim_recursive(node: Node) -> AnimationPlayer:
	for child: Node in node.get_children():
		if child is AnimationPlayer:
			return child
		var result: AnimationPlayer = _find_anim_recursive(child)
		if result:
			return result
	return null


func _average_scale() -> float:
	var s: Vector3 = global_transform.basis.get_scale()
	return maxf((s.x + s.y + s.z) / 3.0, 0.0001)


func _setup_paint_viewport() -> void:
	var script := load("res://cleanable/paint_viewport.gd")
	_paint_viewport = Node.new()
	_paint_viewport.set_script(script)
	add_child(_paint_viewport)
	_paint_viewport.setup(paint_size, texture_size, rust_resistance, metal_resistance)
	_paint_viewport.set_zones(_zone_texture, _zone_colors, _zone_order.size())


## Collects every face of every mesh instance, in body-local space:
##  - _bake_faces  flat array for the threaded surface baker
##  - _face_verts / _face_uvs + spatial grid for hit -> UV lookups
func _setup_mesh_data() -> void:
	_face_verts.clear()
	_face_uvs.clear()
	_face_grid.clear()
	_mesh_face_ranges.clear()
	_shape_face_offsets.clear()
	_bake_faces = PackedFloat32Array()

	var mesh_min := Vector3(INF, INF, INF)
	var mesh_max := Vector3(-INF, -INF, -INF)
	var inv: Transform3D = global_transform.affine_inverse()

	for mesh_instance: MeshInstance3D in _mesh_instances:
		var first_face: int = _face_verts.size() / 3
		var mesh: Mesh = mesh_instance.mesh
		if not mesh or mesh.get_surface_count() == 0:
			_mesh_face_ranges.append(Vector2i(first_face, 0))
			continue

		var si: int = mini(surface_index, mesh.get_surface_count() - 1)
		var arrays: Array = mesh.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
		var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if verts.is_empty() or uvs == null or (uvs as PackedVector2Array).size() != verts.size():
			push_warning("Cleanable '%s': mesh '%s' has no UVs - skipped." % [name, mesh_instance.name])
			_mesh_face_ranges.append(Vector2i(first_face, 0))
			continue

		# Body-local vertices and normals
		var to_body: Transform3D = inv * mesh_instance.global_transform
		var local_verts: PackedVector3Array = to_body * verts
		var normal_basis: Basis = to_body.basis.inverse().transposed()
		var has_normals: bool = normals != null and (normals as PackedVector3Array).size() == verts.size()

		var index_count: int = verts.size()
		var has_indices: bool = indices != null and not (indices as PackedInt32Array).is_empty()
		if has_indices:
			index_count = (indices as PackedInt32Array).size()

		var face_count: int = index_count / 3
		var chunk := PackedFloat32Array()
		chunk.resize(face_count * SurfaceBaker.FLOATS_PER_FACE)

		for f: int in range(face_count):
			var i0: int = f * 3
			var i1: int = i0 + 1
			var i2: int = i0 + 2
			if has_indices:
				i0 = indices[i0]
				i1 = indices[i1]
				i2 = indices[i2]

			var v0: Vector3 = local_verts[i0]
			var v1: Vector3 = local_verts[i1]
			var v2: Vector3 = local_verts[i2]
			var uv0: Vector2 = uvs[i0]
			var uv1: Vector2 = uvs[i1]
			var uv2: Vector2 = uvs[i2]

			var n0: Vector3
			var n1: Vector3
			var n2: Vector3
			if has_normals:
				n0 = (normal_basis * normals[i0]).normalized()
				n1 = (normal_basis * normals[i1]).normalized()
				n2 = (normal_basis * normals[i2]).normalized()
			else:
				# Godot winds front faces clockwise: outward = cross(v2-v0, v1-v0)
				n0 = (v2 - v0).cross(v1 - v0).normalized()
				n1 = n0
				n2 = n0

			_face_verts.append(v0)
			_face_verts.append(v1)
			_face_verts.append(v2)
			_face_uvs.append(uv0)
			_face_uvs.append(uv1)
			_face_uvs.append(uv2)

			# Flat layout for the threaded baker: 9 pos + 9 normal + 6 uv floats
			var o: int = f * SurfaceBaker.FLOATS_PER_FACE
			chunk[o] = v0.x; chunk[o + 1] = v0.y; chunk[o + 2] = v0.z
			chunk[o + 3] = v1.x; chunk[o + 4] = v1.y; chunk[o + 5] = v1.z
			chunk[o + 6] = v2.x; chunk[o + 7] = v2.y; chunk[o + 8] = v2.z
			chunk[o + 9] = n0.x; chunk[o + 10] = n0.y; chunk[o + 11] = n0.z
			chunk[o + 12] = n1.x; chunk[o + 13] = n1.y; chunk[o + 14] = n1.z
			chunk[o + 15] = n2.x; chunk[o + 16] = n2.y; chunk[o + 17] = n2.z
			chunk[o + 18] = uv0.x; chunk[o + 19] = uv0.y
			chunk[o + 20] = uv1.x; chunk[o + 21] = uv1.y
			chunk[o + 22] = uv2.x; chunk[o + 23] = uv2.y

			mesh_min = mesh_min.min(v0).min(v1).min(v2)
			mesh_max = mesh_max.max(v0).max(v1).max(v2)

		_bake_faces.append_array(chunk)
		_mesh_face_ranges.append(Vector2i(first_face, face_count))

	if _face_verts.is_empty():
		return

	# Auto-size grid cells based on mesh extents
	var extent: Vector3 = mesh_max - mesh_min
	var longest_axis: float = maxf(extent.x, maxf(extent.y, extent.z))
	_grid_cell_size = longest_axis / 20.0 if longest_axis > 0.0 else 1.0

	@warning_ignore("integer_division")
	for face_idx: int in range(_face_verts.size() / 3):
		var b: int = face_idx * 3
		_add_face_to_grid_cells(face_idx, _face_verts[b], _face_verts[b + 1], _face_verts[b + 2])

	_repair_stretched_faces()


## Some models contain a few badly unwrapped faces: a small patch of surface
## whose UVs form a long sliver running across the texture space of other
## parts. Left alone they do two kinds of damage:
##  - in the bake, the sliver claims the texels it crosses, so a line on some
##    other part can never be cleaned from where the player sees it;
##  - on screen, the patch shows a slice of the texture and dirt of other parts.
## Such faces are dropped from the bake and given the UVs of the healthy
## surface right next to them.
func _repair_stretched_faces() -> void:
	var stretched: PackedInt32Array = _find_stretched_faces()
	if stretched.is_empty():
		return

	var is_stretched: Dictionary = {}
	for face: int in stretched:
		is_stretched[face] = true

	# 1. Keep them out of the surface bake
	var kept := PackedFloat32Array()
	@warning_ignore("integer_division")
	var face_count: int = _bake_faces.size() / SurfaceBaker.FLOATS_PER_FACE
	var run_start: int = 0
	for face: int in range(face_count + 1):
		if face == face_count or is_stretched.has(face):
			if face > run_start:
				kept.append_array(_bake_faces.slice(run_start * SurfaceBaker.FLOATS_PER_FACE, face * SurfaceBaker.FLOATS_PER_FACE))
			run_start = face + 1
	_bake_faces = kept

	# 2. Borrow UVs from the neighbouring healthy surface
	var per_mesh: Dictionary = {}  # mesh index -> Array of [local face, uv0, uv1, uv2]
	for face: int in stretched:
		var b: int = face * 3
		var centroid: Vector3 = (_face_verts[b] + _face_verts[b + 1] + _face_verts[b + 2]) / 3.0
		var reference: Vector2 = _nearest_healthy_uv(centroid, Vector2(-1, -1), is_stretched)
		if reference.x < 0.0:
			continue
		var uv0: Vector2 = _nearest_healthy_uv(_face_verts[b], reference, is_stretched)
		var uv1: Vector2 = _nearest_healthy_uv(_face_verts[b + 1], reference, is_stretched)
		var uv2: Vector2 = _nearest_healthy_uv(_face_verts[b + 2], reference, is_stretched)
		if uv0.x < 0.0 or uv1.x < 0.0 or uv2.x < 0.0:
			continue
		_face_uvs[b] = uv0
		_face_uvs[b + 1] = uv1
		_face_uvs[b + 2] = uv2

		for mesh_index: int in range(_mesh_face_ranges.size()):
			var face_range: Vector2i = _mesh_face_ranges[mesh_index]
			if face >= face_range.x and face < face_range.x + face_range.y:
				if not per_mesh.has(mesh_index):
					per_mesh[mesh_index] = []
				per_mesh[mesh_index].append([face - face_range.x, uv0, uv1, uv2])
				break

	for mesh_index: int in per_mesh:
		_apply_repaired_uvs(_mesh_instances[mesh_index], per_mesh[mesh_index])


## Faces whose UV mapping is far denser than the rest of the model in one
## direction only. Evenly dense islands (small detailed parts) are left alone.
func _find_stretched_faces() -> PackedInt32Array:
	@warning_ignore("integer_division")
	var face_count: int = _face_verts.size() / 3
	var major := PackedFloat32Array()
	var minor := PackedFloat32Array()
	major.resize(face_count)
	minor.resize(face_count)
	var densities: Array[float] = []
	var collapsed := PackedInt32Array()

	for face: int in range(face_count):
		var b: int = face * 3
		var e1: Vector3 = _face_verts[b + 1] - _face_verts[b]
		var e2: Vector3 = _face_verts[b + 2] - _face_verts[b]
		var u1: Vector2 = _face_uvs[b + 1] - _face_uvs[b]
		var u2: Vector2 = _face_uvs[b + 2] - _face_uvs[b]
		var normal: Vector3 = e1.cross(e2)
		major[face] = -1.0
		if normal.length_squared() < 1e-20 or e1.length_squared() < 1e-14:
			# No surface area at all, yet it may still own a patch of texture:
			# that patch would be baked onto a line nobody can see or hit.
			if absf(u1.cross(u2)) * 0.5 * paint_size * paint_size > 2.0:
				collapsed.append(face)
			continue

		# Singular values of the surface -> UV map: UV units per metre along
		# the most and least stretched directions of this face.
		var x_axis: Vector3 = e1.normalized()
		var y_axis: Vector3 = normal.normalized().cross(x_axis)
		var a11: float = e1.length()
		var a12: float = e2.dot(x_axis)
		var a22: float = e2.dot(y_axis)
		if absf(a22) < 1e-9:
			if absf(u1.cross(u2)) * 0.5 * paint_size * paint_size > 2.0:
				collapsed.append(face)
			continue
		var j11: float = u1.x / a11
		var j21: float = u1.y / a11
		var j12: float = (u2.x - j11 * a12) / a22
		var j22: float = (u2.y - j21 * a12) / a22
		var q: float = j11 * j11 + j12 * j12 + j21 * j21 + j22 * j22
		var det: float = j11 * j22 - j12 * j21
		var disc: float = sqrt(maxf(q * q - 4.0 * det * det, 0.0))
		major[face] = sqrt((q + disc) * 0.5)
		minor[face] = sqrt(maxf((q - disc) * 0.5, 0.0))
		if minor[face] > 0.0:
			densities.append(sqrt(major[face] * minor[face]))

	var result: PackedInt32Array = collapsed
	if densities.size() < 8:
		return result
	densities.sort()
	@warning_ignore("integer_division")
	var median: float = densities[densities.size() / 2]
	if median <= 0.0:
		return result

	for face: int in range(face_count):
		if major[face] > median * STRETCH_LIMIT and major[face] > maxf(minor[face], 1e-12) * STRETCH_ANISOTROPY:
			result.append(face)
	result.sort()
	return result


## UV of the healthy surface closest to a body-local point. When several
## surfaces are equally close (a UV seam), the one nearest to `prefer` wins,
## so all three corners of a repaired face land on the same island.
func _nearest_healthy_uv(local_pos: Vector3, prefer: Vector2, skip: Dictionary) -> Vector2:
	var cell := Vector3i((local_pos / _grid_cell_size).floor())
	var candidates: Array = []  # [distance, uv]
	var best_dist: float = INF
	var seen: Dictionary = {}

	for dx: int in range(-1, 2):
		for dy: int in range(-1, 2):
			for dz: int in range(-1, 2):
				var key := cell + Vector3i(dx, dy, dz)
				if not _face_grid.has(key):
					continue
				for face: int in _face_grid[key]:
					if seen.has(face) or skip.has(face):
						continue
					seen[face] = true
					var b: int = face * 3
					var v0: Vector3 = _face_verts[b]
					var v1: Vector3 = _face_verts[b + 1]
					var v2: Vector3 = _face_verts[b + 2]
					if (v2 - v0).cross(v1 - v0).length_squared() < 1e-14:
						continue
					var on_face: Vector3 = _closest_point_on_triangle(local_pos, v0, v1, v2)
					var dist: float = local_pos.distance_to(on_face)
					var bary: Vector3 = _barycentric(on_face, v0, v1, v2)
					candidates.append([dist, _face_uvs[b] * bary.x + _face_uvs[b + 1] * bary.y + _face_uvs[b + 2] * bary.z])
					best_dist = minf(best_dist, dist)

	var slack: float = maxf(_grid_cell_size * 0.01, 0.001)
	var best_uv := Vector2(-1, -1)
	var best_score: float = INF
	for candidate: Array in candidates:
		if candidate[0] > best_dist + slack:
			continue
		var score: float = candidate[0] if prefer.x < 0.0 else (candidate[1] as Vector2).distance_to(prefer)
		if score < best_score:
			best_score = score
			best_uv = candidate[1]
	return best_uv


## Gives this mesh instance its own copy of the mesh with new UVs on the
## listed faces ([face index, uv0, uv1, uv2]). The faces get private vertices,
## so healthy neighbours sharing a vertex keep their mapping.
func _apply_repaired_uvs(mesh_instance: MeshInstance3D, repairs: Array) -> void:
	var source := mesh_instance.mesh as ArrayMesh
	if not source or source.get_blend_shape_count() > 0:
		return
	var target_surface: int = mini(surface_index, source.get_surface_count() - 1)

	var repaired := ArrayMesh.new()
	for surface: int in range(source.get_surface_count()):
		var arrays: Array = source.surface_get_arrays(surface)
		if surface == target_surface:
			_rewrite_face_uvs(arrays, repairs)
		repaired.add_surface_from_arrays(source.surface_get_primitive_type(surface), arrays)
		repaired.surface_set_material(surface, source.surface_get_material(surface))
		repaired.surface_set_name(surface, source.surface_get_name(surface))
	repaired.shadow_mesh = source.shadow_mesh
	mesh_instance.mesh = repaired


func _rewrite_face_uvs(arrays: Array, repairs: Array) -> void:
	var vertex_count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indexed: bool = arrays[Mesh.ARRAY_INDEX] != null and not (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty()

	if not indexed:
		for repair: Array in repairs:
			for k: int in range(3):
				uvs[int(repair[0]) * 3 + k] = repair[1 + k]
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		return

	# Indexed mesh: duplicate the three corners of every repaired face
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var sources := PackedInt32Array()
	var new_uvs := PackedVector2Array()
	for repair: Array in repairs:
		for k: int in range(3):
			var slot: int = int(repair[0]) * 3 + k
			sources.append(indices[slot])
			new_uvs.append(repair[1 + k])
			indices[slot] = vertex_count + sources.size() - 1
	arrays[Mesh.ARRAY_INDEX] = indices

	for channel: int in range(arrays.size()):
		if channel == Mesh.ARRAY_INDEX or arrays[channel] == null:
			continue
		var data: Variant = arrays[channel]
		@warning_ignore("integer_division")
		var stride: int = data.size() / vertex_count
		if stride <= 0:
			continue
		for src: int in sources:
			for part: int in range(stride):
				data.append(data[src * stride + part])
		arrays[channel] = data

	uvs = arrays[Mesh.ARRAY_TEX_UV]
	for i: int in range(new_uvs.size()):
		uvs[vertex_count + i] = new_uvs[i]
	arrays[Mesh.ARRAY_TEX_UV] = uvs


func _add_face_to_grid_cells(face_idx: int, v0: Vector3, v1: Vector3, v2: Vector3) -> void:
	var min_cell := Vector3i((v0.min(v1).min(v2) / _grid_cell_size).floor())
	var max_cell := Vector3i((v0.max(v1).max(v2) / _grid_cell_size).floor())

	# Register the face in EVERY cell its bbox spans. Collapsing large faces to a
	# block around their center makes edge/corner hits unfindable - never do that.
	for x: int in range(min_cell.x, max_cell.x + 1):
		for y: int in range(min_cell.y, max_cell.y + 1):
			for z: int in range(min_cell.z, max_cell.z + 1):
				var key := Vector3i(x, y, z)
				if not _face_grid.has(key):
					_face_grid[key] = []
				_face_grid[key].append(face_idx)


## Hooks the dirt mask, zone map and zone colors into every unique material,
## and prepares the see-through material each mesh switches to in dirt vision.
func _setup_materials() -> void:
	_materials.clear()
	_aim_materials.clear()
	_vision_slots.clear()
	var vision_materials: Dictionary = {}  # normal material -> dirt-vision material
	_zone_flash.resize(MAX_ZONES)
	_zone_flash.fill(0.0)
	var viewport_tex: ViewportTexture = _paint_viewport.get_viewport_texture()

	for mesh_instance: MeshInstance3D in _mesh_instances:
		var mat: ShaderMaterial = mesh_instance.get_surface_override_material(surface_index) as ShaderMaterial
		if not mat:
			var mesh: Mesh = mesh_instance.mesh
			if mesh and mesh.get_surface_count() > 0:
				mat = mesh.surface_get_material(mini(surface_index, mesh.get_surface_count() - 1)) as ShaderMaterial

		if mat and not _materials.has(mat):
			mat.set_shader_parameter("dirt_mask", viewport_tex)
			mat.set_shader_parameter("zone_map", _zone_texture)
			mat.set_shader_parameter("zone_colors", _zone_colors)
			mat.set_shader_parameter("zone_count", _zone_order.size())
			mat.set_shader_parameter("zone_flash", _zone_flash)
			mat.set_shader_parameter("aim_visible", 0.0)
			mat.set_shader_parameter("aim_firing", 0.0)
			_materials.append(mat)
			_aim_materials.append(mat)

			var vision := ShaderMaterial.new()
			vision.shader = XRAY_SHADER
			vision.set_shader_parameter("dirt_mask", viewport_tex)
			vision.set_shader_parameter("rust_color", vision_rust_color)
			vision.set_shader_parameter("base_color", vision_base_color)
			vision.set_shader_parameter("dirt_opacity", vision_dirt_opacity)
			vision.set_shader_parameter("ghost_color", vision_ghost_color)
			vision.set_shader_parameter("ghost_opacity", vision_ghost_opacity)
			vision.set_shader_parameter("pulse_speed", vision_pulse_speed)
			vision.set_shader_parameter("pulse_amount", vision_pulse_amount)
			vision_materials[mat] = vision
			_aim_materials.append(vision)

		if mat:
			# Stand-in that only casts the shadow, shown while dirt vision is on
			var shadow := MeshInstance3D.new()
			shadow.name = "DirtVisionShadow"
			shadow.mesh = mesh_instance.mesh
			shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			var shadow_material := StandardMaterial3D.new()
			shadow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
			shadow.material_override = shadow_material
			shadow.visible = false
			mesh_instance.add_child(shadow)

			_vision_slots.append({
				"instance": mesh_instance,
				"override": mesh_instance.get_surface_override_material(surface_index),
				"vision": vision_materials[mat],
				"shadow": shadow,
			})

# =============================================================================
# SURFACE BAKE — threaded position/normal map rasterization
# =============================================================================

func _start_bake() -> void:
	if _bake_faces.is_empty():
		return
	_bake_cancel = [false]
	_bake_thread = Thread.new()
	_bake_thread.start(_bake_worker.bind(_bake_faces, paint_size, texture_size, dilate_radius, _bake_cancel))


## Worker thread: everything heavy happens here so the game never hitches.
func _bake_worker(faces: PackedFloat32Array, size: int, grid_size: int, dilate: int, cancel: Array) -> void:
	var result: Dictionary = SurfaceBaker.bake(faces, size, dilate, cancel)
	if cancel[0]:
		return
	result["position_image"] = Image.create_from_data(size, size, false, Image.FORMAT_RGBAF, result["position"].to_byte_array())
	result["normal_image"] = Image.create_from_data(size, size, false, Image.FORMAT_RGBAF, result["normal"].to_byte_array())
	result["grid_coverage"] = _downsample_coverage(result["coverage"], size, grid_size)
	result.erase("position")
	result.erase("normal")
	if cancel[0]:
		return
	_on_bake_done.call_deferred(result)


func _on_bake_done(result: Dictionary) -> void:
	if _bake_thread:
		_bake_thread.wait_to_finish()
		_bake_thread = null
	if not is_inside_tree():
		return

	_position_image = result["position_image"]
	_normal_image = result["normal_image"]
	_position_texture = ImageTexture.create_from_image(_position_image)
	_normal_texture = ImageTexture.create_from_image(_normal_image)
	_paint_viewport.set_surface_maps(_position_texture, _normal_texture)

	# Replace the provisional fill with the coverage-corrected one, then measure
	# the true initial dirt so completion thresholds are always reachable. The
	# brush switches on when that first measurement arrives.
	_paint_viewport.fill_zone_dirt(true)
	_coverage = result["grid_coverage"]
	_apply_coverage_to_zones()
	_request_measure()


## Mask-resolution coverage → progress grid. A cell counts as covered if ANY of
## its sub-texels has surface data behind it.
static func _downsample_coverage(cov: PackedByteArray, size: int, grid_size: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(grid_size * grid_size)
	out.fill(0)
	@warning_ignore("integer_division")
	var ratio: int = maxi(size / grid_size, 1)

	for y: int in range(grid_size):
		for x: int in range(grid_size):
			var covered: bool = false
			for sy: int in range(ratio):
				var row: int = (y * ratio + sy) * size
				for sx: int in range(ratio):
					if cov[row + x * ratio + sx] != 0:
						covered = true
						break
				if covered:
					break
			if covered:
				out[x + y * grid_size] = 1
	return out


## Drop zone cells that have no surface behind them - the brush can never
## reach those, and counting them would make zones impossible to complete.
func _apply_coverage_to_zones() -> void:
	var removed_zones: Array[String] = []

	for zone_key: String in _zones:
		var zone: Dictionary = _zones[zone_key]
		var kept := PackedInt32Array()
		var sum_x: int = 0
		var sum_y: int = 0

		for cell: int in zone["pidx"]:
			if _coverage[cell] != 0:
				kept.append(cell)
				sum_x += cell % texture_size
				@warning_ignore("integer_division")
				sum_y += cell / texture_size
			else:
				_pixel_to_zone.erase(cell)

		if kept.size() < min_zone_pixels:
			for cell: int in kept:
				_pixel_to_zone.erase(cell)
			removed_zones.append(zone_key)
			continue

		zone["pidx"] = kept
		zone["total"] = kept.size()
		zone["center_uv"] = Vector2(
			sum_x / float(kept.size()) / texture_size,
			sum_y / float(kept.size()) / texture_size
		)

	# A zone with (almost) no real surface can never be cleaned by the player:
	# mark it done silently so it cannot block the job.
	for zone_key: String in removed_zones:
		var zone: Dictionary = _zones[zone_key]
		zone["pidx"] = PackedInt32Array()
		zone["total"] = 0
		zone["completed"] = true
		zone["rust_remaining"] = 0.0
		zone["metal_remaining"] = 0.0
		_paint_viewport.wipe_zone(zone["id"])

# =============================================================================
# ZONE DISCOVERY — auto-detect colored regions from zone map
# =============================================================================

func _setup_zones() -> void:
	_zone_colors.resize(MAX_ZONES)
	_zone_colors.fill(Vector3.ZERO)
	if not zone_map:
		return

	# Exact, uncompressed copy of the zone map: the shaders must classify the
	# very same colors the bookkeeping below sees (the imported texture may be
	# VRAM-compressed and mipmapped).
	var source: Image = zone_map.get_image()
	if not source:
		return
	if source.is_compressed():
		source.decompress()
	source.clear_mipmaps()
	source.convert(Image.FORMAT_RGB8)
	_zone_texture = ImageTexture.create_from_image(source)

	_zone_image = source.duplicate()
	if _zone_image.get_size() != Vector2i(texture_size, texture_size):
		_zone_image.resize(texture_size, texture_size, Image.INTERPOLATE_NEAREST)

	# Combine user-defined reference colors with auto-discovered ones
	var all_zone_colors: Array[Color] = []
	for key: Variant in zone_names.keys():
		if key is Color:
			all_zone_colors.append(key)

	for disc_color: Color in _discover_zone_colors():
		var is_new: bool = true
		for existing: Color in all_zone_colors:
			if _color_distance(disc_color, existing) < seed_merge_distance:
				is_new = false
				break
		if is_new:
			all_zone_colors.append(disc_color)

	if all_zone_colors.is_empty():
		return
	if all_zone_colors.size() > MAX_ZONES:
		push_warning("Cleanable '%s': %d zone colors found, only the first %d are used." % [name, all_zone_colors.size(), MAX_ZONES])
		all_zone_colors.resize(MAX_ZONES)

	# Assign every non-black cell to its nearest zone color
	var data: PackedByteArray = _zone_image.get_data()
	var stride: int = 3
	var cells_by_color: Array[PackedInt32Array] = []
	for i: int in range(all_zone_colors.size()):
		cells_by_color.append(PackedInt32Array())

	for y: int in range(texture_size):
		var row_offset: int = y * texture_size * stride
		for x: int in range(texture_size):
			var i: int = row_offset + x * stride
			var r: float = data[i] / 255.0
			var g: float = data[i + 1] / 255.0
			var b: float = data[i + 2] / 255.0

			if r < 0.05 and g < 0.05 and b < 0.05:
				continue

			var color := Color(r, g, b)
			var best: int = 0
			var best_dist: float = _color_distance(color, all_zone_colors[0])
			for c: int in range(1, all_zone_colors.size()):
				var dist: float = _color_distance(color, all_zone_colors[c])
				if dist < best_dist:
					best_dist = dist
					best = c
			cells_by_color[best].append(x + y * texture_size)

	# Keep real zones only; tiny ones are anti-aliasing artifacts. The shader's
	# color list is exactly the kept zones, in the same order, so a stray
	# artifact texel simply joins its nearest real zone.
	for c: int in range(all_zone_colors.size()):
		var cells: PackedInt32Array = cells_by_color[c]
		if cells.size() < min_zone_pixels:
			continue

		var zone_color: Color = all_zone_colors[c]
		var zone_key: String = _color_to_hex(zone_color)
		if _zones.has(zone_key):
			continue
		var sum_x: int = 0
		var sum_y: int = 0
		for cell: int in cells:
			sum_x += cell % texture_size
			@warning_ignore("integer_division")
			sum_y += cell / texture_size
			_pixel_to_zone[cell] = zone_key

		_zone_order.append(zone_key)
		_zone_colors[_zone_order.size() - 1] = Vector3(zone_color.r, zone_color.g, zone_color.b)
		_zones[zone_key] = {
			"id": _zone_order.size(),
			"color": zone_color,
			"total": cells.size(),
			"completed": false,
			"pidx": cells,
			"center_uv": Vector2(sum_x, sum_y) / float(cells.size()) / texture_size,
			"rust_total": float(cells.size()), "rust_remaining": float(cells.size()),
			"metal_total": float(cells.size()), "metal_remaining": float(cells.size())
		}
		if not _has_zone_name(zone_key):
			_zone_auto_names[zone_key] = "Zone %d" % _zone_order.size()


func _discover_zone_colors() -> Array[Color]:
	var seed_colors: Array[Color] = []
	var data: PackedByteArray = _zone_image.get_data()
	var stride: int = 3

	for y: int in range(texture_size):
		var row_offset: int = y * texture_size * stride
		for x: int in range(texture_size):
			var i: int = row_offset + x * stride
			var r: float = data[i] / 255.0
			var g: float = data[i + 1] / 255.0
			var b: float = data[i + 2] / 255.0

			if maxf(r, maxf(g, b)) < brightness_threshold:
				continue

			var color := Color(r, g, b)
			var is_new: bool = true
			for seed_color: Color in seed_colors:
				if _color_distance(color, seed_color) < seed_merge_distance:
					is_new = false
					break
			if is_new:
				seed_colors.append(color)

	return seed_colors

# =============================================================================
# PROGRESS — reads back a small box-filtered copy of the mask
# =============================================================================

## Schedules one measurement. Never blocks: the result arrives two rendered
## frames later through _on_frame_post_draw.
func _request_measure() -> void:
	if _measure_state == Measure.IDLE:
		_measure_state = Measure.WAIT_PAINT
	else:
		_measure_queued = true


func _on_frame_post_draw() -> void:
	match _measure_state:
		Measure.WAIT_PAINT:
			# Everything painted so far is in the mask now; shrink it this frame.
			_paint_viewport.request_measure()
			_measure_state = Measure.WAIT_READBACK
		Measure.WAIT_READBACK:
			_measure_state = Measure.IDLE
			var img: Image = _paint_viewport.get_measure_image()
			if img:
				_apply_measure(img)
			if _measure_queued or not _totals_initialized:
				_measure_queued = false
				_measure_state = Measure.WAIT_PAINT


func _apply_measure(snapshot: Image) -> void:
	if snapshot.get_format() != Image.FORMAT_RGBA8:
		snapshot.convert(Image.FORMAT_RGBA8)
	if snapshot.get_size() != Vector2i(texture_size, texture_size):
		snapshot.resize(texture_size, texture_size, Image.INTERPOLATE_BILINEAR)

	var data: PackedByteArray = snapshot.get_data()
	var stride: int = 4

	if not _totals_initialized:
		# First measurement after the corrected fill = ground truth for 100% dirty.
		# If the frame was not actually rendered (minimized window), wait for a real one.
		var cells: int = 0
		var sum: float = 0.0
		for zone_key: String in _zones:
			for cell: int in _zones[zone_key]["pidx"]:
				sum += data[cell * stride]
				cells += 1
		if cells > 0 and sum / 255.0 < cells * 0.2:
			return

	_last_snapshot = snapshot

	for zone_key: String in _zone_order:
		var zone: Dictionary = _zones[zone_key]
		if zone["completed"]:
			continue

		var rust_sum: float = 0.0
		var metal_sum: float = 0.0
		for cell: int in zone["pidx"]:
			var idx: int = cell * stride
			rust_sum += data[idx]
			metal_sum += data[idx + 1]
		rust_sum /= 255.0
		metal_sum /= 255.0

		zone["rust_remaining"] = rust_sum
		zone["metal_remaining"] = metal_sum
		if not _totals_initialized:
			zone["rust_total"] = maxf(rust_sum, 0.001)
			zone["metal_total"] = maxf(metal_sum, 0.001)
		else:
			_check_zone_completion(zone_key)

	if not _totals_initialized:
		_totals_initialized = true
		_bake_ready = true
		surface_ready.emit()

# =============================================================================
# ZONE COMPLETION — triggers flash, ding, and eventually victory
# =============================================================================

func _check_zone_completion(zone_key: String) -> void:
	var zone: Dictionary = _zones[zone_key]
	if zone["completed"]:
		return

	var rust_pct: float = 1.0 - (zone["rust_remaining"] / zone["rust_total"])
	var metal_pct: float = 1.0 - (zone["metal_remaining"] / zone["metal_total"])

	if rust_pct >= rust_complete_threshold and metal_pct >= metal_complete_threshold:
		_complete_zone(zone_key)


func _complete_zone(zone_key: String) -> void:
	var zone: Dictionary = _zones[zone_key]
	if zone["completed"]:
		return

	zone["completed"] = true
	zone["rust_remaining"] = 0.0
	zone["metal_remaining"] = 0.0

	# Wipe the zone's last dirt specks (full mask resolution) and flash it
	_paint_viewport.wipe_zone(zone["id"])
	_start_flash(zone["id"])

	AudioManager.play_ding()
	zone_completed.emit(zone["color"], global_position)
	_check_object_completed()


func _check_object_completed() -> void:
	if _zones.is_empty():
		return
	for zone_key: String in _zones:
		if not _zones[zone_key]["completed"]:
			return

	if _victory_triggered:
		return
	_victory_triggered = true
	clear_aim()
	# In dirt vision a fully clean object is invisible - show it for the finale.
	if has_node("/root/DirtVision"):
		get_node("/root/DirtVision").set_enabled(false)

	object_completed.emit()
	_play_victory_animation()

# =============================================================================
# VICTORY — plays dance animation, then tells GameManager we're done
# =============================================================================

func _play_victory_animation() -> void:
	var anim_player: AnimationPlayer = _find_animation_player()

	if not anim_player or not anim_player.has_animation(victory_animation_name):
		GameManager.complete_job()
		return

	anim_player.animation_finished.connect(_on_victory_animation_finished, CONNECT_ONE_SHOT)
	anim_player.play(victory_animation_name)


func _on_victory_animation_finished(_anim_name: String) -> void:
	GameManager.complete_job()

# =============================================================================
# FLASH — white pulse that fades after zone completion (shader-driven)
# =============================================================================

func _start_flash(zone_id: int) -> void:
	if zone_id < 1 or zone_id > MAX_ZONES:
		return
	_zone_flash[zone_id - 1] = 1.0
	_flash_active = true
	_push_flash()


func _fade_flash(delta: float) -> void:
	var any_active: bool = false
	for i: int in range(_zone_flash.size()):
		if _zone_flash[i] > 0.0:
			_zone_flash[i] = maxf(_zone_flash[i] - flash_fade_speed * delta, 0.0)
			if _zone_flash[i] > 0.0:
				any_active = true
	_flash_active = any_active
	_push_flash()


func _push_flash() -> void:
	for mat: ShaderMaterial in _materials:
		mat.set_shader_parameter("zone_flash", _zone_flash)

# =============================================================================
# UV LOOKUP — world position → UV → progress-grid cell
# (zone display and dirt checks only; painting does not depend on this)
# =============================================================================

## Progress-grid cell under a world position, or -1.
func _cell_from_world(world_pos: Vector3, world_normal: Vector3, shape_index: int, face_index: int) -> int:
	var uv: Vector2 = _uv_from_world(world_pos, world_normal, shape_index, face_index)
	if uv.x < 0.0:
		return -1
	var px: int = clampi(int(uv.x * texture_size), 0, texture_size - 1)
	var py: int = clampi(int(uv.y * texture_size), 0, texture_size - 1)
	return px + py * texture_size


func _uv_from_world(world_pos: Vector3, world_normal: Vector3 = Vector3.ZERO, shape_index: int = -1, face_index: int = -1) -> Vector2:
	var local_pos: Vector3 = to_local(world_pos)

	# Exact path: the raycast already told us which collision triangle was hit.
	if shape_index >= 0 and face_index >= 0:
		var first_face: int = _first_face_of_shape(shape_index)
		if first_face >= 0:
			var b: int = (first_face + face_index) * 3
			if b + 2 < _face_verts.size():
				var bary: Vector3 = _barycentric(local_pos, _face_verts[b], _face_verts[b + 1], _face_verts[b + 2])
				return _face_uvs[b] * bary.x + _face_uvs[b + 1] * bary.y + _face_uvs[b + 2] * bary.z

	var local_normal: Vector3 = Vector3.ZERO
	if world_normal != Vector3.ZERO:
		local_normal = (global_transform.basis.inverse() * world_normal).normalized()
	return _find_uv_at_position(local_pos, local_normal)


## Maps a physics shape index to the first cached face of the mesh it was
## generated from, or -1 when the collision triangles do not line up 1:1 with
## a mesh (then the spatial search below is used instead). Verified once.
func _first_face_of_shape(shape_index: int) -> int:
	if _shape_face_offsets.has(shape_index):
		return _shape_face_offsets[shape_index]

	var result: int = -1
	var owner_node: Object = null
	if shape_index < 0:
		_shape_face_offsets[shape_index] = -1
		return -1
	var owner_id: int = shape_find_owner(shape_index)
	owner_node = shape_owner_get_owner(owner_id)

	if owner_node is CollisionShape3D and (owner_node as CollisionShape3D).shape is ConcavePolygonShape3D:
		var node := owner_node as CollisionShape3D
		var tris: PackedVector3Array = (node.shape as ConcavePolygonShape3D).get_faces()
		@warning_ignore("integer_division")
		var tri_count: int = tris.size() / 3
		var tolerance: float = maxf(_grid_cell_size * 0.01, 0.0005)

		for face_range: Vector2i in _mesh_face_ranges:
			if face_range.y != tri_count or tri_count == 0:
				continue
			# Same triangle count: confirm the triangles really coincide, in order.
			var matches: bool = true
			var step: int = maxi(tri_count / 24, 1)
			var t: int = 0
			while t < tri_count and matches:
				for k: int in range(3):
					var shape_vert: Vector3 = node.transform * tris[t * 3 + k]
					var b: int = (face_range.x + t) * 3
					var d: float = minf(shape_vert.distance_to(_face_verts[b]),
						minf(shape_vert.distance_to(_face_verts[b + 1]), shape_vert.distance_to(_face_verts[b + 2])))
					if d > tolerance:
						matches = false
						break
				t += step
			if matches:
				result = face_range.x
				break

	_shape_face_offsets[shape_index] = result
	return result


func _find_uv_at_position(local_pos: Vector3, hint_normal: Vector3 = Vector3.ZERO) -> Vector2:
	if _face_verts.is_empty():
		return Vector2(-1, -1)

	var closest_uv: Vector2 = Vector2(-1, -1)
	var closest_dist: float = INF
	var closest_dot: float = -2.0
	var use_hint: bool = hint_normal != Vector3.ZERO

	var cx: int = int(floor(local_pos.x / _grid_cell_size))
	var cy: int = int(floor(local_pos.y / _grid_cell_size))
	var cz: int = int(floor(local_pos.z / _grid_cell_size))

	for radius: int in [1, 2, 3]:
		var faces_seen: Dictionary = {}

		for dx: int in range(-radius, radius + 1):
			for dy: int in range(-radius, radius + 1):
				for dz: int in range(-radius, radius + 1):
					var key: Vector3i = Vector3i(cx + dx, cy + dy, cz + dz)
					if not _face_grid.has(key):
						continue
					for face_idx: int in _face_grid[key]:
						if faces_seen.has(face_idx):
							continue
						faces_seen[face_idx] = true

						var b: int = face_idx * 3
						var v0: Vector3 = _face_verts[b]
						var v1: Vector3 = _face_verts[b + 1]
						var v2: Vector3 = _face_verts[b + 2]
						var normal: Vector3 = (v2 - v0).cross(v1 - v0)
						if normal.length_squared() < 1e-14:
							continue  # degenerate triangle

						var closest_on_tri: Vector3 = _closest_point_on_triangle(local_pos, v0, v1, v2)
						var dist: float = local_pos.distance_to(closest_on_tri)

						# Among near-tied faces (thin walls, coplanar seams), prefer the one
						# whose facing matches the raycast normal. Godot winds front faces
						# clockwise, so the OUTWARD normal is cross(v2-v0, v1-v0).
						var face_dot: float = 0.0
						if use_hint:
							face_dot = normal.normalized().dot(hint_normal)

						var better: bool = dist < closest_dist - FACE_TIE_EPS
						if not better and use_hint and dist < closest_dist + FACE_TIE_EPS and face_dot > closest_dot:
							better = true

						if better:
							closest_dist = dist
							closest_dot = face_dot
							var bary: Vector3 = _barycentric(closest_on_tri, v0, v1, v2)
							closest_uv = _face_uvs[b] * bary.x + _face_uvs[b + 1] * bary.y + _face_uvs[b + 2] * bary.z

		if closest_dist < _grid_cell_size * 2.0:
			return closest_uv

	return closest_uv


func _closest_point_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab: Vector3 = b - a
	var ac: Vector3 = c - a
	var ap: Vector3 = p - a
	var d1: float = ab.dot(ap)
	var d2: float = ac.dot(ap)

	if d1 <= 0.0 and d2 <= 0.0:
		return a

	var bp: Vector3 = p - b
	var d3: float = ab.dot(bp)
	var d4: float = ac.dot(bp)

	if d3 >= 0.0 and d4 <= d3:
		return b

	var vc: float = d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))

	var cp: Vector3 = p - c
	var d5: float = ab.dot(cp)
	var d6: float = ac.dot(cp)

	if d6 >= 0.0 and d5 <= d6:
		return c

	var vb: float = d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))

	var va: float = d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))

	var sum: float = va + vb + vc
	if absf(sum) < 1e-20:
		return a  # degenerate triangle
	var denom: float = 1.0 / sum
	return a + ab * (vb * denom) + ac * (vc * denom)


func _barycentric(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0: Vector3 = b - a
	var v1: Vector3 = c - a
	var v2: Vector3 = p - a
	var d00: float = v0.dot(v0)
	var d01: float = v0.dot(v1)
	var d11: float = v1.dot(v1)
	var d20: float = v2.dot(v0)
	var d21: float = v2.dot(v1)
	var denom: float = d00 * d11 - d01 * d01

	# Relative test: a fixed epsilon would misfire on small (but valid) triangles
	if absf(denom) <= 1e-9 * d00 * d11 or denom == 0.0:
		return Vector3(1, 0, 0)

	var v: float = (d11 * d20 - d01 * d21) / denom
	var w: float = (d00 * d21 - d01 * d20) / denom
	return Vector3(1.0 - v - w, v, w)

# =============================================================================
# HELPERS
# =============================================================================

func _calculate_zone_progress(zone: Dictionary) -> float:
	if zone["completed"]:
		return 1.0
	var rust_progress: float = 1.0 - (zone["rust_remaining"] / zone["rust_total"])
	var metal_progress: float = 1.0 - (zone["metal_remaining"] / zone["metal_total"])
	return clampf((rust_progress + metal_progress) / 2.0, 0.0, 1.0)


func _color_distance(a: Color, b: Color) -> float:
	var rd: float = a.r - b.r
	var gd: float = a.g - b.g
	var bd: float = a.b - b.b
	return rd * rd + gd * gd + bd * bd


func _has_zone_name(zone_key: String) -> bool:
	if zone_names.has(zone_key):
		return true
	for key: Variant in zone_names.keys():
		if key is Color and _color_to_hex(key) == zone_key:
			return true
	return false


func _get_zone_display_name(zone_key: String) -> String:
	if zone_names.has(zone_key):
		return zone_names[zone_key]
	for key: Variant in zone_names.keys():
		if key is Color and _color_to_hex(key) == zone_key:
			return zone_names[key]
	if _zone_auto_names.has(zone_key):
		return _zone_auto_names[zone_key]
	return zone_key


func _color_to_hex(color: Color) -> String:
	return "%02x%02x%02x" % [int(round(color.r * 255)), int(round(color.g * 255)), int(round(color.b * 255))]


func _hex_to_color(hex: String) -> Color:
	return Color(
		float(("0x" + hex.substr(0, 2)).hex_to_int()) / 255.0,
		float(("0x" + hex.substr(2, 2)).hex_to_int()) / 255.0,
		float(("0x" + hex.substr(4, 2)).hex_to_int()) / 255.0
	)


## Dirt vision on: every mesh swaps to its see-through material, where the
## remaining dirt glows (also through the model). Off: back to normal.
func _on_dirt_vision_changed(enabled: bool) -> void:
	_vision_on = enabled
	for slot: Dictionary in _vision_slots:
		var mesh_instance: MeshInstance3D = slot["instance"]
		if not is_instance_valid(mesh_instance):
			continue
		mesh_instance.set_surface_override_material(surface_index, slot["vision"] if enabled else slot["override"])
		(slot["shadow"] as MeshInstance3D).visible = enabled


## True while this object is shown in dirt vision.
func is_dirt_vision_on() -> bool:
	return _vision_on
