shader_type spatial;
render_mode cull_disabled;

#include "res://cleanable/zone_lookup.gdshaderinc"

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

uniform sampler2D dirt_mask : hint_default_white, filter_linear, repeat_disable;

// Per-zone completion flash (index = zone id - 1), driven by cleanable_mesh.gd
uniform float zone_flash[16];

uniform bool dirt_vision_enabled = false;
uniform vec3 rust_glow_color : source_color = vec3(1.0, 0.3, 0.1);
uniform vec3 metal_glow_color : source_color = vec3(0.3, 0.5, 1.0);
uniform float dirt_glow_intensity : hint_range(0.0, 10.0) = 5.0;
uniform float pulse_speed : hint_range(0.5, 5.0) = 2.0;
uniform float pulse_min : hint_range(0.0, 1.0) = 0.4;
uniform float outside_zone_alpha : hint_range(0.0, 0.2) = 0.05;

// Laser aim, in world space. The ring is drawn with the very same beam test
// the brush shader uses, so it outlines exactly what the laser will clean.
uniform float aim_visible = 0.0;  // 0 = no ring
uniform float aim_firing = 0.0;   // 0..1, adds the hot glow under the beam
uniform vec3 aim_point = vec3(0.0);
uniform vec3 aim_dir = vec3(0.0, 0.0, -1.0);
uniform float aim_radius = 0.075;
uniform float aim_depth_front = 0.2;
uniform float aim_depth_back = 0.2;
uniform vec3 aim_ring_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 aim_heat_color : source_color = vec3(1.0, 0.55, 0.2);

varying vec3 world_pos;
varying vec3 world_nrm;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// Clamp: the paint target is float (HDR) and subtractive blending pushes
	// heavily cleaned texels below zero.
	vec2 mask = clamp(texture(dirt_mask, UV).rg, vec2(0.0), vec2(1.0));
	float rust_amount = mask.r;
	float grey_amount = mask.g;

	vec3 rust_col = texture(rust_albedo, UV).rgb;
	vec3 metal_col = texture(metal_albedo, UV).rgb;
	vec3 chrome_col = texture(chrome_albedo, UV).rgb;

	vec3 rust_nrm = texture(rust_normal, UV).rgb;
	vec3 metal_nrm = texture(metal_normal, UV).rgb;
	vec3 chrome_nrm = texture(chrome_normal, UV).rgb;

	// Normal surface compositing
	vec3 albedo = chrome_col;
	vec3 normal_map = chrome_nrm;
	float roughness = chrome_roughness;
	float metallic = chrome_metallic;

	float metal_visible = grey_amount * (1.0 - rust_amount);

	albedo = mix(albedo, metal_col, metal_visible);
	normal_map = mix(normal_map, metal_nrm, metal_visible);
	roughness = mix(roughness, metal_roughness, metal_visible);
	metallic = mix(metallic, 0.0, metal_visible);

	albedo = mix(albedo, rust_col, rust_amount);
	normal_map = mix(normal_map, rust_nrm, rust_amount);
	roughness = mix(roughness, rust_roughness, rust_amount);

	int zone = zone_id_at(UV);
	float flash = (zone > 0) ? zone_flash[zone - 1] : 0.0;
	vec3 emission = vec3(1.0) * flash * 3.0;

	float alpha = 1.0;

	if (dirt_vision_enabled) {
		float dirt_amount = max(rust_amount, grey_amount);

		if (dirt_amount > 0.01) {
			// Remaining dirt: glow and stay fully opaque
			float pulse = pulse_min + (1.0 - pulse_min) * (0.5 + 0.5 * sin(TIME * pulse_speed));
			vec3 glow_color = mix(metal_glow_color, rust_glow_color, step(0.01, rust_amount));
			float boosted_dirt = pow(dirt_amount, 0.5);

			emission += glow_color * boosted_dirt * dirt_glow_intensity * pulse;
			albedo = glow_color * 0.5;
			alpha = 1.0;
		} else {
			// Clean areas: drop below scissor threshold = invisible
			albedo = vec3(0.0);
			emission = vec3(0.0);
			alpha = outside_zone_alpha;
		}
	}

	// Aiming ring + heat glow: same cylinder-around-the-beam test as the brush
	if (aim_visible > 0.0) {
		vec3 rel = world_pos - aim_point;
		float depth = dot(rel, aim_dir);
		float dist = length(rel - aim_dir * depth);
		vec3 wn = FRONT_FACING ? world_nrm : -world_nrm;
		bool lit = depth >= -aim_depth_front && depth <= aim_depth_back && dot(wn, -aim_dir) > 0.02;
		if (lit && dist < aim_radius * 1.2) {
			float px = max(fwidth(dist), 1e-5);
			// crisp line just inside the radius, with a dark rim so it reads on any surface
			float line_w = max(px * 1.25, aim_radius * 0.02);
			float d_line = abs(dist - (aim_radius - line_w));
			float ring = 1.0 - smoothstep(line_w - px, line_w, d_line);
			float rim = 1.0 - smoothstep(line_w * 2.0 - px, line_w * 2.0 + px, d_line);
			float inside = 1.0 - smoothstep(aim_radius * 0.55, aim_radius, dist);

			albedo = mix(albedo, vec3(0.0), max(rim - ring, 0.0) * 0.6 * aim_visible);
			albedo = mix(albedo, aim_ring_color, ring * aim_visible);
			emission += aim_ring_color * ring * aim_visible * 0.9;
			emission += aim_heat_color * inside * aim_firing * 0.9;
			alpha = max(alpha, ring * aim_visible);
		}
	}

	// Flip normal for back faces so lighting is correct from behind
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;

	ALBEDO = albedo;
	NORMAL_MAP = normal_map;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	EMISSION = emission;
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
