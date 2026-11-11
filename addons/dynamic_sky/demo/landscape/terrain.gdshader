shader_type spatial;

#include "res://addons/dynamic_sky/surfaces/snow_deposition.gdshaderinc"
#include "res://addons/dynamic_sky/surfaces/surface_shelter.gdshaderinc"
#include "res://addons/dynamic_sky/surfaces/material_sampling.gdshaderinc"

group_uniforms Material_Maps;
uniform sampler2D scree_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D scree_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D scree_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_macro_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_macro_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D snow_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D snow_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D snow_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D meadow_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D meadow_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D meadow_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

group_uniforms Physical_Scale;
// Texture repeats per world meter. A meadow repeat covers two meters by default.
uniform float meadow_texture_scale : hint_range(0.05, 2.0, 0.01) = 0.50;
uniform float scree_texture_scale : hint_range(0.05, 2.0, 0.01) = 0.25;
uniform float rock_texture_scale : hint_range(0.05, 2.0, 0.01) = 0.4545;
uniform float geological_texture_scale : hint_range(0.005, 0.15, 0.001) = 0.03125;
uniform float snow_texture_scale : hint_range(0.05, 2.0, 0.01) = 0.625;
// Number of texture repeats in a stochastic triangle before its random offset changes.
uniform float stochastic_patch_repeats : hint_range(1.0, 6.0, 0.1) = 2.7;
uniform float detail_normal_strength : hint_range(0.0, 2.0, 0.01) = 0.78;
uniform float geological_normal_strength : hint_range(0.0, 2.0, 0.01) = 1.0;

group_uniforms Biomes_And_Weather;
// The geometry owns meadow R, trail G, drainage B, and forest A masks.
uniform bool use_biome_vertex_colors = false;
// Inclination from world up, in degrees, across which talus becomes exposed bedrock.
uniform vec2 rock_slope_degrees = vec2(24.0, 48.0);
// Altitude interval in world meters where unvegetated alpine ground reveals more bedrock.
uniform vec2 bedrock_height_range = vec2(180.0, 420.0);
uniform vec2 natural_snowline = vec2(420.0, 580.0);
// Shelter center XZ followed by footprint half extents in its local XZ axes.
uniform vec4 shelter_bounds = vec4(0.0);
uniform float shelter_yaw_degrees = 0.0;
instance uniform vec4 weather_surface = vec4(0.0);
group_uniforms;

varying vec3 world_position;
varying vec3 world_normal;
varying vec4 biome_weights;

float cell_value(vec2 cell) {
	return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 position) {
	vec2 cell = floor(position);
	vec2 offset = fract(position);
	offset *= offset * (3.0 - 2.0 * offset);
	float lower = mix(cell_value(cell), cell_value(cell + vec2(1.0, 0.0)), offset.x);
	float upper = mix(cell_value(cell + vec2(0.0, 1.0)), cell_value(cell + 1.0), offset.x);
	return mix(lower, upper, offset.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = MODEL_NORMAL_MATRIX * NORMAL;
	biome_weights = COLOR;
}

void fragment() {
	vec2 ground = world_position.xz;
	vec3 up = normalize(world_normal);
	vec3 position_dx = dFdx(world_position);
	vec3 position_dy = dFdy(world_position);
	vec3 axis_blend = pow(abs(up), vec3(6.0));
	axis_blend /= max(dot(axis_blend, vec3(1.0)), 0.00001);
	vec3 signs = step(vec3(0.0), up) * 2.0 - 1.0;
	float distance_to_eye = length(VERTEX);
	float distance_blend = smoothstep(32.0, 240.0, distance_to_eye);
	float coarse = value_noise(ground * 0.084);
	float medium = value_noise(ground * 0.54);
	float weathering = value_noise(ground * 0.037 + world_position.y * vec2(0.22, 0.047));
	float broad_variation = value_noise(ground * 0.012 + vec2(11.2, 3.8));
	float slope = 1.0 - up.y;
	float rock_start = 1.0 - cos(radians(clamp(rock_slope_degrees.x, 0.0, 89.0)));
	float rock_end = 1.0 - cos(radians(clamp(rock_slope_degrees.y, 0.0, 89.0)));
	float cliff_exposure = smoothstep(rock_start, max(rock_start + 0.0001, rock_end), slope + (weathering - 0.5) * 0.055);
	float altitude_rock = smoothstep(bedrock_height_range.x, max(bedrock_height_range.x + 1.0, bedrock_height_range.y), world_position.y);
	altitude_rock *= use_biome_vertex_colors ? mix(0.72, 0.30, clamp(biome_weights.r, 0.0, 1.0)) : 0.0;
	float exposed = max(cliff_exposure, altitude_rock);
	float shore = 1.0 - smoothstep(-30.0, -24.0, world_position.y + medium * 2.1);
	float trail = use_biome_vertex_colors ? smoothstep(0.08, 0.78, biome_weights.g) : 0.0;
	float drainage = use_biome_vertex_colors ? clamp(biome_weights.b, 0.0, 1.0) : 0.0;
	float forest = use_biome_vertex_colors ? clamp(biome_weights.a, 0.0, 1.0) : 0.0;
	float meadow_weight = use_biome_vertex_colors
		? clamp(biome_weights.r * (1.0 - trail) * (1.0 - exposed) * (1.0 - shore), 0.0, 1.0)
		: 0.0;
	meadow_weight *= 1.0 - forest * mix(0.28, 0.62, broad_variation);
	// Use the shared meadow envelope, with broken soil openings inside it at a meter scale.
	float meadow_openings = smoothstep(0.24, 0.62, coarse * 0.68 + weathering * 0.32);
	meadow_weight *= mix(0.58, 1.0, meadow_openings);
	if (!use_biome_vertex_colors) {
		exposed = 1.0;
	}
	exposed *= 1.0 - trail * 0.68;
	float patch = max(stochastic_patch_repeats, 1.0);
	TerrainPBR soil = terrain_triplanar(scree_albedo, scree_normal, scree_orm,
		world_position * scree_texture_scale, position_dx * scree_texture_scale, position_dy * scree_texture_scale,
		axis_blend, signs, patch, 2.8);
	vec3 soil_tint = mix(vec3(0.83, 0.78, 0.65), vec3(1.02, 0.99, 0.91), broad_variation);
	soil_tint = mix(soil_tint, vec3(0.61, 0.55, 0.43), forest * 0.58);
	soil_tint = mix(soil_tint, vec3(0.76, 0.65, 0.48), shore * 0.60);
	soil.albedo *= soil_tint;
	soil.deviation *= detail_normal_strength;
	TerrainPBR earth = soil;
	vec3 geological_deviation = vec3(0.0);
	if (meadow_weight > 0.001) {
		TerrainPBR meadow = terrain_triplanar(meadow_albedo, meadow_normal, meadow_orm,
			world_position * meadow_texture_scale, position_dx * meadow_texture_scale, position_dy * meadow_texture_scale,
			axis_blend, signs, patch, 2.8);
		meadow.albedo *= mix(vec3(0.91, 0.95, 0.85), vec3(1.03, 1.01, 0.98), broad_variation);
		meadow.deviation *= detail_normal_strength * 0.86;
		earth = terrain_blend(earth, meadow, meadow_weight);
	}
	if (exposed > 0.001) {
		TerrainPBR rock = terrain_triplanar(rock_albedo, rock_normal, rock_orm,
			world_position * rock_texture_scale, position_dx * rock_texture_scale, position_dy * rock_texture_scale,
			axis_blend, signs, patch, 0.44);
		vec3 macro_point = world_position * geological_texture_scale + vec3(0.18, 0.77, -0.21);
		TerrainPBR geology = terrain_triplanar(rock_albedo, rock_macro_normal, rock_macro_orm,
			macro_point, position_dx * geological_texture_scale, position_dy * geological_texture_scale,
			axis_blend, signs, patch, 0.38);
		TerrainPBR stone = terrain_blend(rock, geology, mix(0.32, 0.76, distance_blend));
		stone.deviation = rock.deviation * detail_normal_strength * mix(0.65, 0.18, distance_blend)
			+ geology.deviation * geological_normal_strength * mix(0.90, 1.0, distance_blend);
		geological_deviation = geology.deviation * geological_normal_strength * exposed;
		stone.albedo *= mix(vec3(0.88, 0.89, 0.90), vec3(1.06, 1.02, 0.94), broad_variation);
		earth = terrain_blend(earth, stone, exposed * (1.0 - drainage * 0.22));
	}
	float snowline_variation = (weathering - 0.5) * 96.0 + up.z * 28.0;
	float frost = smoothstep(natural_snowline.x, max(natural_snowline.x + 1.0, natural_snowline.y), world_position.y + snowline_variation)
		* (1.0 - cliff_exposure * 0.84);
	float weather_exposure = surface_weather_exposure(ground, shelter_bounds, shelter_yaw_degrees);
	float dust = smoothstep(0.14, 0.91, weather_surface.z * weather_exposure + (coarse - 0.5) * 0.23) * 0.58;
	earth.albedo = mix(earth.albedo, vec3(0.18, 0.142, 0.097) * (0.78 + medium * 0.35), dust);
	earth.orm.g = mix(earth.orm.g, 0.94, dust);
	earth.deviation *= 1.0 - dust * 0.36;
	float snow = max(snow_deposition(ground, up.y, weather_surface.y, weather_exposure, 0.61), frost);
	float wet = weather_surface.x * weather_exposure * (1.0 - snow);
	float cavity = 1.0 - earth.orm.r;
	float puddle_shape = value_noise(ground * 0.23 + vec2(6.2, 4.9));
	float puddle = wet * wet * smoothstep(0.66, 0.88, puddle_shape + cavity * 0.14)
		* smoothstep(0.86, 0.98, up.y) * clamp(0.12 + drainage * 0.66 + trail * 0.30, 0.0, 1.0);
	earth.albedo *= 1.0 - wet * 0.42;
	earth.orm.g = mix(earth.orm.g, max(earth.orm.g * 0.55, 0.24), wet);
	earth.orm.g = mix(earth.orm.g, 0.075, puddle);
	earth.deviation *= 1.0 - puddle * 0.76;
	TerrainPBR result = earth;
	if (snow > 0.001) {
		TerrainPBR snow_detail = terrain_triplanar(snow_albedo, snow_normal, snow_orm,
			world_position * snow_texture_scale, position_dx * snow_texture_scale, position_dy * snow_texture_scale,
			axis_blend, signs, patch, 1.0);
		float snow_macro_scale = 0.095;
		TerrainPBR snow_drift = terrain_triplanar(snow_albedo, snow_normal, snow_orm,
			world_position * snow_macro_scale + vec3(0.32, 0.17, -0.19), position_dx * snow_macro_scale, position_dy * snow_macro_scale,
			axis_blend, signs, patch, 0.6);
		TerrainPBR snow_pack = terrain_blend(snow_detail, snow_drift, distance_blend * 0.68);
		snow_pack.deviation = snow_detail.deviation * detail_normal_strength * mix(0.58, 0.16, distance_blend)
			+ snow_drift.deviation * 0.32 + geological_deviation * 0.72;
		snow_pack.albedo *= mix(0.96, 1.015, weathering);
		result = terrain_blend(earth, snow_pack, snow);
	}
	vec3 deviation = result.deviation - up * dot(result.deviation, up);
	NORMAL = mat3(VIEW_MATRIX) * normalize(up + deviation);
	ALBEDO = result.albedo;
	AO = clamp(result.orm.r, 0.0, 1.0);
	ROUGHNESS = clamp(result.orm.g, 0.045, 1.0);
	// Rock, soil, vegetation, dust, and snow are dielectric substrates.
	METALLIC = 0.0;
	CLEARCOAT = wet * 0.28;
	CLEARCOAT_ROUGHNESS = mix(0.28, 0.10, puddle);
}
