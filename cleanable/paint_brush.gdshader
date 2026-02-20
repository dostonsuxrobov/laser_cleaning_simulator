shader_type canvas_item;
render_mode blend_sub;

uniform float strength : hint_range(0.0, 1.0) = 0.1;
uniform float rust_resistance : hint_range(0.1, 5.0) = 1.0;
uniform float metal_resistance : hint_range(0.1, 5.0) = 1.5;

void fragment() {
	vec2 center = UV - vec2(0.5);
	float dist = length(center) * 2.0;
	if (dist > 1.0) {
		discard;
	}

	float falloff = 1.0 - smoothstep(0.6, 1.0, dist);
	float power = strength * falloff;

	float rust_clean = power / rust_resistance;
	float metal_clean = power / metal_resistance;

	COLOR = vec4(rust_clean, metal_clean, 0.0, 1.0);
}