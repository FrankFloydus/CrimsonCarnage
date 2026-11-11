shader_type spatial;

#include "res://addons/dynamic_sky/weather/wind/foliage_wind.gdshaderinc"

uniform sampler2D spruce_bough : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D bark_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bark_normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bark_orm_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

instance uniform vec4 weather_surface = vec4(0.0);

varying float model_height;
varying vec3 crown_position;

void vertex() {
	model_height = VERTEX.y;
	crown_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float flutter_mask = smoothstep(0.07, 0.54, length(VERTEX.xz)) * (1.0 - step(1.10, UV.x));
	VERTEX = dynamic_sky_bend_foliage(VERTEX, MODEL_MATRIX, TIME, flutter_mask);
}

void fragment() {
	bool trunk = UV.x > 1.10;
	if (trunk) {
		vec2 bark_uv = vec2((UV.x - 1.23) * 1.26, UV.y * 0.53);
		vec3 bark = texture(bark_texture, bark_uv).rgb;
		vec3 orm = texture(bark_orm_texture, bark_uv).rgb;
		ALBEDO = bark * mix(vec3(0.58, 0.52, 0.45), vec3(0.87, 0.79, 0.66), smoothstep(0.0, 3.7, model_height));
		ALBEDO *= COLOR.rgb;
		NORMAL_MAP = texture(bark_normal_texture, bark_uv).rgb;
		NORMAL_MAP_DEPTH = 0.61;
		AO = orm.r;
		ROUGHNESS = mix(0.62, orm.g, 0.84);
	} else {
		vec3 branch = texture(spruce_bough, UV).rgb;
		float canopy = smoothstep(0.85, 4.5, model_height);
		vec3 needles = branch * mix(vec3(0.73, 0.81, 0.62), vec3(1.03, 1.18, 0.94), canopy);
		ALBEDO = needles * COLOR.rgb;
		BACKLIGHT = needles * 0.29;
		SPECULAR = 0.24;
		ROUGHNESS = 0.89;
	}

	float exposed = smoothstep(0.15, 0.81, (mat3(INV_VIEW_MATRIX) * NORMAL).y);
	float drift = sin(dot(crown_position, vec3(1.67, 1.82, 1.35))) * 0.54
		+ cos(dot(crown_position, vec3(-3.12, 4.41, 2.67))) * 0.46;
	float snowline = weather_surface.y - (0.52 + drift * 0.22);
	float feather = clamp(fwidth(snowline) * 0.75, 0.027, 0.12);
	float snow = smoothstep(-feather, 0.14 + feather, snowline) * exposed;
	float wind_shed = clamp(length(dynamic_sky_wind_velocity) * 0.013, 0.0, 0.33);
	snow *= (1.0 - wind_shed) * (trunk ? 0.79 : 1.0);
	float wet = weather_surface.x * (1.0 - snow);
	float dust = weather_surface.z * (0.19 + exposed * 0.26) * (1.0 - snow);
	ALBEDO *= 1.0 - wet * 0.31;
	ALBEDO = mix(ALBEDO, vec3(0.176, 0.134, 0.093), dust);
	ALBEDO = mix(ALBEDO, vec3(0.66, 0.75, 0.84) * (0.94 + drift * 0.04), snow);
	ROUGHNESS = mix(mix(ROUGHNESS, 0.54, wet), 0.82, snow);
	BACKLIGHT *= 1.0 - snow * 0.85;
}
