shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, specular_disabled;

// Vertex-colored foliage with wind sway. UV.x = sway weight (0 at root).
uniform float sway = 0.12;
uniform float sway_speed = 1.4;
uniform float fade_start = 1000.0;
uniform float fade_end = 1100.0;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = UV.x;
	float ph = wp.x * 0.21 + wp.z * 0.17;
	float gust = 0.6 + 0.4 * sin(TIME * 0.35 + wp.x * 0.02);
	VERTEX.x += sin(TIME * sway_speed + ph) * sway * w * gust;
	VERTEX.z += cos(TIME * sway_speed * 0.8 + ph * 1.3) * sway * 0.6 * w * gust;
}

void fragment() {
	ALBEDO = pow(max(COLOR.rgb, vec3(0.0)), vec3(2.2));
	ROUGHNESS = 0.9;
	BACKLIGHT = vec3(0.25, 0.25, 0.1);
}
