// Ocean surface: scrolling normal maps, gentle vertex waves, fresnel tint and shore foam.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform vec3 shallow_color : source_color = vec3(0.16, 0.62, 0.70);
uniform vec3 deep_color : source_color = vec3(0.03, 0.22, 0.38);
uniform sampler2D normal_tex : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform float uv_scale = 0.045;
uniform float flow_speed = 0.02;
uniform float wave_height = 0.12;
// land mask of the island: r = land (5 m cells), g = blurred "near land" field
uniform sampler2D land_tex : filter_linear, repeat_disable;
uniform vec2 land_origin = vec2(-1300.0, -340.0);
uniform vec2 land_size = vec2(2600.0, 680.0);

varying vec3 world_pos;

vec2 land_at(vec2 xz) {
	vec2 uv = (xz - land_origin) / land_size;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) return vec2(0.0);
	return texture(land_tex, uv).rg;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME;
	float fade = 1.0 - clamp(land_at(world_pos.xz).g * 1.6, 0.0, 1.0);
	VERTEX.y += (sin(world_pos.x * 0.12 + t * 1.1) * 0.6 + cos(world_pos.z * 0.17 + t * 0.8) * 0.4) * wave_height * fade;
}

void fragment() {
	vec2 uv = world_pos.xz * uv_scale;
	vec3 n1 = texture(normal_tex, uv + vec2(TIME * flow_speed, TIME * flow_speed * 0.6)).rgb;
	vec3 n2 = texture(normal_tex, uv * 1.9 - vec2(TIME * flow_speed * 0.7, -TIME * flow_speed * 0.4)).rgb;
	NORMAL_MAP = normalize(mix(n1, n2, 0.5));
	NORMAL_MAP_DEPTH = 0.7;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec2 la = land_at(world_pos.xz);
	float dist = 1.0 - clamp(la.g, 0.0, 1.0);
	vec3 col = mix(shallow_color, deep_color, dist);
	col = mix(col, vec3(0.75, 0.86, 0.95), fres * 0.35);
	float shore = clamp(la.r * 1.6, 0.0, 1.0);
	float foam = smoothstep(0.55, 0.9, shore + (n1.r - 0.5) * 0.8 + sin(world_pos.z * 0.4 + TIME * 1.5) * 0.08);
	ALBEDO = mix(col, vec3(0.95), foam);
	ROUGHNESS = mix(0.04, 0.6, foam);
	METALLIC = 0.0;
	SPECULAR = 0.7;
}
