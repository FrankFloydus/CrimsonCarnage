#ifndef DYNAMIC_SKY_WEATHER_LAYER
#define DYNAMIC_SKY_WEATHER_LAYER

#include "res://addons/dynamic_sky/surfaces/snow_deposition.gdshaderinc"
#include "res://addons/dynamic_sky/surfaces/material_sampling.gdshaderinc"

// DynamicSky supplies wetness, snow, dust and current rain per geometry instance.
instance uniform vec4 dynamic_sky_weather = vec4(0.0);

group_uniforms Weather;
uniform bool dynamic_sky_weather_enabled = true;
uniform sampler2D dynamic_sky_snow_albedo : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dynamic_sky_snow_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dynamic_sky_snow_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float dynamic_sky_snow_scale : hint_range(0.01, 4.0) = 0.625;
uniform vec3 dynamic_sky_dust_color : source_color = vec3(0.67, 0.49, 0.29);
group_uniforms;

void dynamic_sky_apply_weather(
	vec3 position_world, vec3 geometric_normal_world, mat3 view_from_world,
	inout vec3 albedo, inout vec3 normal_view, inout float surface_roughness,
	inout float metallic, inout float specular, inout float occlusion
) {
	if (!dynamic_sky_weather_enabled || max(max(dynamic_sky_weather.x, dynamic_sky_weather.y), dynamic_sky_weather.z) <= 0.0) {
		return;
	}
	vec3 up = normalize(geometric_normal_world);
	float upward = smoothstep(0.38, 0.93, up.y);
	vec2 ground = position_world.xz;
	float wet = dynamic_sky_weather.x * mix(0.37, 1.0, upward);
	float dust_pattern = snow_deposit_noise(ground * 0.45 + vec2(position_world.y * 0.19, 0.0));
	float dust = smoothstep(dust_pattern - 0.22, dust_pattern + 0.34, dynamic_sky_weather.z) * mix(0.22, 0.92, upward);
	albedo = mix(albedo, dynamic_sky_dust_color * mix(0.71, 0.96, dust_pattern), dust);
	surface_roughness = mix(surface_roughness, 0.94, dust);
	metallic = mix(metallic, 0.0, dust);

	float snow = snow_deposition(ground, up.y, dynamic_sky_weather.y, 1.0, 0.61);
	if (snow > 0.001) {
		vec3 weights = pow(abs(up), vec3(4.0));
		weights /= max(weights.x + weights.y + weights.z, 0.001);
		vec3 signs = step(vec3(0.0), up) * 2.0 - 1.0;
		vec3 point = position_world * dynamic_sky_snow_scale;
		TerrainPBR coating = terrain_triplanar(
			dynamic_sky_snow_albedo, dynamic_sky_snow_normal, dynamic_sky_snow_orm,
			point, dFdx(point), dFdy(point), weights, signs, 1.8, 1.0
		);
		vec3 deviation = coating.deviation - up * dot(coating.deviation, up);
		vec3 snow_normal = normalize(view_from_world * normalize(up + deviation * 0.58));
		albedo = mix(albedo, coating.albedo, snow);
		surface_roughness = mix(surface_roughness, coating.orm.g, snow);
		occlusion = mix(occlusion, coating.orm.r, snow);
		metallic = mix(metallic, 0.0, snow);
		specular = mix(specular, 0.35, snow);
		normal_view = normalize(mix(normal_view, snow_normal, snow));
		wet *= 1.0 - snow * 0.74;
	}
	if (wet > 0.0) {
		float low_spots = snow_deposit_noise(ground * 1.2) * 0.74 + snow_deposit_noise(ground * 3.6) * 0.26;
		float puddle = smoothstep(0.57, 0.80, low_spots) * smoothstep(0.42, 0.96, wet) * upward;
		albedo *= mix(1.0, 0.53, wet) * mix(1.0, 0.68, puddle);
		surface_roughness = mix(mix(surface_roughness, 0.35, wet), 0.075, puddle);
		metallic *= 1.0 - puddle;
		specular = mix(specular, 0.58, puddle);
		normal_view = normalize(mix(normal_view, view_from_world * up, puddle * 0.94));
	}
}

// Call after the shader has authored its base material outputs.
#define APPLY_DYNAMIC_SKY_WEATHER(position_world, normal_world) dynamic_sky_apply_weather(position_world, normal_world, mat3(VIEW_MATRIX), ALBEDO, NORMAL, ROUGHNESS, METALLIC, SPECULAR, AO)

#endif
