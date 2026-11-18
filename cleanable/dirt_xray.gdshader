shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

// Dirt vision. The object turns into a faint see-through shell and every bit
// of remaining dirt shows as a softly pulsing highlight - including dirt on
// the far side of a part, seen straight through the model. Nothing else in
// the scene is touched: no screen tint, the surroundings look exactly as
// they do without it. (The object's shadow is kept by cleanable_mesh.gd.)

#include "res://cleanable/aim_ring.gdshaderinc"

uniform sampler2D dirt_mask : hint_default_black, filter_linear, repeat_disable;

// Highlight colors: rust still on top / only the base layer left.
uniform vec3 rust_color : source_color = vec3(1.0, 0.5, 0.12);
uniform vec3 base_color : source_color = vec3(0.35, 0.65, 1.0);
uniform float dirt_opacity : hint_range(0.0, 1.0) = 0.9;

// The see-through shell.
uniform vec3 ghost_color : source_color = vec3(0.75, 0.86, 1.0);
uniform float ghost_opacity : hint_range(0.0, 1.0) = 0.1;
// Extra opacity at glancing angles, so the shape still reads.
uniform float ghost_rim : hint_range(0.0, 1.0) = 0.3;

// Gentle breathing of the highlight.
uniform float pulse_speed : hint_range(0.0, 10.0) = 2.5;
uniform float pulse_amount : hint_range(0.0, 0.5) = 0.18;

varying vec3 world_pos;
varying vec3 world_nrm;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 mask = clamp(texture(dirt_mask, UV).rg, vec2(0.0), vec2(1.0));
	float dirt = max(mask.r, mask.g);

	// Remaining dirt: brighter the more there is, breathing slowly
	float pulse = 1.0 + pulse_amount * sin(TIME * pulse_speed);
	vec3 dirt_col = mix(base_color, rust_color, smoothstep(0.0, 0.25, mask.r)) * pulse;
	float dirt_alpha = smoothstep(0.02, 0.35, dirt) * dirt_opacity;

	// Clean surface: a faint shell, a little stronger towards the silhouette
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float shell_alpha = clamp(ghost_opacity + ghost_rim * pow(1.0 - facing, 2.5), 0.0, 1.0);

	vec3 color = mix(ghost_color, dirt_col, dirt_alpha);
	float alpha = max(dirt_alpha, shell_alpha * (1.0 - dirt_alpha));

	// Aiming ring + heat glow, exactly as in the normal view
	float aim_dist = aim_distance(world_pos, world_nrm);
	vec3 aim = aim_ring(aim_dist, fwidth(aim_dist));
	color = mix(color, aim_heat_color, aim.z * 0.5);
	alpha = max(alpha, aim.z * 0.35);
	color = mix(color, vec3(0.0), aim.y * 0.6);
	alpha = max(alpha, aim.y * 0.6);
	color = mix(color, aim_ring_color, aim.x);
	alpha = max(alpha, aim.x);

	ALBEDO = color;
	ALPHA = alpha;
}
