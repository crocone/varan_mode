shader_type spatial;
render_mode diffuse_lambert_wrap, specular_schlick_ggx;

// Vertex colours carry the biome hue; tiling detail textures add pebbles,
// grit, cracks (ground) and sandstone strata (steep rock) up close.
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D ground_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_nrm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_nrm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float wet_line = 0.25;
uniform float ground_scale = 0.42;
uniform float rock_scale = 0.12;
uniform float detail_far = 70.0;

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec3 unpack(vec3 n) {
	return n * 2.0 - 1.0;
}

void fragment() {
	vec3 base = pow(max(COLOR.rgb, vec3(0.0)), vec3(2.2));
	float n1 = texture(noise_tex, wpos.xz * 0.013).r;
	float n2 = texture(noise_tex, wpos.xz * 0.11).r;
	vec3 col = base * (0.8 + 0.4 * n1) * (0.92 + 0.16 * n2);
	float dist = length(wpos - CAMERA_POSITION_WORLD);
	float near = 1.0 - smoothstep(detail_far * 0.5, detail_far, dist);
	// ground detail (top projection, two scales to break tiling)
	vec2 guv = wpos.xz * ground_scale;
	vec3 gd = texture(ground_tex, guv).rgb;
	vec3 gd2 = texture(ground_tex, guv * 0.23 + vec2(0.37, 0.11)).rgb;
	vec3 gdet = mix(vec3(0.5), gd * 0.65 + gd2 * 0.35, near);
	vec3 gn = unpack(texture(ground_nrm, guv).rgb);
	// rock detail (triplanar) on steep slopes / cliffs
	vec3 bw = pow(abs(wnrm), vec3(4.0));
	bw /= (bw.x + bw.y + bw.z);
	vec3 rx = texture(rock_tex, wpos.zy * rock_scale).rgb;
	vec3 ry = texture(rock_tex, wpos.xz * rock_scale).rgb;
	vec3 rz = texture(rock_tex, wpos.xy * rock_scale).rgb;
	vec3 rdet = rx * bw.x + ry * bw.y + rz * bw.z;
	vec3 rnx = unpack(texture(rock_nrm, wpos.zy * rock_scale).rgb);
	vec3 rnz = unpack(texture(rock_nrm, wpos.xy * rock_scale).rgb);
	float steep = smoothstep(0.62, 0.42, wnrm.y);
	vec3 det = mix(gdet * 2.0, rdet * 2.1, steep);
	col *= det;
	// perturb the world normal (no tangents needed)
	vec3 pn = wnrm;
	pn += (vec3(gn.x, 0.0, -gn.y) * 0.9) * near * (1.0 - steep);
	pn += (vec3(0.0, rnx.y, rnx.x) * bw.x + vec3(rnz.x, rnz.y, 0.0) * bw.z) * 0.8 * steep;
	pn = normalize(pn);
	NORMAL = normalize((VIEW_MATRIX * vec4(pn, 0.0)).xyz);
	// damp dark band at the waterline
	float wet = 1.0 - smoothstep(0.0, wet_line, wpos.y);
	col *= 1.0 - 0.35 * wet * step(-0.6, wpos.y);
	ALBEDO = col;
	ROUGHNESS = 0.93 - wet * 0.45;
	SPECULAR = 0.3;
}
