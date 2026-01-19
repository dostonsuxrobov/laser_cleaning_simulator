shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear;
uniform float distortion_strength : hint_range(0.0, 0.15) = 0.03;
uniform float wave_speed : hint_range(0.0, 80.0) = 25.0;
uniform float wave_frequency : hint_range(0.0, 100.0) = 40.0;
uniform float visibility : hint_range(0.0, 1.0) = 0.7;

varying vec3 world_pos;
varying float along_beam;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	along_beam = VERTEX.z + 0.5;
}

void fragment() {
	// Stronger near impact
	float intensity = along_beam * along_beam;
	
	// Animated waves
	float wave = sin(world_pos.z * wave_frequency + TIME * wave_speed);
	wave += sin(world_pos.z * wave_frequency * 0.7 + TIME * wave_speed * 1.3) * 0.5;
	wave *= distortion_strength * intensity;
	
	// Edge fade
	float edge_fade = 1.0 - abs(UV.x - 0.5) * 2.0;
	edge_fade = edge_fade * edge_fade;
	wave *= edge_fade;
	
	// Distorted screen sample
	vec2 distorted_uv = SCREEN_UV + vec2(wave, wave * 0.5);
	vec3 screen_col = texture(screen_texture, distorted_uv).rgb;
	
	// Optional: add subtle orange tint to make it more visible
	vec3 heat_tint = vec3(1.0, 0.95, 0.9);
	screen_col = mix(screen_col, screen_col * heat_tint, intensity * visibility * 0.3);
	
	ALBEDO = screen_col;
	ALPHA = edge_fade * intensity * visibility;
}