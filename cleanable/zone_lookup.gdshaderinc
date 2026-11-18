// Shared zone classification. A texel belongs to the zone whose reference
// color is nearest to the zone map color; near-black texels belong to none.
// The CPU bookkeeping in cleanable_mesh.gd uses exactly the same rule.

const int MAX_ZONES = 16;

uniform sampler2D zone_map : filter_nearest, repeat_disable, hint_default_black;
uniform vec3 zone_colors[16];
uniform int zone_count = 0;

// Returns 0 for "no zone", otherwise the 1-based zone index.
int zone_id_at(vec2 uv) {
	vec3 c = texture(zone_map, uv).rgb;
	if (zone_count <= 0 || max(c.r, max(c.g, c.b)) < 0.05) {
		return 0;
	}
	int best = 0;
	float best_dist = 1.0e9;
	for (int i = 0; i < zone_count && i < MAX_ZONES; i++) {
		vec3 d = c - zone_colors[i];
		float dist = dot(d, d);
		if (dist < best_dist) {
			best_dist = dist;
			best = i + 1;
		}
	}
	return best;
}
