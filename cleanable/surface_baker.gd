class_name SurfaceBaker
extends RefCounted
## CPU rasterizer: bakes per-texel body-local position + normal maps from mesh faces.
## Runs on a worker thread at load. Output feeds the world-space brush shader, so
## painting happens by true 3D distance instead of UV-space discs.

# Flat face layout: v0 v1 v2 (9 floats) + n0 n1 n2 (9 floats) + uv0 uv1 uv2 (6 floats)
const FLOATS_PER_FACE: int = 24


## Rasterizes faces into UV space. Returns:
##   position: PackedFloat32Array, 4 floats/texel (xyz body-local, w = coverage)
##   normal:   PackedFloat32Array, 4 floats/texel (xyz body-local, w unused)
##   coverage: PackedByteArray, 1 = real surface, 2 = dilated padding
## `cancel` is an optional one-element array; set cancel[0] = true from another
## thread to abandon the bake early (the result is then incomplete - discard it).
static func bake(faces: PackedFloat32Array, size: int, dilate_radius: int, cancel: Array = []) -> Dictionary:
	var texel_count: int = size * size
	var pos := PackedFloat32Array()
	pos.resize(texel_count * 4)
	var nrm := PackedFloat32Array()
	nrm.resize(texel_count * 4)
	var cov := PackedByteArray()
	cov.resize(texel_count)

	var face_count: int = faces.size() / FLOATS_PER_FACE
	for f: int in range(face_count):
		if not cancel.is_empty() and cancel[0]:
			break
		var o: int = f * FLOATS_PER_FACE
		var ax: float = faces[o + 18] * size
		var ay: float = faces[o + 19] * size
		var bx: float = faces[o + 20] * size
		var by: float = faces[o + 21] * size
		var cx: float = faces[o + 22] * size
		var cy: float = faces[o + 23] * size

		var den: float = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
		if abs(den) < 1e-9:
			continue
		var inv_den: float = 1.0 / den

		var x0: int = clampi(int(floor(min(ax, min(bx, cx)) - 1.0)), 0, size - 1)
		var x1: int = clampi(int(ceil(max(ax, max(bx, cx)) + 1.0)), 0, size - 1)
		var y0: int = clampi(int(floor(min(ay, min(by, cy)) - 1.0)), 0, size - 1)
		var y1: int = clampi(int(ceil(max(ay, max(by, cy)) + 1.0)), 0, size - 1)

		for y: int in range(y0, y1 + 1):
			var py: float = y + 0.5
			var row: int = y * size
			for x: int in range(x0, x1 + 1):
				var px: float = x + 0.5
				var wa: float = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) * inv_den
				if wa < -0.0001:
					continue
				var wb: float = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) * inv_den
				if wb < -0.0001:
					continue
				var wc: float = 1.0 - wa - wb
				if wc < -0.0001:
					continue

				var idx: int = (row + x) * 4
				pos[idx] = wa * faces[o] + wb * faces[o + 3] + wc * faces[o + 6]
				pos[idx + 1] = wa * faces[o + 1] + wb * faces[o + 4] + wc * faces[o + 7]
				pos[idx + 2] = wa * faces[o + 2] + wb * faces[o + 5] + wc * faces[o + 8]
				pos[idx + 3] = 1.0
				nrm[idx] = wa * faces[o + 9] + wb * faces[o + 12] + wc * faces[o + 15]
				nrm[idx + 1] = wa * faces[o + 10] + wb * faces[o + 13] + wc * faces[o + 16]
				nrm[idx + 2] = wa * faces[o + 11] + wb * faces[o + 14] + wc * faces[o + 17]
				nrm[idx + 3] = 1.0
				cov[row + x] = 1

	if cancel.is_empty() or not cancel[0]:
		_dilate(pos, nrm, cov, size, dilate_radius)
	return {"position": pos, "normal": nrm, "coverage": cov}


## Grows the covered region outward one texel per pass (multi-source BFS).
## Padding texels inherit the surface data of their nearest island, which keeps
## bilinear filtering at island edges cleanable and seam-free.
static func _dilate(pos: PackedFloat32Array, nrm: PackedFloat32Array, cov: PackedByteArray, size: int, radius: int) -> void:
	var frontier := PackedInt32Array()
	for i: int in range(size * size):
		if cov[i] != 0:
			frontier.append(i)

	for _pass: int in range(radius):
		if frontier.is_empty():
			break
		var next := PackedInt32Array()
		for i: int in frontier:
			var x: int = i % size
			var y: int = i / size
			for dy: int in range(-1, 2):
				var ny: int = y + dy
				if ny < 0 or ny >= size:
					continue
				for dx: int in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx: int = x + dx
					if nx < 0 or nx >= size:
						continue
					var ni: int = ny * size + nx
					if cov[ni] != 0:
						continue
					var src: int = i * 4
					var dst: int = ni * 4
					pos[dst] = pos[src]
					pos[dst + 1] = pos[src + 1]
					pos[dst + 2] = pos[src + 2]
					pos[dst + 3] = 1.0
					nrm[dst] = nrm[src]
					nrm[dst + 1] = nrm[src + 1]
					nrm[dst + 2] = nrm[src + 2]
					nrm[dst + 3] = 1.0
					cov[ni] = 2
					next.append(ni)
		frontier = next
