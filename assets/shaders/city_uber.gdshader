shader_type spatial;
// One material for (almost) the whole city: every textured/plain surface samples its
// PBR set from Texture2DArrays, picked per vertex (UV2.x = layer). Merging materials this
// way turns ~20 draw calls per chunk into one. Look matches the original ORM materials:
// albedo x vertex colour (sRGB), ORM (AO / roughness / metal), tangent-space normal map.

uniform sampler2DArray albedo_arr : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray normal_arr : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray orm_arr : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 params[32];   // x: use vertex colour, y: emission energy, z: normal strength, w: backlight
uniform vec4 tint[32];     // linear albedo multiplier
uniform float ao_light_affect = 0.25;

varying flat int layer;

void vertex() {
	layer = int(UV2.x + 0.5);
}

void fragment() {
	vec4 p = params[layer];
	vec3 uvw = vec3(UV, float(layer));
	vec3 base = texture(albedo_arr, uvw).rgb * tint[layer].rgb;
	if (p.x > 0.5) {
		vec3 c = COLOR.rgb;
		base *= mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
	}
	vec3 orm = texture(orm_arr, uvw).rgb;
	ALBEDO = base;
	AO = orm.r;
	AO_LIGHT_AFFECT = ao_light_affect;
	ROUGHNESS = orm.g;
	METALLIC = orm.b;
	if (p.z > 0.0) {
		NORMAL_MAP = texture(normal_arr, uvw).rgb;
		NORMAL_MAP_DEPTH = p.z;
	}
	EMISSION = base * p.y;
	// palm fronds: light passing through leaves (matches the old leaf material's backlight)
	BACKLIGHT = vec3(0.051, 0.133, 0.010) * p.w;
}
