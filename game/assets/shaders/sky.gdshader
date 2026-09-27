shader_type sky;

uniform vec3 top_col : source_color = vec3(0.25, 0.45, 0.75);
uniform vec3 horizon_col : source_color = vec3(0.85, 0.78, 0.65);
uniform vec3 ground_col : source_color = vec3(0.35, 0.25, 0.18);
uniform vec3 sun_col : source_color = vec3(1.0, 0.9, 0.7);
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform float star_amount = 0.0;
uniform float haze = 0.5;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void sky() {
	vec3 d = EYEDIR;
	float h = d.y;
	vec3 col = mix(horizon_col, top_col, pow(clamp(h, 0.0, 1.0), 0.55));
	col = mix(col, ground_col, smoothstep(0.0, -0.15, h));
	float sd = max(dot(d, normalize(sun_dir)), 0.0);
	col += sun_col * pow(sd, 6.0) * 0.35 * haze;
	col += sun_col * pow(sd, 60.0) * 0.6;
	col += sun_col * smoothstep(0.9993, 0.9996, sd) * 8.0;
	if (star_amount > 0.001 && h > 0.0) {
		vec3 g = floor(d * 220.0);
		float s = hash(g);
		float star = step(0.9965, s) * (0.5 + 0.5 * sin(TIME * 2.0 + s * 100.0));
		col += vec3(star) * star_amount * smoothstep(0.0, 0.3, h);
		// faint milky way band
		float band = exp(-pow(dot(d, normalize(vec3(0.3, 0.5, 0.8))) * 4.0, 2.0));
		col += vec3(0.05, 0.05, 0.07) * band * star_amount;
	}
	COLOR = col;
}
