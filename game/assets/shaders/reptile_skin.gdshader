shader_type spatial;
render_mode diffuse_lambert_wrap;

// Vertex-colored reptile skin with procedural scales driven by UV
// (u = along the body, v = around it).
uniform vec2 scale_count = vec2(110.0, 26.0);
uniform float gloss = 0.35;
uniform int debug_mode = 0;

vec2 hash2(vec2 p) {
	p = mod(p, 289.0);
	return fract(vec2(sin(dot(p, vec2(12.9898, 78.233))), sin(dot(p, vec2(39.3468, 11.135)))) * 43758.5453);
}

void fragment() {
	vec3 c = clamp(COLOR.rgb, 0.0, 1.0);
	vec3 base = c * c;
	float has_uv = step(0.0001, UV.x + UV.y);
	vec2 uv = UV * scale_count;
	uv.x += floor(uv.y) * 0.5;
	vec2 g = floor(uv);
	vec2 f = fract(uv);
	float md = 8.0;
	vec2 mcell = vec2(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 o = vec2(float(x), float(y));
			vec2 r = o + 0.5 + (hash2(g + o) - 0.5) * 0.5 - f;
			float d = dot(r, r);
			if (d < md) { md = d; mcell = g + o; }
		}
	}
	float bump = 1.0 - smoothstep(0.08, 0.42, md);
	float cellv = hash2(mcell).x;
	float shade = mix(1.0, mix(0.72, 1.06, bump) * (0.93 + 0.14 * cellv), has_uv);
	ALBEDO = clamp(base * shade, vec3(0.0), vec3(1.0));
	ROUGHNESS = clamp(0.82 - gloss * bump * has_uv, 0.3, 1.0);
}
