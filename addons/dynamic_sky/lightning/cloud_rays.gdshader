shader_type spatial;
render_mode unshaded, blend_add, cull_front, depth_draw_never, fog_disabled, shadows_disabled;

uniform sampler2D scene_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D optical_noise : filter_linear_mipmap, repeat_enable;
uniform vec3 effect_tint = vec3(0.311279, 0.439230, 0.703125);
uniform vec3 card_center = vec3(0.0);
uniform vec2 wind_mps = vec2(0.0);
uniform float particle_rgb = 0.0;
uniform float relative_age = 0.0;
uniform float integration_half_height_m = 145.0;
uniform float cloud_top_m = 1000000.0;
uniform vec2 card_half_extent_m = vec2(7500.0);

varying float vertex_gain;
varying vec2 noise_uv;
varying vec3 world_position;

float scene_depth_m(vec2 uv, mat4 inv_projection) {
	float depth = texture(scene_depth, uv).r;
	if (depth < 0.000001) {
		return 1e6;
	}
	vec4 point = inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return -point.z / point.w;
}

float cloud_alpha_at(vec2 uv) {
	// The original 256-pixel tile uses mip 2 for the source's 64-pixel field scale.
	float value = textureLod(optical_noise, uv / 1.5 + vec2(0.37, 0.68), 2.0).r;
	return clamp(0.517 + (value - 0.501) * 0.46, 0.0, 1.0);
}

float cloud_turbulence(float value) {
	return clamp(0.395 + (value - 0.5) * 0.50, 0.0, 1.0);
}

void vertex() {
	vec3 world_point = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	noise_uv = world_point.xz / 8483.31 - wind_mps * (relative_age / 500.0);
	float cloud_alpha = cloud_alpha_at(noise_uv);
	float radial = clamp(1.0 - length(UV * 2.0 - 1.0), 0.0, 1.0);
	vertex_gain = pow(radial, 2.2) * 4.0 * pow(max(cloud_alpha, 0.0), mix(5.0, 1.0, radial));
	vec3 look = normalize(card_center - CAMERA_POSITION_WORLD);
	VERTEX.y += 154.0 * (cloud_alpha - 0.2) * clamp(10.0 * abs(look.y), 0.0, 1.0);
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float optical_field(vec2 world_xz) {
	vec2 uv = world_xz / 8483.31 - wind_mps * (relative_age / 500.0);
	float cloud_alpha = cloud_alpha_at(uv);
	float radial = clamp(1.0 - length((world_xz - card_center.xz) / max(card_half_extent_m, vec2(1.0))), 0.0, 1.0);
	float detail = cloud_turbulence(textureLod(optical_noise, uv + vec2(0.61, 0.11), 1.0).g);
	return pow(radial, 2.2) * 4.0 * pow(max(cloud_alpha, 0.0), mix(5.0, 1.0, radial)) * mix(detail, 1.0, 0.4);
}

void fragment() {
	float camera_mask = clamp((min(card_center.y, cloud_top_m) - CAMERA_POSITION_WORLD.y) / 200.0, 0.0, 1.0);
	if (camera_mask <= 0.0) {
		discard;
	}
	float depth_fade = clamp((scene_depth_m(SCREEN_UV, INV_PROJECTION_MATRIX) + VERTEX.z) / 700.0, 0.0, 1.0);
	if (depth_fade <= 0.0) {
		discard;
	}
	float detail = cloud_turbulence(texture(optical_noise, noise_uv + vec2(0.61, 0.11)).g);
	vec2 coarse = world_position.xz / 3400.0 + vec2(0.49, 0.08);
	float break_up = textureLod(optical_noise, coarse, 2.0).g;
	float wisps = textureLod(optical_noise, coarse * vec2(2.2, 1.4) + vec2(0.11, 0.42), 2.0).r;
	// Scale the footprint with strike distance so distant samples beneath the card fade smoothly.
	float strike_distance = max(length(card_center - CAMERA_POSITION_WORLD), 1.0);
	float depth_fraction = -VERTEX.z / strike_distance;
	float far_t = smoothstep(0.76, 1.34, depth_fraction);
	float distant_wisps = smoothstep(0.16, 0.82, mix(break_up, wisps, 0.42));
	float fade = (1.0 - far_t) * mix(1.0, distant_wisps, far_t * 0.85);
	vec3 camera_ray = normalize(world_position - CAMERA_POSITION_WORLD);
	float grazing = 1.0 - smoothstep(0.13, 0.39, abs(camera_ray.y));
	vec2 vertical_step = camera_ray.xz * (integration_half_height_m / max(abs(camera_ray.y), 0.10));
	float radiance = vertex_gain * mix(detail, 1.0, 0.4);
	if (grazing > 0.0) {
		// Integrate a short height range at grazing angles instead of drawing extra transparent cards.
		float lower = optical_field(world_position.xz - vertical_step);
		float upper = optical_field(world_position.xz + vertical_step);
		radiance = mix(radiance, (lower + upper) * 0.5, grazing * 0.72);
	}
	// Favor the nearer cloud layer and soften the core while retaining the dim fringe.
	float near_weight = 1.0 - smoothstep(0.45, 0.78, depth_fraction);
	radiance *= mix(1.0, 1.60, near_weight);
	float excess = max(radiance - 0.38, 0.0);
	radiance = min(radiance, 0.38) + excess / (1.0 + 1.4 * excess);
	// Unshaded ALBEDO bypasses the lit emission exposure normalization.
	ALBEDO = effect_tint / max(EXPOSURE, 0.0001) * particle_rgb * 2.5 * radiance;
	ALPHA = depth_fade * camera_mask * fade;
}
