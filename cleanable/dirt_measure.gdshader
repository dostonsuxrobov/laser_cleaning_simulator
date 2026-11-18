shader_type canvas_item;
render_mode blend_disabled, unshaded;

// Shrinks the full-resolution dirt mask to the small progress grid with an
// exact box filter, so progress can be read back cheaply (a few hundred KB
// instead of the whole float mask) without losing any dirt in between texels.

uniform sampler2D dirt_mask : filter_nearest, repeat_disable;
uniform int ratio = 4; // mask texels per progress cell, per axis

void fragment() {
	vec2 src_size = vec2(textureSize(dirt_mask, 0));
	ivec2 base = ivec2(floor(UV * src_size / float(ratio))) * ratio;
	vec2 sum = vec2(0.0);
	for (int y = 0; y < ratio; y++) {
		for (int x = 0; x < ratio; x++) {
			sum += clamp(texelFetch(dirt_mask, base + ivec2(x, y), 0).rg, vec2(0.0), vec2(1.0));
		}
	}
	sum /= float(ratio * ratio);
	COLOR = vec4(sum, 0.0, 1.0);
}
