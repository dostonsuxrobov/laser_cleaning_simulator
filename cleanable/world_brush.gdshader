shader_type canvas_item;
render_mode blend_sub, unshaded;

// Laser brush. Runs as a full-texture pass over the dirt mask: every texel
// looks up its own 3D surface position (baked at load) and is cleaned only if
// that point sits inside the laser beam - a cylinder of brush_radius around
// the beam axis. That is exactly the footprint the aiming ring draws, so what
// is inside the ring is what gets cleaned: on flat, curved and steeply angled
// surfaces alike, independent of UV layout and texel density.

uniform sampler2D position_map : filter_nearest, repeat_disable;
uniform sampler2D normal_map : filter_nearest, repeat_disable;

// All in the cleanable's body-local space.
uniform vec3 beam_from = vec3(0.0);  // beam axis point at the previous hit (stroke start)
uniform vec3 beam_to = vec3(0.0);    // beam axis point at the current hit
uniform vec3 beam_dir = vec3(0.0, 0.0, -1.0); // normalized travel direction of the light
uniform float brush_radius = 0.075;
// How far the lit surface extends toward / away from the laser, measured
// along the beam from the hit point. Keeps the beam from cleaning hidden
// layers behind the surface it actually lands on.
uniform float depth_front = 0.2;
uniform float depth_back = 0.2;
uniform float strength = 0.02;

uniform float rust_resistance = 1.0;
uniform float metal_resistance = 1.5;
uniform float edge_softness : hint_range(0.05, 1.0) = 0.3;

void fragment() {
	vec4 pm = texture(position_map, UV);
	if (pm.a < 0.5) {
		discard; // texel has no surface behind it
	}

	// Split the texel's offset from the hit into "along the beam" (depth) and
	// "across the beam" (what the player sees as distance from the ring centre).
	vec3 rel = pm.xyz - beam_to;
	float depth = dot(rel, beam_dir);
	vec3 across = rel - beam_dir * depth;

	// The stroke since last frame, flattened into the same across-beam plane.
	vec3 seg = beam_from - beam_to;
	float seg_depth = dot(seg, beam_dir);
	vec3 seg_across = seg - beam_dir * seg_depth;
	float len2 = dot(seg_across, seg_across);
	float t = (len2 > 1e-10) ? clamp(dot(across, seg_across) / len2, 0.0, 1.0) : 0.0;
	float dist = length(across - seg_across * t);
	if (dist > brush_radius) {
		discard;
	}

	// Depth window, stretched to cover both ends of the stroke.
	if (depth < min(0.0, seg_depth) - depth_front || depth > max(0.0, seg_depth) + depth_back) {
		discard;
	}

	// Only surfaces the beam can land on - never the far side of a part.
	vec3 n = normalize(texture(normal_map, UV).xyz);
	float facing = smoothstep(0.02, 0.3, dot(n, -beam_dir));

	float falloff = 1.0 - smoothstep(1.0 - edge_softness, 1.0, dist / brush_radius);
	float power = strength * falloff * facing;

	COLOR = vec4(power / rust_resistance, power / metal_resistance, 0.0, 1.0);
}
