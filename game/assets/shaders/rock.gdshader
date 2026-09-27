shader_type spatial;
render_mode diffuse_lambert_wrap;

// Triplanar sandstone detail in world space, hue from vertex colour.
uniform sampler2D rock_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_nrm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float scale = 0.35;
uniform float tex_mix = 1.0;

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 bw = pow(abs(wnrm), vec3(4.0));
	bw /= (bw.x + bw.y + bw.z);
	vec3 rx = texture(rock_tex, wpos.zy * scale).rgb;
	vec3 ry = texture(rock_tex, wpos.xz * scale).rgb;
	vec3 rz = texture(rock_tex, wpos.xy * scale).rgb;
	vec3 det = rx * bw.x + ry * bw.y + rz * bw.z;
	vec3 nx = texture(rock_nrm, wpos.zy * scale).rgb * 2.0 - 1.0;
	vec3 ny = texture(rock_nrm, wpos.xz * scale).rgb * 2.0 - 1.0;
	vec3 nz = texture(rock_nrm, wpos.xy * scale).rgb * 2.0 - 1.0;
	vec3 pn = wnrm + (vec3(0.0, nx.y, nx.x) * bw.x + vec3(ny.x, 0.0, -ny.y) * bw.y + vec3(nz.x, nz.y, 0.0) * bw.z) * 0.9;
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(pn), 0.0)).xyz);
	vec3 vc = pow(max(COLOR.rgb, vec3(0.0)), vec3(2.2));
	ALBEDO = vc * mix(vec3(1.0), det * 2.1, tex_mix);
	ROUGHNESS = 0.9;
}
