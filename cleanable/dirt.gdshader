shader_type spatial;

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

void fragment() {
    vec2 mask = texture(dirt_mask, UV).rg;
    float rust_amount = mask.r;
    float grey_amount = mask.g;
    
    // Sample all layers
    vec3 rust_col = texture(rust_albedo, UV).rgb;
    vec3 metal_col = texture(metal_albedo, UV).rgb;
    vec3 chrome_col = texture(chrome_albedo, UV).rgb;
    
    vec3 rust_nrm = texture(rust_normal, UV).rgb;
    vec3 metal_nrm = texture(metal_normal, UV).rgb;
    vec3 chrome_nrm = texture(chrome_normal, UV).rgb;
    
    // Blend: chrome → metal → rust (bottom to top)
    vec3 albedo = chrome_col;
    vec3 normal_map = chrome_nrm;
    float roughness = chrome_roughness;
    float metallic = chrome_metallic;
    
    // Blend in grey metal
    albedo = mix(albedo, metal_col, grey_amount);
    normal_map = mix(normal_map, metal_nrm, grey_amount);
    roughness = mix(roughness, metal_roughness, grey_amount);
    metallic = mix(metallic, 0.0, grey_amount);
    
    // Blend in rust on top
    albedo = mix(albedo, rust_col, rust_amount);
    normal_map = mix(normal_map, rust_nrm, rust_amount);
    roughness = mix(roughness, rust_roughness, rust_amount);
    
    ALBEDO = albedo;
    NORMAL_MAP = normal_map;
    ROUGHNESS = roughness;
    METALLIC = metallic;
}