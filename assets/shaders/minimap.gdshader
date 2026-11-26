shader_type canvas_item;
// Round, rotating radar: samples the pre-rendered city map around the player.

uniform sampler2D map_tex : filter_linear, repeat_disable;
uniform vec2 center_uv = vec2(0.5);
uniform float rot = 0.0;
uniform vec2 span_uv = vec2(0.3);
uniform vec4 search_color = vec4(0.0);
uniform vec2 search_uv = vec2(-9.0);
uniform float search_r = 0.0;
uniform vec2 hot_uv = vec2(-9.0);
uniform float hot_r = 0.0;
uniform vec2 world_size = vec2(350.0, 300.0);
uniform vec4 water = vec4(0.11, 0.25, 0.33, 1.0);

void fragment() {
	vec2 p = UV - 0.5;
	float r = length(p);
	if (r > 0.5) discard;
	float c = cos(rot), s = sin(rot);
	vec2 q = vec2(p.x * c + p.y * s, -p.x * s + p.y * c);
	vec2 uv = center_uv + q * span_uv;
	vec4 col = (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) ? water : texture(map_tex, uv);
	if (length((uv - search_uv) * world_size) < search_r) {
		col.rgb = mix(col.rgb, search_color.rgb, search_color.a);
	}
	float hd = length((uv - hot_uv) * world_size);
	if (hot_r > 0.0 && hd < hot_r) {
		col.rgb = mix(col.rgb, vec3(1.0, 0.55, 0.2), hd > hot_r - 3.0 ? 0.6 : 0.12);
	}
	col.rgb *= 1.0 - smoothstep(0.38, 0.5, r) * 0.35;
	col.a = 0.92 * smoothstep(0.5, 0.49, r);
	COLOR = col;
}
