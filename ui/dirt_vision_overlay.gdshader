shader_type canvas_item;

uniform bool enabled = false;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear;

uniform vec3 tint_color : source_color = vec3(0.0, 1.0, 0.3);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.4;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.5;
uniform float vignette_radius : hint_range(0.0, 1.0) = 0.7;
uniform float noise_amount : hint_range(0.0, 0.1) = 0.03;
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.1;

float random(vec2 uv) {
	return fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec3 result = texture(screen_texture, SCREEN_UV).rgb;

	if (enabled) {
		// Convert to grayscale luminance
		float luminance = dot(result, vec3(0.299, 0.587, 0.114));

		// Apply green tint
		vec3 tinted = mix(result, tint_color * luminance * 1.5, tint_strength);

		// Boost contrast
		tinted = pow(max(tinted, vec3(0.0)), vec3(1.2));

		// Vignette
		vec2 center = SCREEN_UV - vec2(0.5);
		float dist = length(center);
		float vignette = smoothstep(vignette_radius, vignette_radius - 0.3, dist);
		tinted *= mix(1.0 - vignette_strength, 1.0, vignette);

		// Noise grain
		float noise = random(SCREEN_UV + TIME * 0.1) * noise_amount;
		tinted += vec3(noise);

		// Scanlines
		float scanline = sin(SCREEN_UV.y * 800.0) * 0.5 + 0.5;
		tinted *= mix(1.0, scanline, scanline_strength);

		result = tinted;
	}

	COLOR = vec4(result, 1.0);
}
