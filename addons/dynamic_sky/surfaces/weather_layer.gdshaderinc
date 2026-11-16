#ifndef DYNAMIC_SKY_WEATHER_LAYER
#define DYNAMIC_SKY_WEATHER_LAYER

#include "res://addons/dynamic_sky/surfaces/snow_deposition.gdshaderinc"
#include "res://addons/dynamic_sky/surfaces/material_sampling.gdshaderinc"
#include "res://addons/dynamic_sky/surfaces/rain_puddles.gdshaderinc"
#include "res://addons/dynamic_sky/surfaces/rain_contact_normal.gdshaderinc"
#include "res://addons/dynamic_sky/surfaces/radial_material_field.gdshaderinc"

// DynamicSky supplies wetness, snow, dust and current rain per geometry instance.
instance uniform vec4 dynamic_sky_weather = vec4(0.0);

group_uniforms Weather;
uniform bool dynamic_sky_weather_enabled = true;
// Roughness of a saturated surface between pools. Smoother base materials retain their finish.
uniform float dynamic_sky_wet_roughness : hint_range(0.04, 0.6, 0.01) = 0.22;
// Normal strength of small rain contacts on the wet film between pools.
uniform float dynamic_sky_wet_film_ripple_strength : hint_range(0.0, 1.0, 0.01) = 0.10;
uniform sampler2D dynamic_sky_snow_albedo : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dynamic_sky_snow_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dynamic_sky_snow_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float dynamic_sky_snow_scale : hint_range(0.01, 4.0) = 0.625;
uniform vec3 dynamic_sky_dust_color : source_color = vec3(0.67, 0.49, 0.29);
group_uniforms;

void dynamic_sky_apply_weather(
	vec3 position_world, vec3 geometric_normal_world, mat3 view_from_world, vec4 weather,
	inout vec3 albedo, inout vec3 normal_view, inout float surface_roughness,
	inout float metallic, inout float specular, inout float occlusion,
	inout float clearcoat, inout float clearcoat_roughness
) {
	if (!dynamic_sky_weather_enabled || max(max(weather.x, weather.y), weather.z) <= 0.0) {
		return;
	}
	vec3 up = normalize(geometric_normal_world);
	float upward = smoothstep(0.38, 0.93, up.y);
	vec2 ground = position_world.xz;
	float wet = weather.x * mix(0.37, 1.0, upward);
	float dust_pattern = snow_deposit_noise(ground * 0.45 + vec2(position_world.y * 0.19, 0.0));
	float dust = smoothstep(dust_pattern - 0.22, dust_pattern + 0.34, weather.z) * mix(0.22, 0.92, upward);
	dust *= smoothstep(0.0, 0.15, weather.z);
	albedo = mix(albedo, dynamic_sky_dust_color * mix(0.71, 0.96, dust_pattern), dust);
	surface_roughness = mix(surface_roughness, 0.94, dust);
	metallic = mix(metallic, 0.0, dust);

	float snow = snow_deposition(ground, up.y, weather.y, 1.0, 0.61);
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
		// A water film smooths the whole wet surface before deeper pools collect.
		albedo *= mix(1.0, 0.53, wet);
		float substrate = smoothstep(0.34, 0.85, surface_roughness);
		float film_roughness = dynamic_sky_wet_roughness * mix(0.58, 1.22, substrate);
		surface_roughness = mix(surface_roughness, min(surface_roughness, film_roughness), wet);
		float footprint = max(length(dFdx(ground)), length(dFdy(ground)));
		vec2 pool = rain_puddle_coverage(ground, 1.2, 0.60, 0.22, occlusion, wet, up.y, footprint);
		float puddle = pool.x;
		float thin_film = wet * upward * (1.0 - puddle);
		clearcoat = max(clearcoat, thin_film * 0.30);
		clearcoat_roughness = mix(clearcoat_roughness, mix(0.34, 0.77, substrate), thin_film);
		float rain = weather.w * smoothstep(0.90, 0.985, up.y);
		vec3 contact = vec3(0.0);
		if (rain_contact_gain > 0.0 && rain_contact_mapping.z > 0.0 && up.y >= 0.35 && weather.w > 0.01) {
			contact = rain_contact_surface_stamp(position_world, footprint);
			contact.z *= rain_contact_gain * smoothstep(0.05, 0.45, wet);
		}
		float film_weight = dynamic_sky_wet_film_ripple_strength * wet * (1.0 - puddle) * (1.0 - contact.z);
		vec3 impacts = vec3(0.0);
		vec2 film_normal = vec2(0.0);
		float ripple_detail = rain_puddle_lod(footprint);
		if (rain > 0.01 && ripple_detail > 0.0 && wet > 0.12) {
			impacts = rain_puddle_impacts(ground, 6.0, rain, footprint, TIME, film_weight > 0.0, film_normal);
		}
		albedo *= mix(1.0, 0.82, pool.y);
		surface_roughness = mix(surface_roughness, 0.055, puddle);
		surface_roughness = mix(surface_roughness, min(surface_roughness, 0.04),
			impacts.y * wet * (1.0 - puddle) * 0.55);
		metallic *= 1.0 - puddle;
		// Godot's dielectric F0 is 0.16 * SPECULAR squared; water gives F0 = 0.0204.
		specular = mix(specular, sqrt(0.0204 / 0.16), puddle);
		float ripple_strength = 0.52 + 0.48 * pool.y;
		if (puddle > 0.0 && rain > 0.01) {
			float pool_depth = puddle * wet * ripple_strength;
			surface_roughness = rain_puddle_filtered_roughness(surface_roughness, pool_depth, ripple_detail,
				rain_procedural_pool_variance(6.0, rain));
		}
		vec3 pool_normal = normalize(vec3(impacts.x * ripple_strength, 1.0, impacts.z * ripple_strength));
		normal_view = normalize(mix(normal_view, view_from_world * pool_normal, puddle));
		// Use the live stamp only on its hit surface. Keep the pool waves independent.
		vec3 contact_offset = vec3(contact.x, 0.0, contact.y);
		contact_offset -= up * dot(contact_offset, up);
		vec3 film_offset = view_from_world * (
			vec3(film_normal.x, 0.0, film_normal.y) * film_weight + contact_offset * contact.z
		);
		if (dot(film_offset, film_offset) > 0.0) {
			normal_view = normalize(normal_view + film_offset);
		}
	}
}

// Call after the shader has authored its base material outputs.
#define APPLY_DYNAMIC_SKY_WEATHER_STATE(position_world, normal_world, weather) dynamic_sky_apply_weather(position_world, normal_world, mat3(VIEW_MATRIX), weather, ALBEDO, NORMAL, ROUGHNESS, METALLIC, SPECULAR, AO, CLEARCOAT, CLEARCOAT_ROUGHNESS)
#define APPLY_DYNAMIC_SKY_WEATHER(position_world, normal_world) APPLY_DYNAMIC_SKY_WEATHER_STATE(position_world, normal_world, dynamic_sky_radial_weather_at(position_world, dynamic_sky_weather))

#endif
