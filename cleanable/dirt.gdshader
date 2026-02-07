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
uniform sampler2D zone_mask : hint_default_black, filter_linear;

// Dirt vision
uniform bool dirt_vision_enabled = false;
uniform vec3 rust_glow_color : source_color = vec3(1.0, 0.3, 0.1);
uniform vec3 metal_glow_color : source_color = vec3(0.3, 0.5, 1.0);
uniform float dirt_glow_intensity : hint_range(0.0, 10.0) = 5.0;
uniform float pulse_speed : hint_range(0.5, 5.0) = 2.0;
uniform float pulse_min : hint_range(0.0, 1.0) = 0.4;
uniform float outside_zone_alpha : hint_range(0.0, 0.2) = 0.05;

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

	// Per-zone flash from flash_mask texture
	float flash = texture(flash_mask, UV).r;
	vec3 emission = vec3(1.0) * flash * 3.0;

	// Dirt vision mode
	if (dirt_vision_enabled) {
		float in_zone = texture(zone_mask, UV).r;
		float dirt_amount = max(rust_amount, grey_amount);

		if (in_zone > 0.5 && dirt_amount > 0.01) {
			float pulse = pulse_min + (1.0 - pulse_min) * (0.5 + 0.5 * sin(TIME * pulse_speed));
			vec3 glow_color = mix(metal_glow_color, rust_glow_color, step(0.01, rust_amount));
			float boosted_dirt = pow(dirt_amount, 0.5);

			emission += glow_color * boosted_dirt * dirt_glow_intensity * pulse;
			albedo = glow_color * 0.5;
			ALPHA = 1.0;
		} else {
			albedo = vec3(0.0);
			emission = vec3(0.0);
			ALPHA = outside_zone_alpha;
		}
	} else {
		ALPHA = 1.0;
	}

	ALBEDO = albedo;
	NORMAL_MAP = normal_map;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	EMISSION = emission;
}