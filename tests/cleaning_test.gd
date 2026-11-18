extends Node
## Automated play-test of the cleaning mechanics. Runs the real game scene,
## drives the real sprayer, and checks what ends up in the dirt mask.
##
##   godot --path . res://tests/cleaning_test.tscn
##   godot --path . res://tests/cleaning_test.tscn -- --shots=C:/some/folder
##
## Exits with code 0 when every check passes, 1 otherwise. Needs a real
## renderer (the dirt mask lives on the GPU), so do not run it with --headless.
##
## Checks:
##   startup    surface bake finishes, zones are found, progress starts at 0
##   precision  nothing outside the laser beam is cleaned, everything well
##              inside the aiming ring is - on flat, angled and curved spots
##   stroke     a fast sweep leaves no gaps between frames
##   near miss  the beam still cleans when only its edge overlaps a part
##   zones      completing a zone wipes exactly that zone
##   content    zones carry part names, dirt vision drives glow + overlay
##              together, the pause-menu settings apply and are saved
##   full job   a bot standing where a player can stand cleans everything:
##              every zone completes, the victory plays, the result screen
##              shows, and "play again" starts a fresh job

const TICK: float = 1.0 / 60.0

var _cleanable: Node3D
var _player: CharacterBody3D
var _pivot: Node3D
var _sprayer: Node3D
var _shots: String = ""
var _checks: int = 0
var _fails: int = 0

# Surface data as flat arrays (fast to scan)
var _size: int = 0
var _pos := PackedFloat32Array()
var _nrm := PackedFloat32Array()
var _before := PackedFloat32Array()  # rust channel right after the last reset


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_shots = arg.trim_prefix("--shots=")
			DirAccess.make_dir_recursive_absolute(_shots)
	_boot.call_deferred()


func _process(_delta: float) -> void:
	# Never hold the mouse hostage while the test runs.
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Run the game as the current scene (so restart works) with this node beside it.
func _boot() -> void:
	var tree := get_tree()
	tree.current_scene = null
	var main: Node = load("res://main.tscn").instantiate()
	tree.root.add_child(main)
	tree.current_scene = main

	await _run()

	print("")
	print("RESULT: %d checks, %d failed" % [_checks, _fails])
	tree.paused = false
	tree.quit(1 if _fails > 0 else 0)


func _run() -> void:
	if not await _acquire():
		return
	await _test_startup()
	await _test_precision()
	await _test_stroke()
	await _test_near_miss()
	await _test_zone_wipe()
	await _test_content()
	await _test_full_job()

# =============================================================================
# HELPERS
# =============================================================================

func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  PASS  " + what)
	else:
		_fails += 1
		print("  FAIL  " + what)


func _frames(n: int) -> void:
	for i: int in range(n):
		await get_tree().process_frame


## Finds the game nodes and waits for the surface bake. False on timeout.
func _acquire() -> bool:
	var tree := get_tree()
	_cleanable = null
	var deadline: int = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		await tree.process_frame
		_cleanable = tree.get_first_node_in_group("cleanable")
		_player = tree.get_first_node_in_group("player")
		_sprayer = tree.get_first_node_in_group("sprayer")
		if _cleanable and _player and _sprayer and _cleanable.is_surface_ready():
			break
	if not (_cleanable and _player and _sprayer and _cleanable.is_surface_ready()):
		_check(false, "game scene loads and the surface bake finishes")
		return false

	_pivot = _player.get_node("CameraPivot")
	# The test places the camera itself and ticks the sprayer by hand.
	_player.set_physics_process(false)
	_player.set_process_input(false)
	_sprayer.set_physics_process(false)
	_sprayer.set_process_input(false)

	var pos_img: Image = _cleanable.get("_position_image")
	var nrm_img: Image = _cleanable.get("_normal_image")
	_size = pos_img.get_width()
	_pos = pos_img.get_data().to_float32_array()
	_nrm = nrm_img.get_data().to_float32_array()
	return true


func _aim(eye: Vector3, target: Vector3) -> void:
	var d: Vector3 = (target - eye).normalized()
	_player.global_position = eye - _pivot.position
	_player.rotation = Vector3(0, atan2(-d.x, -d.z), 0)
	_pivot.rotation = Vector3(asin(clampf(d.y, -1.0, 1.0)), 0, 0)
	_player.force_update_transform()
	_pivot.force_update_transform()


func _tick(firing: bool, n: int = 1) -> void:
	_sprayer.set("_laser_active", firing)
	for i: int in range(n):
		_sprayer.call("_physics_process", TICK)


func _mask_rust() -> PackedFloat32Array:
	var img: Image = _cleanable.get_dirt_image()
	img.convert(Image.FORMAT_RF)
	return img.get_data().to_float32_array()


func _reset_dirt() -> void:
	_tick(false)
	_cleanable.get("_paint_viewport").fill_zone_dirt(true)
	_cleanable.end_stroke()
	await _frames(3)
	_before = _mask_rust()


func _shot(label: String) -> void:
	if _shots == "":
		return
	await _frames(3)
	get_viewport().get_texture().get_image().save_png(_shots.path_join(label + ".png"))


func _ray(eye: Vector3, target: Vector3) -> Dictionary:
	var space := get_viewport().get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(eye, eye + (target - eye).normalized() * 12.0)
	query.exclude = [_player.get_rid()]
	return space.intersect_ray(query)


## Nudges an aim point until the whole brush footprint sits on dirt, so a
## precision case never lands on an already-clean patch. Returns the target.
func _dirty_target(eye: Vector3, target: Vector3, radius: float) -> Vector3:
	var dir: Vector3 = (target - eye).normalized()
	var right: Vector3 = dir.cross(Vector3.UP).normalized()
	var up: Vector3 = right.cross(dir).normalized()
	for ring: int in range(0, 9):
		for step: int in range(maxi(ring * 8, 1)):
			var angle: float = TAU * step / maxf(ring * 8, 1)
			var candidate: Vector3 = target + (right * cos(angle) + up * sin(angle)) * ring * 0.03
			var ok: bool = true
			for offset: Vector2 in [Vector2.ZERO, Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
				var hit: Dictionary = _ray(eye, candidate + (right * offset.x + up * offset.y) * radius)
				if hit.is_empty() or hit.collider != _cleanable:
					ok = false
					break
				# exact check against the full-resolution mask
				var uv: Vector2 = _cleanable.call("_uv_from_world", hit.position, hit.normal, hit.get("shape", -1), hit.get("face_index", -1))
				var tx: int = clampi(int(uv.x * _size), 0, _size - 1)
				var ty: int = clampi(int(uv.y * _size), 0, _size - 1)
				if uv.x < 0.0 or _before[tx + ty * _size] < 0.9:
					ok = false
					break
			if ok:
				return candidate
	return target


## Zone id (1-based, 0 = none) of every mask texel, by the same nearest-color
## rule the shaders use.
func _texel_zone_ids() -> PackedByteArray:
	var ids := PackedByteArray()
	ids.resize(_size * _size)
	var zone_tex: Texture2D = _cleanable.get("_zone_texture")
	var colors: PackedVector3Array = _cleanable.get("_zone_colors")
	var count: int = (_cleanable.get("_zone_order") as Array).size()
	if not zone_tex or count == 0:
		return ids
	var img: Image = zone_tex.get_image()
	var data: PackedByteArray = img.get_data()
	var w: int = img.get_width()
	var h: int = img.get_height()
	var cache: Dictionary = {}
	for y: int in range(_size):
		@warning_ignore("integer_division")
		var sy: int = mini((y * 2 + 1) * h / (_size * 2), h - 1)
		for x: int in range(_size):
			if _before[x + y * _size] < 0.9:
				continue
			@warning_ignore("integer_division")
			var sx: int = mini((x * 2 + 1) * w / (_size * 2), w - 1)
			var o: int = (sx + sy * w) * 3
			var packed: int = data[o] | (data[o + 1] << 8) | (data[o + 2] << 16)
			if not cache.has(packed):
				var c := Vector3(data[o], data[o + 1], data[o + 2]) / 255.0
				var best: int = 0
				if maxf(c.x, maxf(c.y, c.z)) >= 0.05:
					var best_dist: float = INF
					for k: int in range(count):
						var dist: float = c.distance_squared_to(colors[k])
						if dist < best_dist:
							best_dist = dist
							best = k + 1
				cache[packed] = best
			ids[x + y * _size] = cache[packed]
	return ids


## Compares the mask against the beam the sprayer reported. Returns counts.
func _measure_beam(beam: Dictionary, radius: float) -> Dictionary:
	var inv: Transform3D = _cleanable.global_transform.affine_inverse()
	var point: Vector3 = inv * (beam["point"] as Vector3)
	var dir: Vector3 = (inv.basis * (beam["dir"] as Vector3)).normalized()
	var front: float = beam["front"]
	var back: float = beam["back"]
	var after: PackedFloat32Array = _mask_rust()

	var out: Dictionary = {"cleaned": 0, "outside": 0, "inner": 0, "inner_cleaned": 0}
	for i: int in range(_size * _size):
		if _before[i] < 0.9 or _pos[i * 4 + 3] < 0.5:
			continue
		var rel := Vector3(_pos[i * 4], _pos[i * 4 + 1], _pos[i * 4 + 2]) - point
		var depth: float = rel.dot(dir)
		var axis_dist: float = (rel - dir * depth).length()
		var in_window: bool = depth >= -front - 0.002 and depth <= back + 0.002
		var cleaned: bool = after[i] < 0.5
		if cleaned:
			out["cleaned"] += 1
			if axis_dist > radius * 1.01 or not in_window:
				out["outside"] += 1
		if axis_dist < radius * 0.6 and depth >= -front and depth <= back:
			var facing: float = Vector3(_nrm[i * 4], _nrm[i * 4 + 1], _nrm[i * 4 + 2]).normalized().dot(-dir)
			if facing > 0.35:
				out["inner"] += 1
				if cleaned:
					out["inner_cleaned"] += 1
	return out

# =============================================================================
# TESTS
# =============================================================================

func _test_startup() -> void:
	print("startup")
	var zones: Dictionary = _cleanable.get("_zones")
	_check(zones.size() >= 1, "zone map produces zones (%d found)" % zones.size())
	var sane: bool = true
	for key: String in zones:
		var zone: Dictionary = zones[key]
		if zone["rust_total"] < zone["total"] * 0.5 or zone["rust_total"] > zone["total"] * 1.01:
			sane = false
	_check(sane, "initial dirt measured for every zone")
	_check(_cleanable.get_total_progress() < 0.001, "progress starts at 0%")
	_aim(Vector3(2.4, 1.5, -2.4), Vector3(-0.3, 0.7, -5.0))
	await _shot("01_start")


func _test_precision() -> void:
	print("precision")
	# [label, where the player's eye is, what they aim at]
	var cases: Array = [
		["straight on", Vector3(2.0, 1.5, -5.0), Vector3(-0.3, 1.05, -5.0)],
		["sloped joint", Vector3(2.0, 1.5, -4.5), Vector3(-0.13, 0.91, -4.5)],
		["steep angle", Vector3(1.2, 1.5, -2.2), Vector3(-0.13, 0.91, -4.5)],
		["from above", Vector3(0.9, 1.5, -4.5), Vector3(-0.2, 1.11, -4.5)],
		["base pillar", Vector3(2.5, 1.5, -7.1), Vector3(0.39, 0.6, -7.1)],
		["end cap", Vector3(0.0, 1.5, -1.0), Vector3(-0.07, 0.55, -3.0)],
		["grazing", Vector3(0.75, 1.25, -2.9), Vector3(-0.13, 0.95, -4.6)],
	]
	for case: Array in cases:
		for radius: float in [0.03, 0.15]:
			await _reset_dirt()
			_sprayer.set("_brush_radius", radius)
			var eye: Vector3 = case[1]
			var target: Vector3 = _dirty_target(eye, case[2], radius)
			if case[0] == "straight on":
				# stand exactly along the surface normal of the aimed spot
				var first: Dictionary = _ray(eye, target)
				if not first.is_empty():
					target = first.position
					eye = target + (first.normal as Vector3) * 1.5
			_aim(eye, target)
			var beam: Dictionary = _sprayer.call("_trace_beam")
			if beam["cleanable"] != _cleanable:
				_check(false, "%s r=%.2f: aim lands on the cleanable" % [case[0], radius])
				continue
			_tick(true, 45)
			_tick(false)
			await _frames(3)
			var m: Dictionary = _measure_beam(beam, radius)
			var label: String = "%s, %.0f cm brush" % [case[0], radius * 100.0]
			_check(m["outside"] == 0, "%s: nothing cleaned outside the beam (%d stray of %d)" % [label, m["outside"], m["cleaned"]])
			var share: float = float(m["inner_cleaned"]) / maxf(m["inner"], 1)
			if m["inner"] > 0 or case[0] == "straight on":
				_check(m["inner"] > 0 and share >= 0.99, "%s: inside of the ring fully cleaned (%d of %d)" % [label, m["inner_cleaned"], m["inner"]])
	_sprayer.set("_brush_radius", 0.075)


func _test_stroke() -> void:
	print("stroke")
	await _reset_dirt()
	var radius: float = 0.05
	_sprayer.set("_brush_radius", radius)
	var eye := Vector3(1.6, 1.4, -4.4)
	var hit: Dictionary = _ray(eye, Vector3(-0.2, 0.95, -4.4))
	var along := Vector3(0, 0, 1)  # sweep along the arm
	var a: Vector3 = hit.position - along * 0.3
	var b: Vector3 = hit.position + along * 0.3
	# 0.6 m in 6 ticks = 6 m/s: every tick jumps a full brush diameter
	_cleanable.end_stroke()
	for i: int in range(7):
		_aim(eye, a.lerp(b, i / 6.0))
		_tick(true)
	_tick(false)
	await _frames(3)

	# Every dirty texel near the path centre line must have been touched.
	var inv: Transform3D = _cleanable.global_transform.affine_inverse()
	var la: Vector3 = inv * a
	var lb: Vector3 = inv * b
	var after: PackedFloat32Array = _mask_rust()
	var on_path: int = 0
	var touched: int = 0
	for i: int in range(_size * _size):
		if _before[i] < 0.9 or _pos[i * 4 + 3] < 0.5:
			continue
		var p := Vector3(_pos[i * 4], _pos[i * 4 + 1], _pos[i * 4 + 2])
		var t: float = clampf((p - la).dot(lb - la) / (lb - la).length_squared(), 0.0, 1.0)
		if t < 0.05 or t > 0.95 or p.distance_to(la.lerp(lb, t)) > radius * 0.3:
			continue
		on_path += 1
		if after[i] < _before[i] - 0.01:
			touched += 1
	_check(on_path > 50 and touched == on_path, "fast sweep is gap-free (%d of %d path texels touched)" % [touched, on_path])
	_sprayer.set("_brush_radius", 0.075)


func _test_near_miss() -> void:
	print("near miss")
	await _reset_dirt()
	var radius: float = 0.1
	_sprayer.set("_brush_radius", radius)
	var eye := Vector3(2.0, 1.1, -4.5)
	# Raise the aim until the centre ray just leaves the top edge of the arm.
	var y: float = 0.9
	while y < 1.7:
		var hit: Dictionary = _ray(eye, Vector3(-0.3, y, -4.5))
		if hit.is_empty() or hit.collider != _cleanable:
			break
		y += 0.01
	_aim(eye, Vector3(-0.3, y + 0.02, -4.5))
	var centre: Dictionary = _ray(eye, Vector3(-0.3, y + 0.02, -4.5))
	var beam: Dictionary = _sprayer.call("_trace_beam")
	_check(centre.is_empty() or centre.collider != _cleanable, "crosshair is off the part")
	_check(beam["cleanable"] == _cleanable, "beam edge still registers the part")
	if beam["cleanable"] == _cleanable:
		_tick(true, 45)
		_tick(false)
		await _frames(3)
		var m: Dictionary = _measure_beam(beam, radius)
		_check(m["cleaned"] > 50 and m["outside"] == 0, "edge of the beam cleans, and only inside the ring (%d texels, %d stray)" % [m["cleaned"], m["outside"]])
		await _shot("02_near_miss")
	_sprayer.set("_brush_radius", 0.075)


func _test_zone_wipe() -> void:
	print("zone completion")
	await _reset_dirt()
	var zones: Dictionary = _cleanable.get("_zones")
	var order: Array = _cleanable.get("_zone_order")
	if order.is_empty():
		_check(false, "at least one zone exists")
		return
	var key: String = order[0]
	var zone_id: int = zones[key]["id"]
	var ids: PackedByteArray = _texel_zone_ids()

	var completed: Array = []
	var on_done := func(_color: Color, _where: Vector3) -> void: completed.append(true)
	_cleanable.zone_completed.connect(on_done)
	_cleanable.call("_complete_zone", key)
	await _frames(2)
	await _shot("03_zone_flash")
	await _frames(2)
	_cleanable.zone_completed.disconnect(on_done)

	var after: PackedFloat32Array = _mask_rust()
	var in_zone: int = 0
	var left_in_zone: int = 0
	var lost_elsewhere: int = 0
	for i: int in range(_size * _size):
		if _before[i] < 0.9:
			continue
		if ids[i] == zone_id:
			in_zone += 1
			if after[i] > 0.5:
				left_in_zone += 1
		elif after[i] < 0.5:
			lost_elsewhere += 1
	_check(completed.size() == 1, "zone_completed signal fires once")
	_check(in_zone > 0 and left_in_zone == 0, "completed zone is wiped clean (%d of %d texels still dirty)" % [left_in_zone, in_zone])
	_check(lost_elsewhere == 0, "other zones keep their dirt (%d texels lost)" % lost_elsewhere)
	_check(zones[key]["completed"] and _cleanable.get_zones_state()[key]["progress"] == 1.0, "zone reports 100%")

	# put the job back to its untouched state for the full run
	zones[key]["completed"] = false
	await _reset_dirt()
	_cleanable.call("_request_measure")
	await _frames(6)


func _find_sliders(node: Node, out: Array) -> void:
	for child: Node in node.get_children():
		if child is HSlider:
			out.append(child)
		_find_sliders(child, out)


func _press_escape() -> void:
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	Input.parse_input_event(esc)
	await _frames(3)


func _test_content() -> void:
	print("content")
	var names: Array = []
	var state: Dictionary = _cleanable.get_zones_state()
	for key: String in state:
		names.append(state[key]["name"])
	_check(names == ["Base", "Lower Arm", "Elbow", "Forearm", "Wrist"], "zones carry part names (%s)" % ", ".join(names))

	# Dirt vision: surface glow and screen overlay follow one switch
	var overlay: CanvasItem = get_tree().current_scene.get_node_or_null("DirtVisionOverlay/Overlay")
	var material: ShaderMaterial = (_cleanable.get("_materials") as Array)[0]
	DirtVision.set_enabled(true)
	await _frames(2)
	var on: bool = overlay != null and overlay.visible and material.get_shader_parameter("dirt_vision_enabled")
	await _shot("03b_dirt_vision")
	DirtVision.set_enabled(false)
	await _frames(2)
	var off: bool = overlay != null and not overlay.visible and not material.get_shader_parameter("dirt_vision_enabled")
	_check(on and off, "dirt vision switches the surface glow and the screen overlay together")

	# Settings in the pause menu (the player's real settings are restored afterwards)
	var saved_sensitivity: float = GameSettings.mouse_sensitivity
	var saved_volume: float = GameSettings.master_volume
	await _press_escape()
	var sliders: Array = []
	_find_sliders(get_tree().current_scene.get_node("GameFlow"), sliders)
	_check(get_tree().paused and sliders.size() == 2, "pause menu offers sensitivity and volume sliders")
	if sliders.size() == 2:
		(sliders[0] as HSlider).value = 2.0
		(sliders[1] as HSlider).value = 0.25
		await _shot("03c_settings")
		var bus: int = AudioServer.get_bus_index("Master")
		_check(is_equal_approx(GameSettings.mouse_sensitivity, 2.0), "sensitivity slider changes the setting")
		_check(is_equal_approx(GameSettings.master_volume, 0.25) and absf(AudioServer.get_bus_volume_db(bus) - linear_to_db(0.25)) < 0.01, "volume slider changes the master volume")

		# mouse look really scales with the setting
		var motion := InputEventMouseMotion.new()
		motion.relative = Vector2(100, 0)
		var yaw_before: float = _player.rotation.y
		_player.call("_input", motion)
		var turned: float = absf(_player.rotation.y - yaw_before)
		_check(is_equal_approx(turned, 100.0 * _player.mouse_sensitivity * 2.0), "mouse look follows the sensitivity setting")
	await _press_escape()
	var config := ConfigFile.new()
	var loaded: bool = config.load(GameSettings.PATH) == OK
	_check(not get_tree().paused and loaded and is_equal_approx(float(config.get_value("audio", "master_volume", -1.0)), 0.25),
		"closing the pause menu saves the settings")
	GameSettings.set_mouse_sensitivity(saved_sensitivity)
	GameSettings.set_master_volume(saved_volume)
	GameSettings.save_settings()


## Eye positions a player can really reach: a walk around the object,
## standing, crouched, and at the top of a jump.
func _viewpoints(mn: Vector3, mx: Vector3) -> Array[Vector3]:
	var ring: Array[Vector2] = []
	var margin: float = 1.0
	var step: float = 0.6
	var x: float = mn.x - margin
	while x < mx.x + margin:
		ring.append(Vector2(x, mn.z - margin))
		ring.append(Vector2(x, mx.z + margin))
		x += step
	var z: float = mn.z - margin
	while z < mx.z + margin:
		ring.append(Vector2(mn.x - margin, z))
		ring.append(Vector2(mx.x + margin, z))
		z += step
	var points: Array[Vector3] = []
	for height: float in [1.5, 1.0, 2.25]:
		for r: Vector2 in ring:
			points.append(Vector3(r.x, height, r.y))
	return points


func _test_full_job() -> void:
	print("full job")
	var space := get_viewport().get_world_3d().direct_space_state
	var xform: Transform3D = _cleanable.global_transform

	# One aim target per 6 cm of dirty surface
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	var seen: Dictionary = {}
	var targets: Array[Vector3] = []
	var normals: Array[Vector3] = []
	for i: int in range(_size * _size):
		if _before[i] < 0.9 or _pos[i * 4 + 3] < 0.5:
			continue
		var wp: Vector3 = xform * Vector3(_pos[i * 4], _pos[i * 4 + 1], _pos[i * 4 + 2])
		mn = mn.min(wp)
		mx = mx.max(wp)
		var voxel := Vector3i((wp / 0.06).floor())
		if seen.has(voxel):
			continue
		seen[voxel] = true
		targets.append(wp)
		normals.append((xform.basis * Vector3(_nrm[i * 4], _nrm[i * 4 + 1], _nrm[i * 4 + 2])).normalized())

	# Aim at each target from the two viewpoints that see it most head-on
	var eyes: Array[Vector3] = _viewpoints(mn, mx)
	var jobs: Array = []
	for i: int in range(targets.size()):
		var candidates: Array = []
		for e: int in range(eyes.size()):
			var to_eye: Vector3 = eyes[e] - targets[i]
			var dist: float = to_eye.length()
			if dist > 2.6 or dist < 0.35:
				continue
			var facing: float = normals[i].dot(to_eye / dist)
			if facing >= 0.15:
				candidates.append([facing - dist * 0.05, e])
		candidates.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0])
		var used: int = 0
		for candidate: Array in candidates:
			var eye: Vector3 = eyes[candidate[1]]
			var query := PhysicsRayQueryParameters3D.create(eye, eye + (targets[i] - eye) * 1.05)
			query.exclude = [_player.get_rid()]
			var hit: Dictionary = space.intersect_ray(query)
			if hit.is_empty() or hit.collider != _cleanable or hit.position.distance_to(targets[i]) > 0.03:
				continue
			jobs.append([candidate[1], targets[i]])
			used += 1
			if used >= 2:
				break
	jobs.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])

	# Leave dirt vision on: a clean object is invisible in it, so the game has
	# to switch it off by itself for the victory animation.
	DirtVision.set_enabled(true)

	# Fire. Extra power only shortens the run; where the beam can reach is unchanged.
	var normal_intensity: float = _sprayer.laser_intensity
	_sprayer.laser_intensity = normal_intensity * 5.0
	_sprayer.set("_brush_radius", 0.1)
	var count: int = 0
	for job: Array in jobs:
		_cleanable.end_stroke()
		_aim(eyes[job[0]], job[1])
		_tick(true, 3)
		count += 1
		if count % 12 == 0:
			await get_tree().process_frame
		if count == jobs.size() / 2:
			await _shot("04_half_done")
	_tick(false)
	_sprayer.laser_intensity = normal_intensity
	await _frames(40)

	var zones: Dictionary = _cleanable.get("_zones")
	var all_done: bool = true
	for key: String in zones:
		if not zones[key]["completed"]:
			all_done = false
			print("        zone %s stuck at %.1f%%" % [key, _cleanable.get_zones_state()[key]["progress"] * 100.0])
	_check(all_done, "every zone completes from positions a player can reach (%d aims)" % jobs.size())
	_check(_cleanable.get_total_progress() > 0.999, "overall progress reaches 100%")
	_check(_cleanable.get("_victory_triggered"), "victory is triggered")
	_check(not DirtVision.enabled, "dirt vision switches off for the victory")
	_aim(Vector3(2.4, 1.5, -2.4), Vector3(-0.3, 0.7, -5.0))
	await _shot("05_all_clean")

	# Victory animation -> job complete -> result screen
	var waited: int = 0
	while GameManager.current_state != GameManager.State.COMPLETED and waited < 60 * 30:
		await get_tree().process_frame
		waited += 1
	_check(GameManager.current_state == GameManager.State.COMPLETED, "job completes after the victory animation")
	await _frames(20)
	var result_ui: Node = null
	for node: Node in get_tree().current_scene.get_node("GameFlow").get_children():
		if node.has_method("show_results"):
			result_ui = node
	_check(result_ui != null and get_tree().paused, "result screen is shown and the game is paused")
	await _shot("06_job_complete")
	if not result_ui:
		return

	# Play again -> a fresh, dirty job
	result_ui.call("_on_restart_pressed")
	await _frames(5)
	var fresh: bool = await _acquire()
	_check(fresh, "play again reloads the job and the laser comes back online")
	if not fresh:
		return
	var any_done: bool = false
	for key: String in (_cleanable.get("_zones") as Dictionary):
		if _cleanable.get("_zones")[key]["completed"]:
			any_done = true
	_check(not any_done and _cleanable.get_total_progress() < 0.001, "new job starts fully dirty at 0%")
	_check(GameManager.current_state == GameManager.State.PLAYING and not get_tree().paused, "new job is running")

	# Pause menu opens and closes
	await _press_escape()
	var was_paused: bool = get_tree().paused
	await _shot("07_pause_menu")
	await _press_escape()
	_check(was_paused and not get_tree().paused, "ESC opens and closes the pause menu")

	# Restarting while the surface is still baking must not hang or crash
	GameManager.restart_job()
	await _frames(2)
	GameManager.restart_job()
	await _frames(5)
	_check(await _acquire(), "restarting during the surface bake recovers cleanly")
