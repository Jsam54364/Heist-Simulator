shader_type spatial;
// All small car parts (trim, bumpers, chrome, plates, head/tail lights, wheels) share
// this one material: colour from vertex colour (sRGB), roughness/metal from UV2,
// emission class in COLOR.a (0 none, 0.5 headlight, 1 tail light). The tail light
// brightness is a per-car instance uniform, so every car can share the material.
instance uniform float brake = 0.8;
varying vec2 rm;

void vertex() {
	rm = UV2;
}

void fragment() {
	vec3 c = COLOR.rgb;
	c = mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
	ALBEDO = c;
	ROUGHNESS = rm.x;
	METALLIC = rm.y;
	float e = COLOR.a > 0.75 ? brake : (COLOR.a > 0.25 ? 2.5 : 0.0);
	EMISSION = c * e;
}
