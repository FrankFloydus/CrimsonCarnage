group_uniforms Source_Rain;
// Enables the DemoMap landscape wetness and pool material response.
uniform bool comparison_rain_enabled = false;
// Water accumulation threshold used before subtracting the ground variation field.
uniform float comparison_pool_coverage : hint_range(0.0, 1.0, 0.01) = 0.28;
// Contrast of the pool boundary before derivative filtering.
uniform float comparison_pool_sharpness : hint_range(10.0, 100.0, 1.0) = 40.0;
// Target roughness in deep pools and the thinnest parts of the film.
uniform float comparison_water_roughness : hint_range(0.0, 1.0, 0.01) = 0.04;
// Original 8 by 4 pool normal atlas. RG holds rain and BA holds wind gradients.
uniform sampler2D comparison_pool_normal_atlas : filter_linear_mipmap, repeat_disable;
// World size, in meters, of each tile of the pool normal animation.
uniform float comparison_pool_normal_tile : hint_range(0.5, 10.0, 0.05) = 2.5;
// Playback rate of the pool normal animation in frames per second.
uniform float comparison_pool_animation_fps : hint_range(1.0, 60.0, 1.0) = 30.0;
// Normal amplitude of the pool animation.
uniform float comparison_pool_normal_gain : hint_range(0.0, 2.0, 0.05) = 1.0;
group_uniforms;

// The comparison driver supplies normalized source wind, independent of rain and accumulated wetness.
instance uniform float comparison_pool_wind = 0.0;


float comparison_puddle_variation(vec2 ground) {
	// Original field calibrated to the source puddle channel's distribution and spatial correlation.
	vec2 phase = vec2(62.108597, 78.361931);
	return 0.334
		+ (rain_puddle_noise(ground * 0.20 + phase) - 0.5) * 0.120
		+ (rain_puddle_noise(ground * 0.60 + phase.yx + vec2(4.2, 11.3)) - 0.5) * 0.190
		+ (rain_puddle_noise(ground * 1.75 + phase + vec2(11.1, 4.7)) - 0.5) * 0.103
		+ (rain_puddle_noise(ground * 4.70 + phase.yx + vec2(1.7, 21.6)) - 0.5) * 0.051;
}


vec2 comparison_puddle_masks(vec2 ground, float facing_up, float accumulated, float rain) {
	float variation = comparison_puddle_variation(ground);
	float slope = clamp((facing_up - 0.95) / 0.05, 0.0, 1.0);
	float edge = comparison_pool_coverage * accumulated * slope - variation;
	float width = max(1.0 / comparison_pool_sharpness, fwidth(edge) * 0.85);
	float puddle = clamp((edge + width * 0.5 - 0.5 / comparison_pool_sharpness) / width, 0.0, 1.0);
	float base_wetness = mix(0.50, 0.75, clamp(rain / 0.40, 0.0, 1.0));
	float wetness = clamp(puddle + base_wetness * clamp(accumulated * mix(3.0, 0.7, variation), 0.0, 1.0), 0.0, 1.0);
	return vec2(puddle, wetness);
}


vec2 comparison_pool_normals(vec2 ground, float rain, float puddle, out float detail) {
	vec2 coordinates = ground / comparison_pool_normal_tile;
	vec2 dx = dFdx(coordinates);
	vec2 dy = dFdy(coordinates);
	float footprint = max(length(dx), length(dy)) * comparison_pool_normal_tile;
	detail = 1.0 - smoothstep(0.033, 0.075, footprint);
	if (puddle <= 0.0 || comparison_pool_normal_gain <= 0.0 || detail <= 0.0) {
		return vec2(0.0);
	}
	float frame = mod(floor(TIME * comparison_pool_animation_fps), 32.0);
	vec2 frame_coordinate = vec2(mod(frame, 8.0), floor(frame / 8.0));
	vec2 frame_grid = vec2(8.0, 4.0);
	// The eight-texel wrapped frame margins keep the normal mip inside this frame.
	const float content_fraction = 240.0 / 256.0;
	vec2 atlas_uv = (frame_coordinate + fract(coordinates) * content_fraction + 8.0 / 256.0) / frame_grid;
	vec4 normal_lanes = textureGrad(comparison_pool_normal_atlas, atlas_uv,
		dx * content_fraction / frame_grid, dy * content_fraction / frame_grid) - 0.5;
	return (normal_lanes.rg * rain + normal_lanes.ba * (0.10 * comparison_pool_wind))
		* detail * comparison_pool_normal_gain;
}


vec2 comparison_wet_tile_relief(vec2 ground, float cell_size) {
	vec2 wobble = vec2(rain_puddle_noise(ground * 12.0), rain_puddle_noise(ground * 12.0 + vec2(17.0))) - 0.5;
	vec2 offset = (fract((ground + wobble * 0.012) / cell_size + 0.5) - 0.5) * cell_size;
	vec2 distance_to_joint = abs(offset);
	vec2 bank = smoothstep(vec2(0.0), vec2(0.007), distance_to_joint)
		* (1.0 - smoothstep(vec2(0.012), vec2(0.029), distance_to_joint));
	float footprint = max(length(dFdx(ground)), length(dFdy(ground)));
	return -sign(offset) * bank * (0.31 * (1.0 - smoothstep(0.01, 0.038, footprint)));
}


void apply_comparison_rain(vec2 ground, vec3 up, mat3 view_from_world, vec4 weather,
		inout vec3 color, inout vec3 normal_view, inout float roughness, inout float specular) {
	float accumulated = clamp(weather.x, 0.0, 1.0);
	if (accumulated <= 0.0) {
		return;
	}
	vec2 masks = comparison_puddle_masks(ground, up.y, accumulated, weather.w);
	float puddle = masks.x;
	float wetness = masks.y;
	color = mix(color, vec3(0.020833, 0.018607, 0.016168), puddle * 0.35);
	roughness = mix(roughness, comparison_water_roughness, wetness);
	specular = mix(specular, 0.5, wetness);
	float ripple_detail;
	vec2 ripple = comparison_pool_normals(ground, weather.w, puddle, ripple_detail);
	vec3 water_normal = normalize(view_from_world * vec3(ripple.x, 1.0, ripple.y));
	normal_view = normalize(mix(normal_view, water_normal, puddle));
	// One-axis RMS slopes measured from the original rain and wind atlas lanes.
	float rain_slope = 0.0311 * weather.w;
	float wind_slope = 0.1514 * 0.10 * comparison_pool_wind;
	float slope_variance = min(rain_slope * rain_slope + wind_slope * wind_slope, RAIN_POOL_MAX_SLOPE_VARIANCE);
	float gain = max(comparison_pool_normal_gain, 0.0);
	roughness = rain_puddle_filtered_roughness(roughness, puddle * accumulated, ripple_detail,
		slope_variance * gain * gain);
}
