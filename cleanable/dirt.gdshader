shader_type spatial;
render_mode cull_disabled;

// Normal look of a cleanable surface: rust on top, a base layer under it,
// the clean finish at the bottom, blended by the dirt mask.
// (Dirt vision uses dirt_xray.gdshader instead.)

#include "res://cleanable/zone_lookup.gdshaderinc"
#include "res://cleanable/aim_ring.gdshaderinc"

uniform sampler2D rust_albedo : source_color, filter_linear;
uniform sampler2D rust_normal : hint_normal, filter_linear;
uniform float rust_roughness : hint_range(0.0, 1.0) = 0.9;

// Layer between the rust and the clean finish (what the laser exposes first).
uniform sampler2D metal_albedo : source_color, filter_linear;
uniform sampler2D metal_normal : hint_normal, filter_linear;
uniform float metal_roughness : hint_range(0.0, 1.0) = 0.5;
uniform vec3 metal_tint : source_color = vec3(1.0);
// How strongly the old rust leaves dark scorch stains on that layer.
uniform float metal_stain : hint_range(0.0, 1.0) = 0.0;

uniform sampler2D chrome_albedo : source_color, filter_linear;
uniform sampler2D chrome_normal : hint_normal, filter_linear;
uniform float chrome_roughness : hint_range(0.0, 1.0) = 0.1;
uniform float chrome_metallic : hint_range(0.0, 1.0) = 1.0;
// Optional occlusion (R) / roughness (G) / metallic (B) map for the clean
// finish. When enabled it replaces the two sliders above.
uniform bool chrome_use_orm = false;
uniform sampler2D chrome_orm : hint_default_white, filter_linear;

uniform sampler2D dirt_mask : hint_default_white, filter_linear, repeat_disable;

// Per-zone completion flash (index = zone id - 1), driven by cleanable_mesh.gd
uniform float zone_flash[16];

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
	vec3 metal_col = texture(metal_albedo, UV).rgb * metal_tint;
	vec3 chrome_col = texture(chrome_albedo, UV).rgb;

	// Scorch stains: darker wherever the rust layer above was dark
	float rust_luma = clamp(dot(rust_col, vec3(0.299, 0.587, 0.114)) * 1.25, 0.0, 1.0);
	metal_col *= mix(1.0, rust_luma, metal_stain);

	vec3 rust_nrm = texture(rust_normal, UV).rgb;
	vec3 metal_nrm = texture(metal_normal, UV).rgb;
	vec3 chrome_nrm = texture(chrome_normal, UV).rgb;

	// Layer compositing
	vec3 albedo = chrome_col;
	vec3 normal_map = chrome_nrm;
	float roughness = chrome_roughness;
	float metallic = chrome_metallic;
	float occlusion = 1.0;
	if (chrome_use_orm) {
		vec3 orm = texture(chrome_orm, UV).rgb;
		occlusion = orm.r;
		roughness = orm.g;
		metallic = orm.b;
	}

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

	// Aiming ring + heat glow
	float aim_dist = aim_distance(world_pos, world_nrm);
	vec3 aim = aim_ring(aim_dist, fwidth(aim_dist));
	albedo = mix(albedo, vec3(0.0), aim.y * 0.6);
	albedo = mix(albedo, aim_ring_color, aim.x);
	emission += aim_ring_color * aim.x * 0.9;
	emission += aim_heat_color * aim.z * 0.9;

	// Flip normal for back faces so lighting is correct from behind
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;

	ALBEDO = albedo;
	NORMAL_MAP = normal_map;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	AO = occlusion;
	EMISSION = emission;
}
