shader_type spatial;
render_mode diffuse_lambert_wrap;

// Cylindrically mapped bark in object space (trunks along +Y, logs along +Z).
uniform sampler2D bark_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bark_nrm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float axis_z = 0.0;     // 1 for logs lying along Z
uniform vec2 scale = vec2(1.0, 3.0);
uniform float sway = 0.03;

varying vec3 opos;
varying vec3 onrm;

void vertex() {
	opos = VERTEX;
	onrm = NORMAL;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = UV2.x;
	float ph = wp.x * 0.21 + wp.z * 0.17;
	VERTEX.x += sin(TIME * 1.3 + ph) * sway * w;
}

void fragment() {
	vec3 p = opos;
	vec2 uv;
	if (axis_z > 0.5) {
		uv = vec2(atan(p.x, p.y) / 6.2832 * scale.x, p.z * scale.y);
	} else {
		uv = vec2(atan(p.x, p.z) / 6.2832 * scale.x, p.y * scale.y);
	}
	vec3 c = texture(bark_tex, uv).rgb;
	vec3 vc = pow(max(COLOR.rgb, vec3(0.0)), vec3(2.2));
	ALBEDO = c * vc * 1.6;
	vec3 n = texture(bark_nrm, uv).rgb * 2.0 - 1.0;
	NORMAL = normalize(NORMAL + (VIEW_MATRIX * MODEL_MATRIX * vec4(onrm.x * n.y, n.x * 0.8, onrm.z * n.y, 0.0)).xyz * 0.6);
	ROUGHNESS = 0.85;
}
