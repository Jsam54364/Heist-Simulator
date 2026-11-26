shader_type spatial;
// Far-distance HLOD for the city: every building is a textured box sampled from one
// small atlas (one draw call per chunk), with no normal/ORM maps and no specular.
// UV holds texture repeats; UV2.x holds the atlas cell (-1 = vertex colour only).
render_mode diffuse_lambert, specular_disabled, cull_back;

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 cells = vec2(4.0, 2.0);
uniform float roughness = 0.92;
varying flat float cell;

void vertex() {
	cell = UV2.x;
}

void fragment() {
	vec3 base = COLOR.rgb;
	base = mix(base / 12.92, pow((base + 0.055) / 1.055, vec3(2.4)), step(0.04045, base));
	if (cell >= 0.0) {
		vec2 org = vec2(mod(cell, cells.x), floor(cell / cells.x));
		vec2 cuv = (org + clamp(fract(UV), 0.004, 0.996)) / cells;
		// gradients from the continuous UV avoid mip seams at the fract() wrap
		base *= textureGrad(atlas, cuv, dFdx(UV) / cells, dFdy(UV) / cells).rgb;
	}
	ALBEDO = base;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
}
