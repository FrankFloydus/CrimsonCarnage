group_uniforms Clouds_Dynamic_2D;
// Tileable overhead density. Red is cloud mass and black is clear sky.
uniform sampler2D dynamic_2d_cloud_map : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform float dynamic_2d_base_km : hint_range(0.25, 8.0, 0.05) = 1.25;
uniform float dynamic_2d_scale : hint_range(0.25, 4.0, 0.05) = 1.25;
// Starting position of the cloud pattern in UV space before wind moves it.
uniform vec2 dynamic_2d_pattern_phase = vec2(0.12, 0.756);
uniform float dynamic_2d_opacity : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float dynamic_2d_upper_separation_km : hint_range(0.1, 6.0, 0.05) = 1.6;
uniform float dynamic_2d_upper_opacity : hint_range(0.0, 1.0, 0.01) = 0.24;
group_uniforms;

const float DYNAMIC_CLOUD_TILE_KM = 32.0;

vec2 dynamic_2d_cloud_coordinates(vec2 world_xz_km, vec2 displacement, bool upper_sheet) {
	vec2 coordinates = world_xz_km * dynamic_2d_scale / DYNAMIC_CLOUD_TILE_KM;
	vec2 drift = displacement / DYNAMIC_CLOUD_TILE_KM;
	if (upper_sheet) {
		return mat2(vec2(0.82, 0.46), vec2(-0.46, 0.82)) * coordinates * 0.68
			+ drift * 2.0 + dynamic_2d_pattern_phase + vec2(0.29, -0.45);
	}
	return coordinates + drift + dynamic_2d_pattern_phase;
}

float dynamic_2d_cloud_density(vec2 coordinates) {
	// Replace the seam region with an interior sample before the texture wraps.
	vec2 within_tile = fract(coordinates);
	vec2 edge_distance = min(within_tile, 1.0 - within_tile);
	vec2 interior = smoothstep(vec2(0.025), vec2(0.17), edge_distance);
	float density = texture(dynamic_2d_cloud_map, coordinates).r;
	float shifted_x = texture(dynamic_2d_cloud_map, coordinates + vec2(0.5, 0.0)).r;
	float shifted_y = texture(dynamic_2d_cloud_map, coordinates + vec2(0.0, 0.5)).r;
	float shifted_xy = texture(dynamic_2d_cloud_map, coordinates + vec2(0.5)).r;
	return mix(
		mix(shifted_xy, shifted_y, interior.x),
		mix(shifted_x, density, interior.x),
		interior.y
	);
}

float dynamic_2d_cloud_thickness(float mass, float coverage, bool upper_sheet) {
	float threshold = mix(0.80, 0.18, pow(clamp(coverage, 0.0, 1.0), 0.81));
	float density = smoothstep(threshold - 0.048, threshold + 0.135, mass);
	if (!upper_sheet) {
		float overcast_fill = smoothstep(0.82, 1.0, coverage);
		density = mix(density, 0.85 + 0.15 * density, overcast_fill);
	}
	return density;
}
