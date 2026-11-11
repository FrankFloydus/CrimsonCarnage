shader_type spatial;
render_mode cull_disabled;

#include "res://addons/dynamic_sky/weather/wind/foliage_wind.gdshaderinc"

uniform sampler2D leaf_atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D bark_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
instance uniform vec4 weather_surface = vec4(0.0);
varying float twig;

void vertex() {
	twig = step(1.10, UV.x);
	VERTEX.y *= mix(1.0, 0.62, smoothstep(0.3, 0.9, weather_surface.y));
	VERTEX = dynamic_sky_bend_foliage(VERTEX, MODEL_MATRIX, TIME, 1.0 - twig);
}

void fragment() {
	vec3 foliage = texture(leaf_atlas, UV).rgb * COLOR.rgb;
	vec3 bark = texture(bark_albedo, vec2((UV.x - 1.23) * 2.2, UV.y * 0.7)).rgb;
	vec3 surface = mix(foliage, bark * 0.74, twig);
	float upward = max((mat3(INV_VIEW_MATRIX) * NORMAL).y, 0.0);
	float snow = smoothstep(0.24, 0.88, weather_surface.y) * smoothstep(0.12, 0.72, upward);
	ALBEDO = mix(surface * (1.0 - weather_surface.x * 0.22), vec3(0.87, 0.89, 0.91), snow);
	BACKLIGHT = vec3((1.0 - twig) * (1.0 - snow) * 0.34);
	ROUGHNESS = mix(0.88, 0.58, weather_surface.x * (1.0 - snow));
	SPECULAR = 0.23;
}
