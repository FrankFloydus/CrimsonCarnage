shader_type spatial;
render_mode cull_disabled;

#include "res://addons/dynamic_sky/weather/wind/foliage_wind.gdshaderinc"

uniform vec3 leaf_color : source_color = vec3(0.30, 0.43, 0.20);
uniform vec3 dry_color : source_color = vec3(0.47, 0.39, 0.23);
uniform vec3 stem_color : source_color = vec3(0.31, 0.23, 0.12);
uniform float transmission : hint_range(0.0, 0.6) = 0.27;
uniform float leaf_roughness : hint_range(0.4, 1.0) = 0.83;
uniform float vein_strength : hint_range(0.0, 0.3) = 0.10;
instance uniform vec4 weather_surface = vec4(0.0);

void vertex() {
	float woody = step(1.1, UV.x) * (1.0 - step(2.1, UV.x));
	VERTEX.y *= 1.0 - smoothstep(0.3, 0.95, weather_surface.y) * 0.26;
	VERTEX = dynamic_sky_bend_foliage(VERTEX, MODEL_MATRIX, TIME, 1.0 - woody * 0.8);
}

void fragment() {
	bool wood = UV.x > 1.1 && UV.x < 2.1;
	bool dry = UV.x > 2.1;
	vec2 leaf_uv = UV - vec2(dry ? 2.2 : 0.0, 0.0);
	float across = abs(leaf_uv.x - 0.5) * 2.0;
	float rib = 1.0 - smoothstep(0.025, 0.075, across);
	float side_vein = 1.0 - smoothstep(0.04, 0.12, abs(fract(leaf_uv.y * 9.0 - across * 0.65) - 0.5));
	float detail = vein_strength * (rib * 0.45 + side_vein * 0.18);
	vec3 green = (dry ? dry_color : leaf_color) * COLOR.rgb;
	green *= 0.92 + 0.08 * smoothstep(0.0, 0.7, leaf_uv.y);
	green *= 1.0 + detail;
	vec3 base = wood ? stem_color * COLOR.rgb : green;
	float up = max((mat3(INV_VIEW_MATRIX) * NORMAL).y, 0.0);
	float snow = smoothstep(0.28, 0.90, weather_surface.y) * smoothstep(0.08, 0.72, up);
	float wet = weather_surface.x * (1.0 - snow);
	base *= 1.0 - wet * 0.19;
	base = mix(base, vec3(0.18, 0.14, 0.085), weather_surface.z * (0.18 + up * 0.24));
	ALBEDO = mix(base, vec3(0.86, 0.90, 0.94), snow);
	ROUGHNESS = mix(wood ? 0.91 : leaf_roughness - detail * 0.32, 0.61, wet);
	ROUGHNESS = mix(ROUGHNESS, 0.85, snow);
	SPECULAR = wood ? 0.18 : 0.26;
	AO = wood ? 1.0 : mix(0.90, 1.0, smoothstep(0.0, 0.24, leaf_uv.y));
	BACKLIGHT = vec3(wood ? 0.0 : transmission * (1.0 - snow));
}
