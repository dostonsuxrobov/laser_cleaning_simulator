shader_type canvas_item;
render_mode blend_sub, unshaded;

// World-space laser brush. Runs as a full-texture pass over the dirt mask:
// each texel looks up its own 3D surface position (baked at load) and is
// cleaned only if that position lies within the laser's world-space radius
// of the beam hit point. This makes cleaning match the crosshair exactly,
// regardless of UV layout, texel density, or island boundaries.

uniform sampler2D position_map : filter_nearest, repeat_disable;
uniform sampler2D normal_map : filter_nearest, repeat_disable;

uniform vec3 brush_from = vec3(0.0); // body-local, start of this frame's sweep
uniform vec3 brush_to = vec3(0.0);   // body-local, current hit point
uniform vec3 beam_dir = vec3(0.0, 0.0, -1.0); // body-local, normalized
uniform float brush_radius = 0.075;  // body-local units (= meters at scale 1)
uniform float strength = 0.02;

uniform float rust_resistance = 1.0;
uniform float metal_resistance = 1.5;
uniform float edge_softness : hint_range(0.05, 1.0) = 0.35;
uniform float facing_softness : hint_range(0.05, 1.0) = 0.25;

void fragment() {
	vec4 pm = texture(position_map, UV);
	if (pm.a < 0.5) {
		discard; // texel has no surface behind it
	}

	// Distance from this texel's surface point to the beam sweep segment
	vec3 seg = brush_to - brush_from;
	float len2 = dot(seg, seg);
	float t = (len2 > 1e-12) ? clamp(dot(pm.xyz - brush_from, seg) / len2, 0.0, 1.0) : 0.0;
	float dist = distance(pm.xyz, brush_from + seg * t);
	if (dist > brush_radius) {
		discard;
	}

	// Only surfaces facing the beam get cleaned - never the far side of a part
	vec3 n = normalize(texture(normal_map, UV).xyz);
	float facing = smoothstep(0.0, facing_softness, dot(n, -beam_dir));

	float falloff = 1.0 - smoothstep(1.0 - edge_softness, 1.0, dist / brush_radius);
	float power = strength * falloff * facing;

	COLOR = vec4(power / rust_resistance, power / metal_resistance, 0.0, 1.0);
}
