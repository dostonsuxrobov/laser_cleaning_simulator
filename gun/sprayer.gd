extends Node3D
## Sprayer - traces the laser beam and tells cleanable objects where it lands.
##
## The beam is a cylinder of brush radius around the view ray. Besides the
## centre ray, a handful of rays spread across that cylinder find out what the
## beam really touches, which gives three things a single ray cannot:
##  - the depth range of the lit surface, so steeply angled surfaces are cleaned
##    across the whole ring while hidden layers behind them are left alone;
##  - near-miss cleaning: the beam still works when only its edge overlaps a
##    part (thin parts and silhouettes no longer need pixel-perfect aim);
##  - honest feedback: sparks and crackle only while dirt is actually burning.

signal target_changed(zone_name: String, progress: float, completed: bool)
signal target_lost()
signal brush_size_changed(new_radius: float)
signal hit_dirty_surface(is_dirty: bool)

@export_group("Laser Settings")
@export var spray_range: float = 10.0
@export_range(0.1, 5.0, 0.1) var laser_intensity: float = 1.0

@export_group("Brush Size")
@export var brush_radius_min: float = 0.03
@export var brush_radius_max: float = 0.15
@export var brush_radius_step: float = 0.015

@export_group("Distance Falloff")
@export var optimal_distance: float = 2.0
@export var max_distance: float = 8.0

# Sample rays across the beam, as (radius fraction, angle) pairs.
const INNER_RING: float = 0.5
const OUTER_RING: float = 0.9
const INNER_SAMPLES: int = 4
const OUTER_SAMPLES: int = 8
# Largest depth step between neighbouring samples that still counts as one
# continuous surface (in beam radii). Covers surfaces tilted up to ~70 degrees.
const SURFACE_JUMP_RADII: float = 1.2
const SURFACE_JUMP_MIN: float = 0.02
# Slack around the sampled surface, toward the laser and away from it.
const FRONT_PAD_RADII: float = 1.0
const FRONT_PAD_MIN: float = 0.02
const BACK_PAD_RADII: float = 0.35
const BACK_PAD_MIN: float = 0.01

var _camera: Camera3D
var _laser_beam: Node3D
var _laser_impact: Node3D
var _laser_particles: Node3D
var _laser_active: bool = false
var _brush_radius: float = 0.075
var _is_contacting: bool = false

var _current_zone_key: String = ""
var _aimed_cleanable: Node3D = null
var _exclude: Array[RID] = []
var _sample_offsets := PackedVector2Array()


func _ready() -> void:
	add_to_group("sprayer")
	_camera = get_viewport().get_camera_3d()
	_laser_beam = $LaserBeam
	_laser_impact = $LaserImpact
	_brush_radius = clampf(_brush_radius, brush_radius_min, brush_radius_max)
	_setup_particles()
	_setup_samples()
	_setup_exclusions()


func _setup_particles() -> void:
	var particles_scene := preload("res://player/laser_particles.tscn")
	_laser_particles = particles_scene.instantiate()
	add_child(_laser_particles)


func _setup_samples() -> void:
	_sample_offsets.clear()
	for i: int in range(INNER_SAMPLES):
		var a: float = TAU * (float(i) + 0.5) / INNER_SAMPLES
		_sample_offsets.append(Vector2(cos(a), sin(a)) * INNER_RING)
	for i: int in range(OUTER_SAMPLES):
		var a: float = TAU * float(i) / OUTER_SAMPLES
		_sample_offsets.append(Vector2(cos(a), sin(a)) * OUTER_RING)


## The beam must never hit the body that carries the gun.
func _setup_exclusions() -> void:
	var node: Node = get_parent()
	while node:
		if node is CollisionObject3D:
			_exclude.append((node as CollisionObject3D).get_rid())
		node = node.get_parent()


## Leaving the scene mid-burst (restart, quit) must not leave the crackle
## loop playing or a ring painted on the surface.
func _exit_tree() -> void:
	_stop_contact()
	if is_instance_valid(_aimed_cleanable) and _aimed_cleanable.has_method("clear_aim"):
		_aimed_cleanable.clear_aim()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_laser_active = not _laser_active

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_set_brush_radius(_brush_radius + brush_radius_step)

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_set_brush_radius(_brush_radius - brush_radius_step)


func _set_brush_radius(radius: float) -> void:
	_brush_radius = clampf(radius, brush_radius_min, brush_radius_max)
	brush_size_changed.emit(_brush_radius)


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_3d()
		if not _camera:
			return

	var beam: Dictionary = _trace_beam()
	var firing: bool = _laser_active or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

	_update_target(beam)
	_update_aim(beam, firing)

	if firing:
		_fire(beam, delta)
	else:
		_stop_firing(beam)

# =============================================================================
# BEAM TRACE
# =============================================================================

func _cast(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = _exclude
	return space.intersect_ray(query)


## Follows the beam into the scene. Result keys:
##   origin, dir      beam start and direction
##   end              where the centre ray stops (for the beam visual)
##   cleanable        the cleanable the beam touches, or null
##   point            point on the beam axis where it lands on the cleanable
##   front, back      depth range of the lit surface around `point`
##   hit, normal, shape, face   one real surface hit (centre ray if it landed
##                    on the cleanable, otherwise the nearest sample ray)
##   samples          every surface hit on the cleanable (dirt feedback)
func _trace_beam() -> Dictionary:
	var space := get_world_3d().direct_space_state
	var origin: Vector3 = _camera.global_position
	var cam_basis: Basis = _camera.global_basis
	var dir: Vector3 = -cam_basis.z
	var reach: Vector3 = dir * spray_range

	var beam: Dictionary = {
		"origin": origin, "dir": dir, "end": origin + reach,
		"cleanable": null, "samples": [],
	}

	var center: Dictionary = _cast(space, origin, origin + reach)
	var target: Node3D = null
	var center_on_target: bool = false
	if not center.is_empty():
		beam["end"] = center.position
		var collider := center.collider as Node3D
		if collider and collider.has_method("clean_at"):
			target = collider
			center_on_target = true

	# Spread rays across the beam
	var hits: Array[Dictionary] = []
	for offset: Vector2 in _sample_offsets:
		var from: Vector3 = origin + (cam_basis.x * offset.x + cam_basis.y * offset.y) * _brush_radius
		var hit: Dictionary = _cast(space, from, from + reach)
		if hit.is_empty():
			continue
		var collider := hit.collider as Node3D
		if collider and collider.has_method("clean_at"):
			hit["depth"] = (hit.position - origin).dot(dir)
			hits.append(hit)

	if not target:
		# Near miss: the centre ray passed by, but the beam's edge touches something.
		var nearest: float = INF
		for hit: Dictionary in hits:
			if hit["depth"] < nearest:
				nearest = hit["depth"]
				target = hit.collider
		if not target:
			return beam

	var depths: Array[float] = []
	var representative: Dictionary = center if center_on_target else {}
	for hit: Dictionary in hits:
		if hit.collider != target:
			continue
		depths.append(hit["depth"])
		beam["samples"].append(hit)
		if not center_on_target and (representative.is_empty() or hit["depth"] < representative["depth"]):
			representative = hit

	var depth0: float = (center.position - origin).dot(dir) if center_on_target else float(representative["depth"])
	depths.sort()

	# Toward the laser: anything the beam touches in front of the hit is lit.
	var nearest_depth: float = depth0 if depths.is_empty() else minf(depth0, depths[0])
	# Away from the laser: follow the surface only while it stays continuous,
	# so a far part glimpsed past an edge does not open the beam to hidden layers.
	var jump: float = maxf(_brush_radius * SURFACE_JUMP_RADII, SURFACE_JUMP_MIN)
	var farthest_depth: float = depth0
	for d: float in depths:
		if d <= farthest_depth:
			continue
		if d - farthest_depth > jump:
			break
		farthest_depth = d

	beam["cleanable"] = target
	beam["point"] = origin + dir * depth0
	beam["distance"] = depth0
	beam["front"] = (depth0 - nearest_depth) + maxf(_brush_radius * FRONT_PAD_RADII, FRONT_PAD_MIN)
	beam["back"] = (farthest_depth - depth0) + maxf(_brush_radius * BACK_PAD_RADII, BACK_PAD_MIN)
	beam["hit"] = representative.position
	beam["normal"] = representative.normal
	beam["shape"] = representative.get("shape", -1)
	beam["face"] = representative.get("face_index", -1)
	if center_on_target:
		beam["samples"].append(center)
	return beam

# =============================================================================
# TARGET INFO + AIM RING
# =============================================================================

func _update_target(beam: Dictionary) -> void:
	var cleanable: Node3D = beam["cleanable"]
	if not cleanable:
		_clear_target()
		hit_dirty_surface.emit(false)
		return

	var dirty: bool = _beam_touches_dirt(beam)
	beam["dirty"] = dirty

	var zone_info: Dictionary = {}
	if cleanable.has_method("get_zone_at_position"):
		zone_info = cleanable.get_zone_at_position(beam["hit"], beam["normal"], beam["shape"], beam["face"])

	if zone_info.is_empty():
		_clear_target()
	else:
		_current_zone_key = zone_info["key"]
		target_changed.emit(zone_info["name"], zone_info["progress"], zone_info["completed"])

	hit_dirty_surface.emit(dirty)


## Is there still dirt anywhere under the beam?
func _beam_touches_dirt(beam: Dictionary) -> bool:
	var cleanable: Node3D = beam["cleanable"]
	if not cleanable.has_method("has_dirt_at"):
		return false
	if cleanable.has_dirt_at(beam["hit"], beam["normal"], beam["shape"], beam["face"]):
		return true
	for hit: Dictionary in beam["samples"]:
		if cleanable.has_dirt_at(hit.position, hit.normal, hit.get("shape", -1), hit.get("face_index", -1)):
			return true
	return false


func _clear_target() -> void:
	if _current_zone_key != "":
		_current_zone_key = ""
		target_lost.emit()


## The ring is drawn by the cleanable's own shader with the exact beam the
## brush uses, so it always outlines what will be cleaned.
func _update_aim(beam: Dictionary, firing: bool) -> void:
	var cleanable: Node3D = beam["cleanable"]
	if is_instance_valid(_aimed_cleanable) and _aimed_cleanable != cleanable and _aimed_cleanable.has_method("clear_aim"):
		_aimed_cleanable.clear_aim()
	_aimed_cleanable = cleanable

	if cleanable and cleanable.has_method("set_aim"):
		var in_range: bool = _calculate_effectiveness(beam["distance"]) > 0.0
		cleanable.set_aim(beam["point"], beam["dir"], _brush_radius, beam["front"], beam["back"], firing and in_range)

# =============================================================================
# FIRING
# =============================================================================

func _fire(beam: Dictionary, delta: float) -> void:
	var cleanable: Node3D = beam["cleanable"]
	_laser_beam.show_beam(global_position, beam["end"])

	if not cleanable:
		_end_contact()
		return

	var effectiveness: float = _calculate_effectiveness(beam["distance"])
	cleanable.clean_at(
		beam["point"], beam["dir"], laser_intensity, effectiveness, delta,
		_brush_radius, _get_pressure_multiplier(), beam["front"], beam["back"]
	)

	_laser_impact.show_impact(beam["hit"], beam["normal"], _brush_radius)
	_laser_impact.set_firing(effectiveness > 0.0)

	# Sparks and crackle only while there is dirt left to burn under the beam.
	if beam.get("dirty", false) and effectiveness > 0.0:
		_start_contact()
		_show_particles(beam["hit"], beam["normal"])
	else:
		_stop_contact()
		_hide_particles()


func _stop_firing(beam: Dictionary) -> void:
	_laser_beam.hide_beam()
	_end_contact()
	var cleanable: Node3D = beam["cleanable"]
	if cleanable and cleanable.has_method("end_stroke"):
		cleanable.end_stroke()


func _end_contact() -> void:
	_laser_impact.set_firing(false)
	_laser_impact.hide_impact()
	_hide_particles()
	_stop_contact()


func _start_contact() -> void:
	if not _is_contacting:
		_is_contacting = true
		AudioManager.start_contact()


func _stop_contact() -> void:
	if _is_contacting:
		_is_contacting = false
		AudioManager.stop_contact()


func _calculate_effectiveness(distance: float) -> float:
	if distance > max_distance:
		return 0.0
	if distance <= optimal_distance:
		return 1.0

	var falloff_range: float = maxf(max_distance - optimal_distance, 0.0001)
	return clampf(1.0 - (distance - optimal_distance) / falloff_range, 0.0, 1.0)


## Small brush = focused beam (more power per area), large brush = wide and soft.
func _get_pressure_multiplier() -> float:
	var size_range: float = maxf(brush_radius_max - brush_radius_min, 0.0001)
	var normalized: float = clampf((_brush_radius - brush_radius_min) / size_range, 0.0, 1.0)
	return lerpf(2.2, 0.8, normalized)


func _hide_particles() -> void:
	if _laser_particles and _laser_particles.has_method("hide_particles"):
		_laser_particles.hide_particles()


func _show_particles(pos: Vector3, normal: Vector3) -> void:
	if _laser_particles and _laser_particles.has_method("show_particles"):
		_laser_particles.show_particles(pos, normal)
