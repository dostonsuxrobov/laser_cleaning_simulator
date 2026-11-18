shader_type canvas_item;
render_mode blend_disabled, unshaded;

// Writes the dirt mask directly (no blending), at full mask resolution.
//   wipe_zone == 0 : (re)fill - every zone texel that has real surface behind
//                    it becomes fully dirty, everything else becomes clean.
//   wipe_zone  > 0 : clean every texel of that one zone, leave the rest alone.

#include "res://cleanable/zone_lookup.gdshaderinc"

uniform sampler2D position_map : filter_nearest, repeat_disable, hint_default_white;
uniform bool use_coverage = false;
uniform int wipe_zone = 0;

void fragment() {
	int id = zone_id_at(UV);

	if (wipe_zone > 0) {
		if (id != wipe_zone) {
			discard;
		}
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		float dirt = (id > 0) ? 1.0 : 0.0;
		if (use_coverage && texture(position_map, UV).a < 0.5) {
			dirt = 0.0;
		}
		COLOR = vec4(dirt, dirt, 0.0, 1.0);
	}
}
