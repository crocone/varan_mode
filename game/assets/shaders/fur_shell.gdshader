shader_type spatial;
render_mode cull_back, diffuse_lambert_wrap, specular_schlick_ggx;

// One shell of a shell-textured fur coat. The base mesh is rendered normally;
// each next_pass shell is pushed out along the (skinned) normal and keeps only
// the texels where a strand is long enough to reach this layer.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D strand_tex : filter_linear, repeat_enable;
uniform float layer = 0.5;
uniform float fur_len = 0.02;
uniform float density = 110.0;
uniform float droop = 0.35;

varying float flen;

void vertex() {
	flen = textureLod(rough_tex, UV, 0.0).r * 1.4;
	float h = fur_len * layer * flen;
	VERTEX += NORMAL * h;
	VERTEX.y -= droop * h * layer;
}

void fragment() {
	vec4 rt = texture(rough_tex, UV);
	float furmask = smoothstep(0.84, 0.9, rt.g) * step(0.05, rt.r);
	vec2 suv = UV * density;
	float s = texture(strand_tex, suv).r;
	float thick = s - layer * (0.75 + 0.25 * texture(strand_tex, suv * 0.13).r);
	if (furmask < 0.5 || thick < 0.02) {
		discard;
	}
	vec3 c = texture(albedo_tex, UV).rgb;
	ALBEDO = c * mix(0.62, 1.08, layer);
	ROUGHNESS = 0.95;
	SPECULAR = 0.25;
}
