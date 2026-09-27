shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx, depth_prepass_alpha;

// Alpha-tested leaf / grass cards with wind sway. UV2.x = sway weight.
uniform sampler2D leaf_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float sway = 0.06;
uniform float sway_speed = 1.3;
uniform float alpha_cut = 0.45;
uniform vec3 tint = vec3(1.0);
uniform float translucency = 0.35;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = UV2.x;
	float ph = wp.x * 0.21 + wp.z * 0.17;
	float gust = 0.6 + 0.4 * sin(TIME * 0.35 + wp.x * 0.02);
	VERTEX.x += sin(TIME * sway_speed + ph) * sway * w * gust;
	VERTEX.z += cos(TIME * sway_speed * 0.8 + ph * 1.3) * sway * 0.6 * w * gust;
	VERTEX.y += sin(TIME * sway_speed * 1.7 + ph * 2.0) * sway * 0.25 * w;
}

void fragment() {
	vec4 t = texture(leaf_tex, UV);
	if (t.a < alpha_cut) {
		discard;
	}
	vec3 vc = pow(max(COLOR.rgb, vec3(0.0)), vec3(2.2));
	ALBEDO = t.rgb * vc * tint;
	ROUGHNESS = 0.8;
	SPECULAR = 0.25;
	BACKLIGHT = ALBEDO * translucency;
}
