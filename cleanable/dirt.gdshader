shader_type spatial;

// Clean material (shiny metal underneath)
uniform sampler2D clean_albedo : source_color, filter_linear;
uniform sampler2D clean_normal : hint_normal, filter_linear;
uniform float clean_roughness : hint_range(0.0, 1.0) = 0.15;

// Dirty material (rust/grime on top)
uniform sampler2D dirty_albedo : source_color, filter_linear;
uniform sampler2D dirty_normal : hint_normal, filter_linear;
uniform float dirty_roughness : hint_range(0.0, 1.0) = 0.85;

// Mask that controls blend (painted by laser)
uniform sampler2D dirt_mask : hint_default_white, filter_linear;

void fragment() {
    float mask = texture(dirt_mask, UV).r;

    vec3 clean_col = texture(clean_albedo, UV).rgb;
    vec3 dirty_col = texture(dirty_albedo, UV).rgb;

    vec3 clean_nrm = texture(clean_normal, UV).rgb;
    vec3 dirty_nrm = texture(dirty_normal, UV).rgb;

    ALBEDO = mix(clean_col, dirty_col, mask);
    NORMAL_MAP = mix(clean_nrm, dirty_nrm, mask);
    ROUGHNESS = mix(clean_roughness, dirty_roughness, mask);
}