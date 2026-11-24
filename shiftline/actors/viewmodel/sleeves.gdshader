shader_type spatial;
render_mode specular_disabled, cull_disabled;

uniform vec4 skin_tint : source_color = vec4(0.749, 0.565, 0.435, 1.0);
uniform vec4 fabric_tint : source_color;

void fragment() {
    ALBEDO = mix(skin_tint.rgb, fabric_tint.rgb, smoothstep(0.45, 0.55, COLOR.r));
    ROUGHNESS = 0.96;
}
