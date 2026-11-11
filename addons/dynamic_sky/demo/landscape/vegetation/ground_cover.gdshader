shader_type spatial;
render_mode cull_disabled;

#include "res://addons/dynamic_sky/weather/wind/foliage_wind.gdshaderinc"

uniform sampler2D meadow_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
instance uniform vec4 weather_surface = vec4(0.0);
varying vec3 world_position;
varying float blade_height;

void vertex() {
	blade_height = VERTEX.y;
	float buried = smoothstep(0.16, 0.78, weather_surface.y);
	VERTEX.y *= mix(1.0, 0.16, buried);
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX = dynamic_sky_bend_foliage(VERTEX, MODEL_MATRIX, TIME, 0.8);
}

void fragment() {
	vec3 meadow = texture(meadow_albedo, world_position.xz * 0.50).rgb;
	vec3 leaf = mix(meadow * vec3(0.94, 1.12, 0.76), vec3(0.11, 0.17, 0.075), 0.46);
	leaf *= mix(0.76, 1.13, smoothstep(0.0, 0.35, blade_height)) * COLOR.rgb;
	float dry_blade = clamp(COLOR.a, 0.0, 1.0);
	vec3 straw = vec3(0.24, 0.188, 0.105) * COLOR.rgb;
	leaf = mix(leaf, straw, dry_blade * 0.72);
	float snow = smoothstep(0.30, 0.85, weather_surface.y);
	leaf = mix(leaf, vec3(0.88, 0.90, 0.91), snow * 0.86);
	ALBEDO = leaf * (1.0 - weather_surface.x * 0.19);
	BACKLIGHT = vec3((1.0 - snow) * 0.38);
	ROUGHNESS = mix(0.93, 0.73, weather_surface.x);
	SPECULAR = 0.16;
}
