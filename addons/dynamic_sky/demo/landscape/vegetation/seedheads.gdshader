shader_type spatial;

#include "res://addons/dynamic_sky/weather/wind/foliage_wind.gdshaderinc"

instance uniform vec4 weather_surface = vec4(0.0);

void vertex() {
	VERTEX = dynamic_sky_bend_foliage(VERTEX, MODEL_MATRIX, TIME, 0.65);
}

void fragment() {
	vec3 straw = vec3(0.31, 0.236, 0.117) * COLOR.rgb;
	float snow = smoothstep(0.35, 0.92, weather_surface.y);
	ALBEDO = mix(straw * (1.0 - weather_surface.x * 0.23), vec3(0.86, 0.88, 0.90), snow);
	BACKLIGHT = vec3(0.72 * (1.0 - snow));
	ROUGHNESS = mix(0.89, 0.67, weather_surface.x);
	SPECULAR = 0.18;
}
