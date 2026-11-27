shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;
// Opaque surface of every person: body skin (photo skins from MakeHuman, CC0), clothes,
// shoes, eyes and gear, all from one shared atlas. Per-vertex COLOR (written when the
// outfit is assembled): r = slot id / 255, g = mean luminance of that garment's texture.
// Garments are re-coloured per character: luminance x tint colour, normalised by that
// mean luminance so a tint means the same colour on any source texture (and keeps the
// fabric shading, fading and folds). Tint alpha 0 = keep the texture's own colours.
//   slots: 0 skin, 1 top, 2 bottom, 3 shoes, 4 hat, 5 gear, 6 glossy fixed (eyes,
//          glasses), 8 matte fixed (belts)

uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D normal_atlas : hint_normal, filter_linear_mipmap, repeat_disable;

instance uniform vec2 skin_offset : instance_index(0) = vec2(0.0);           // atlas offset of this person's skin tile
instance uniform vec4 skin_tint : source_color, instance_index(1) = vec4(1.0);
instance uniform vec4 top_color : source_color, instance_index(2) = vec4(0.0);
instance uniform vec4 bottom_color : source_color, instance_index(3) = vec4(0.0);
instance uniform vec4 shoe_color : source_color, instance_index(4) = vec4(0.0);
instance uniform vec4 hat_color : source_color, instance_index(5) = vec4(0.0);
instance uniform vec4 gear_color : source_color, instance_index(6) = vec4(0.0);
instance uniform float hit : instance_index(7) = 0.0;
instance uniform vec4 hair_color : source_color, instance_index(8) = vec4(0.0);

varying flat float slot;
varying flat float lumref;

void vertex() {
	slot = floor(COLOR.r * 255.0 + 0.5);
	lumref = COLOR.g;
	if (slot < 0.5) {
		UV += skin_offset;
	}
}

vec3 tint(vec3 c, vec4 k) {
	if (k.a <= 0.001) {
		return c;
	}
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	vec3 t = k.rgb * clamp(l / max(lumref, 0.04), 0.0, 2.4);
	return mix(c, t, k.a);
}

void fragment() {
	vec3 c = texture(albedo_atlas, UV).rgb;
	float rough = 0.84;
	float spec = 0.32;
	int s = int(slot);
	if (s == 0) {
		c *= skin_tint.rgb;
		rough = 0.62;
		spec = 0.36;
		// a little wrapped, warm light on skin reads as subsurface scattering
		BACKLIGHT = vec3(0.10, 0.035, 0.025);
	} else if (s == 1) {
		c = tint(c, top_color);
	} else if (s == 2) {
		c = tint(c, bottom_color);
	} else if (s == 3) {
		// tint the uppers, keep white soles / laces / toe caps white
		float l0 = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(tint(c, shoe_color), c, smoothstep(0.42, 0.62, l0));
		rough = 0.62;
	} else if (s == 4) {
		c = tint(c, hat_color);
	} else if (s == 5) {
		c = tint(c, gear_color);
		rough = 0.66;
	} else if (s == 6) {
		rough = 0.12;
		spec = 0.65;
	} else if (s == 8) {
		rough = 0.55;
	}
	ALBEDO = mix(c, vec3(1.0, 0.25, 0.2), hit);
	NORMAL_MAP = texture(normal_atlas, UV).rgb;
	ROUGHNESS = rough;
	SPECULAR = spec;
}
