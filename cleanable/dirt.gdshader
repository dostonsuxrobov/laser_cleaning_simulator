shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform sampler2D rust_albedo : source_color, filter_linear;
uniform sampler2D rust_normal : hint_normal, filter_linear;
uniform float rust_roughness : hint_range(0.0, 1.0) = 0.9;

uniform sampler2D metal_albedo : source_color, filter_linear;
uniform sampler2D metal_normal : hint_normal, filter_linear;
uniform float metal_roughness : hint_range(0.0, 1.0) = 0.5;

uniform sampler2D chrome_albedo : source_color, filter_linear;
uniform sampler2D chrome_normal : hint_normal, filter_linear;
uniform float chrome_roughness : hint_range(0.0, 1.0) = 0.1;
uniform float chrome_metallic : hint_range(0.0, 1.0) = 1.0;

uniform sampler2D dirt_mask : hint_default_white, filter_linear;
uniform sampler2D flash_mask : hint_default_black, filter_linear;

// Dirt vision
uniform bool dirt_vision_enabled = false;
uniform vec3 dirt_glow_color : source_color = vec3(1.0, 0.3, 0.1);
uniform float dirt_glow_intensity : hint_range(0.0, 10.0) = 5.0;
uniform float clean_transparency : hint_range(0.0, 1.0) = 0.15;
uniform float dirty_transparency : hint_range(0.0, 1.0) = 1.0;
uniform float pulse_speed : hint_range(0.5, 5.0) = 2.0;
uniform float pulse_min : hint_range(0.0, 1.0) = 0.4;

void fragment() {
	vec2 mask = texture(dirt_mask, UV).rg;
	float rust_amount = mask.r;
	float grey_amount = mask.g;
	
	vec3 rust_col = texture(rust_albedo, UV).rgb;
	vec3 metal_col = texture(metal_albedo, UV).rgb;
	vec3 chrome_col = texture(chrome_albedo, UV).rgb;
	
	vec3 rust_nrm = texture(rust_normal, UV).rgb;
	vec3 metal_nrm = texture(metal_normal, UV).rgb;
	vec3 chrome_nrm = texture(chrome_normal, UV).rgb;
	
	vec3 albedo = chrome_col;
	vec3 normal_map = chrome_nrm;
	float roughness = chrome_roughness;
	float metallic = chrome_metallic;
	
	albedo = mix(albedo, metal_col, grey_amount);
	normal_map = mix(normal_map, metal_nrm, grey_amount);
	roughness = mix(roughness, metal_roughness, grey_amount);
	metallic = mix(metallic, 0.0, grey_amount);
	
	albedo = mix(albedo, rust_col, rust_amount);
	normal_map = mix(normal_map, rust_nrm, rust_amount);
	roughness = mix(roughness, rust_roughness, rust_amount);
	
	// Flash effect from zone completion
	float flash = texture(flash_mask, UV).r;
	vec3 emission = vec3(1.0, 1.0, 1.0) * flash * 3.0;
	
	// Dirt vision mode
	if (dirt_vision_enabled) {
		float dirt_amount = max(rust_amount, grey_amount);
		
		// Pulsing effect
		float pulse = pulse_min + (1.0 - pulse_min) * (0.5 + 0.5 * sin(TIME * pulse_speed));
		
		// Dirty areas: bright glow
		emission += dirt_glow_color * dirt_amount * dirt_glow_intensity * pulse;
		
		// Darken clean areas so dirt stands out
		albedo = mix(vec3(0.02), albedo * 0.3, dirt_amount);
		
		// Clean = very transparent, Dirty = opaque
		ALPHA = mix(clean_transparency, dirty_transparency, dirt_amount);
	} else {
		ALPHA = 1.0;
	}
	
	ALBEDO = albedo;
	NORMAL_MAP = normal_map;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	EMISSION = emission;
}