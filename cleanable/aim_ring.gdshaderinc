// Laser aim, shared by every shader that draws a cleanable surface.
// The ring is drawn with the very same beam test the brush shader uses
// (world_brush.gdshader), so it outlines exactly what the laser will clean.
// All values are in world space and are set by cleanable_mesh.gd.

uniform float aim_visible = 0.0;  // 0 = no ring
uniform float aim_firing = 0.0;   // 0..1, adds the hot glow under the beam
uniform vec3 aim_point = vec3(0.0);
uniform vec3 aim_dir = vec3(0.0, 0.0, -1.0);
uniform float aim_radius = 0.075;
uniform float aim_depth_front = 0.2;
uniform float aim_depth_back = 0.2;
uniform vec3 aim_ring_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 aim_heat_color : source_color = vec3(1.0, 0.55, 0.2);

// Distance of a surface point from the beam axis, or -1.0 when the beam does
// not land on it (outside the lit depth range, or facing away from the laser).
// `outward_normal` is the surface's own normal, never flipped for back faces.
float aim_distance(vec3 surface_pos, vec3 outward_normal) {
	if (aim_visible <= 0.0) {
		return -1.0;
	}
	vec3 rel = surface_pos - aim_point;
	float depth = dot(rel, aim_dir);
	if (depth < -aim_depth_front || depth > aim_depth_back || dot(outward_normal, -aim_dir) <= 0.02) {
		return -1.0;
	}
	return length(rel - aim_dir * depth);
}

// x = ring line, y = dark rim around the line, z = hot area inside the ring.
// `pixel` is fwidth(dist), so the line keeps a constant on-screen thickness.
vec3 aim_ring(float dist, float pixel) {
	if (dist < 0.0 || dist >= aim_radius * 1.2) {
		return vec3(0.0);
	}
	float px = max(pixel, 1e-5);
	float line_w = max(px * 1.25, aim_radius * 0.02);
	float d_line = abs(dist - (aim_radius - line_w));
	float ring = 1.0 - smoothstep(line_w - px, line_w, d_line);
	float rim = 1.0 - smoothstep(line_w * 2.0 - px, line_w * 2.0 + px, d_line);
	float inside = 1.0 - smoothstep(aim_radius * 0.55, aim_radius, dist);
	return vec3(ring * aim_visible, max(rim - ring, 0.0) * aim_visible, inside * aim_firing);
}
