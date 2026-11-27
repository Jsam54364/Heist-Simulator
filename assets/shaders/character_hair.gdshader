shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;
// Hair cards, eyebrows and eyelashes (MakeHuman CC0 alpha textures in one atlas).
// Alpha-tested (cheap on mobile, sorts correctly, casts shadows) with alpha-to-coverage
// softening when MSAA is on. Re-coloured by hair_color like the clothes: luminance x
// colour normalised by the texture's mean luminance (COLOR.g).

uniform sampler2D hair_atlas : source_color, filter_linear_mipmap, repeat_disable;
instance uniform float hit : instance_index(7) = 0.0;
instance uniform vec4 hair_color : source_color, instance_index(8) = vec4(0.0);

varying flat float lumref;
varying flat float fine;

void vertex() {
	lumref = COLOR.g;
	fine = COLOR.b;     // 1 = eyebrows / lashes: thin strokes need a lower alpha cut-off
}

void fragment() {
	vec4 t = texture(hair_atlas, UV);
	vec3 c = t.rgb;
	if (hair_color.a > 0.001) {
		float l = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(c, hair_color.rgb * clamp(l / max(lumref, 0.04), 0.0, 2.2), hair_color.a);
	}
	ALBEDO = mix(c, vec3(1.0, 0.25, 0.2), hit);
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = mix(0.42, 0.16, fine);
	ALPHA_ANTIALIASING_EDGE = 0.25;
	ROUGHNESS = 0.72;
	SPECULAR = 0.24;
}
