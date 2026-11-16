shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://addons/dynamic_sky/surfaces/weather_layer.gdshaderinc"

group_uniforms Base;
// Surface color beneath both grids.
uniform vec4 base_color : source_color = vec4(0.32, 0.39, 0.44, 1.0);

group_uniforms MinorGrid;
// Grid spacing and line thickness are measured in world meters.
uniform float minor_spacing : hint_range(0.01, 10.0, 0.01) = 1.0;
uniform float minor_thickness : hint_range(0.0, 0.25, 0.001) = 0.012;
uniform vec4 minor_color : source_color = vec4(0.48, 0.56, 0.61, 1.0);

group_uniforms MajorGrid;
uniform float major_spacing : hint_range(0.01, 100.0, 0.01) = 4.0;
uniform float major_thickness : hint_range(0.0, 0.5, 0.001) = 0.035;
uniform vec4 major_color : source_color = vec4(0.72, 0.80, 0.84, 1.0);

group_uniforms Roughness;
// The optional map's red channel multiplies the scalar roughness.
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform bool use_roughness_map = false;
uniform sampler2D roughness_map : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
// Number of roughness texture repeats per world meter.
uniform float roughness_map_scale : hint_range(0.01, 10.0, 0.01) = 1.0;

group_uniforms Normal;
uniform bool use_normal_map = false;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// Normal strength and texture repeats per world meter.
uniform float normal_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float normal_map_scale : hint_range(0.01, 10.0, 0.01) = 1.0;

group_uniforms Metallic;
// Metallic value for a material without a map. An enabled map supplies the value from red.
uniform float metallic : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform bool use_metallic_map = false;
uniform sampler2D metallic_map : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float metallic_map_scale : hint_range(0.01, 10.0, 0.01) = 1.0;
group_uniforms;

varying vec3 world_position;
varying vec3 world_normal;


void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}


float grid_mask(vec2 position, float spacing, float thickness) {
	vec2 pixel_width = max(fwidth(position), vec2(0.0001));
	vec2 cell = fract(position / max(spacing, 0.0001));
	vec2 distance_to_line = min(cell, 1.0 - cell) * spacing;
	float half_thickness = min(thickness * 0.5, spacing * 0.5);
	vec2 lines = 1.0 - smoothstep(
		vec2(half_thickness) - pixel_width * 0.5,
		vec2(half_thickness) + pixel_width * 0.5,
		distance_to_line
	);
	// Fade each axis before its cells become too small to resolve on screen.
	lines *= 1.0 - smoothstep(vec2(spacing * 0.2), vec2(spacing * 0.6), pixel_width);
	return max(lines.x, lines.y) * step(0.00001, thickness);
}


float triplanar_grid(float spacing, float thickness, vec3 weights) {
	return grid_mask(world_position.yz, spacing, thickness) * weights.x
		+ grid_mask(world_position.xz, spacing, thickness) * weights.y
		+ grid_mask(world_position.xy, spacing, thickness) * weights.z;
}


float triplanar_scalar(sampler2D value_map, vec3 point, vec3 weights) {
	return texture(value_map, point.yz).r * weights.x
		+ texture(value_map, point.xz).r * weights.y
		+ texture(value_map, point.xy).r * weights.z;
}


vec2 normal_slope(vec2 texel) {
	vec2 normal_xy = texel * 2.0 - 1.0;
	float normal_z = sqrt(max(1.0 - dot(normal_xy, normal_xy), 0.001));
	// The green component points towards the top of the image, opposite increasing UV.y.
	return vec2(normal_xy.x, -normal_xy.y) / max(normal_z, 0.35);
}


vec3 triplanar_normal(vec3 point, vec3 geometric_normal, vec3 weights) {
	vec2 x = normal_slope(texture(normal_map, point.yz).rg);
	vec2 y = normal_slope(texture(normal_map, point.xz).rg);
	vec2 z = normal_slope(texture(normal_map, point.xy).rg);
	vec3 slope = vec3(0.0, x) * weights.x
		+ vec3(y.x, 0.0, y.y) * weights.y
		+ vec3(z, 0.0) * weights.z;
	slope -= geometric_normal * dot(geometric_normal, slope);
	return normalize(geometric_normal + slope * normal_strength);
}


void fragment() {
	vec3 geometric_normal = normalize(world_normal);
	vec3 weights = pow(abs(geometric_normal), vec3(8.0));
	weights /= max(weights.x + weights.y + weights.z, 0.0001);
	float minor_mask = triplanar_grid(minor_spacing, minor_thickness, weights);
	float major_mask = triplanar_grid(major_spacing, major_thickness, weights);
	vec3 color = mix(base_color.rgb, minor_color.rgb, minor_mask * minor_color.a);
	ALBEDO = mix(color, major_color.rgb, major_mask * major_color.a);
	ROUGHNESS = roughness;
	if (use_roughness_map) {
		ROUGHNESS *= triplanar_scalar(roughness_map, world_position * roughness_map_scale, weights);
	}
	METALLIC = metallic;
	if (use_metallic_map) {
		METALLIC = triplanar_scalar(metallic_map, world_position * metallic_map_scale, weights);
	}
	if (use_normal_map) {
		vec3 mapped_normal = triplanar_normal(world_position * normal_map_scale, geometric_normal, weights);
		NORMAL = normalize(mat3(VIEW_MATRIX) * mapped_normal);
	}
	APPLY_DYNAMIC_SKY_WEATHER(world_position, geometric_normal);
}
