shader_type spatial;

// Use mesh UV coordinates - matches cleanable_mesh.gd UV lookup

uniform vec3 clean_color : source_color = vec3(0.9, 0.9, 0.95);
uniform vec3 dirt_color : source_color = vec3(0.35, 0.28, 0.2);
uniform sampler2D dirt_mask : hint_default_white, filter_linear;

void fragment() {
	float dirt = texture(dirt_mask, UV).r;
	
	ALBEDO = mix(clean_color, dirt_color, dirt);
	ROUGHNESS = mix(0.3, 0.9, dirt);
}
