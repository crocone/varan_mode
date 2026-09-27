shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 shallow_col : source_color = vec3(0.36, 0.42, 0.30);
uniform vec3 deep_col : source_color = vec3(0.10, 0.16, 0.13);
uniform vec3 foam_col : source_color = vec3(0.85, 0.82, 0.72);
uniform float flow_speed = 0.02;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME;
	VERTEX.y += sin(wpos.x * 0.35 + t * 1.1) * 0.025 + cos(wpos.z * 0.29 + t * 0.9) * 0.025;
}

void fragment() {
	float t = TIME;
	vec2 uv1 = wpos.xz * 0.05 + vec2(t * flow_speed, t * flow_speed * 0.6);
	vec2 uv2 = wpos.xz * 0.12 - vec2(t * flow_speed * 0.7, -t * flow_speed);
	float n1 = texture(noise_tex, uv1).r;
	float n2 = texture(noise_tex, uv2).r;
	float nx = texture(noise_tex, uv1 + vec2(0.013, 0.0)).r - n1;
	float nz = texture(noise_tex, uv1 + vec2(0.0, 0.013)).r - n1;
	vec3 nrm = normalize(vec3(-nx * 3.0 - (n2 - 0.5) * 0.2, 1.0, -nz * 3.0));
	NORMAL = normalize((VIEW_MATRIX * vec4(nrm, 0.0)).xyz);

	float depth_raw = texture(depth_tex, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	vec4 view = INV_PROJECTION_MATRIX * ndc;
	view.xyz /= view.w;
	float scene_depth = -view.z;
	float water_depth = scene_depth - (-VERTEX.z);
	float d = clamp(water_depth / 2.2, 0.0, 1.0);

	vec2 refr_uv = SCREEN_UV + nrm.xz * 0.012 * d;
	vec3 under = texture(screen_tex, refr_uv).rgb;
	vec3 wcol = mix(shallow_col, deep_col, d);
	vec3 col = mix(under * 0.85, wcol, clamp(d * 1.4 + 0.25, 0.0, 0.95));
	float foam = (1.0 - smoothstep(0.0, 0.18 + n2 * 0.12, water_depth)) * 0.8;
	col = mix(col, foam_col, foam * 0.6);
	ALBEDO = col;
	ROUGHNESS = 0.14;
	METALLIC = 0.0;
	SPECULAR = 0.35;
	ALPHA = clamp(0.55 + d * 0.5 + foam * 0.3, 0.0, 1.0);
}
