// Ocean surface: scrolling normal maps, gentle vertex waves, fresnel tint and shore foam.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform vec3 shallow_color : source_color = vec3(0.16, 0.62, 0.70);
uniform vec3 deep_color : source_color = vec3(0.03, 0.22, 0.38);
uniform sampler2D normal_tex : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform float uv_scale = 0.045;
uniform float flow_speed = 0.02;
uniform float wave_height = 0.12;
uniform float shore_x = 181.0;
uniform float foam_width = 5.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME;
	float fade = clamp((world_pos.x - shore_x) / 20.0, 0.0, 1.0);
	VERTEX.y += (sin(world_pos.x * 0.12 + t * 1.1) * 0.6 + cos(world_pos.z * 0.17 + t * 0.8) * 0.4) * wave_height * fade;
}

void fragment() {
	vec2 uv = world_pos.xz * uv_scale;
	vec3 n1 = texture(normal_tex, uv + vec2(TIME * flow_speed, TIME * flow_speed * 0.6)).rgb;
	vec3 n2 = texture(normal_tex, uv * 1.9 - vec2(TIME * flow_speed * 0.7, -TIME * flow_speed * 0.4)).rgb;
	NORMAL_MAP = normalize(mix(n1, n2, 0.5));
	NORMAL_MAP_DEPTH = 0.7;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	float dist = clamp((world_pos.x - shore_x) / 60.0, 0.0, 1.0);
	vec3 col = mix(shallow_color, deep_color, dist);
	col = mix(col, vec3(0.75, 0.86, 0.95), fres * 0.35);
	float shore = 1.0 - clamp((world_pos.x - shore_x) / foam_width, 0.0, 1.0);
	float foam = smoothstep(0.55, 0.9, shore + (n1.r - 0.5) * 0.8 + sin(world_pos.z * 0.4 + TIME * 1.5) * 0.08);
	ALBEDO = mix(col, vec3(0.95), foam);
	ROUGHNESS = mix(0.04, 0.6, foam);
	METALLIC = 0.0;
	SPECULAR = 0.7;
}
