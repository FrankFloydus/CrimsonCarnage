shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled, depth_draw_never, depth_test_disabled;

uniform sampler2D opaque_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler3D storm_cells : filter_linear, repeat_enable;
uniform vec3 storm_center;
uniform float outer_radius_m = 4000.0;
uniform float ground_y;
uniform float cloud_base_y = 600.0;
uniform float fog_amount;
uniform float fog_scale = 1.0;
uniform float visual_opacity;
uniform float extinction_per_m = 0.00060;
uniform float edge_end = 0.89;
uniform vec3 scatter_gain = vec3(0.97, 1.43, 1.59);
uniform vec3 shaft_radiance = vec3(0.025, 0.063, 0.160);
uniform vec2 wind_offset_m;
uniform float motion_seconds;
uniform vec3 flash_position;
uniform float flash_strength;
uniform float flash_radius_m = 1000.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
}

vec3 unproject(vec2 ndc, float depth, mat4 inverse_projection) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	depth = depth * 2.0 - 1.0;
#endif
	vec4 point = inverse_projection * vec4(ndc, depth, 1.0);
	return point.xyz / max(point.w, 0.000001);
}

vec2 storm_interval(vec3 eye, vec3 ray, float limit, float layer_height) {
	vec2 offset = eye.xz - storm_center.xz;
	float a = dot(ray.xz, ray.xz);
	float c = dot(offset, offset) - outer_radius_m * outer_radius_m;
	vec2 span = vec2(0.0, limit);
	if (a > 0.000001) {
		float b = dot(offset, ray.xz);
		float discriminant = b * b - a * c;
		if (discriminant <= 0.0) {
			return vec2(1.0, 0.0);
		}
		float root = sqrt(discriminant);
		span = vec2(max(0.0, (-b - root) / a), min(limit, (-b + root) / a));
	} else if (c >= 0.0) {
		return vec2(1.0, 0.0);
	}
	vec2 y_bounds = vec2(ground_y - layer_height * 0.16, cloud_base_y + layer_height * 0.045);
	if (abs(ray.y) > 0.00001) {
		vec2 y_cross = (y_bounds - eye.y) / ray.y;
		span = vec2(max(span.x, min(y_cross.x, y_cross.y)), min(span.y, max(y_cross.x, y_cross.y)));
	} else if (eye.y < y_bounds.x || eye.y > y_bounds.y) {
		return vec2(1.0, 0.0);
	}
	return span;
}

void fragment() {
	if (visual_opacity <= 0.0001) { discard; }
	vec2 ndc = SCREEN_UV * 2.0 - 1.0;
	float raw_depth = texture(opaque_depth, SCREEN_UV).r;
	vec3 near_view = unproject(ndc, 1.0, INV_PROJECTION_MATRIX);
	bool orthographic = abs(PROJECTION_MATRIX[3][3]) > 0.5;
	vec3 origin_view = orthographic ? near_view : vec3(0.0);
	vec3 ray_view = orthographic ? vec3(0.0, 0.0, -1.0) : normalize(near_view);
	vec3 eye = (INV_VIEW_MATRIX * vec4(origin_view, 1.0)).xyz;
	vec3 ray = normalize((INV_VIEW_MATRIX * vec4(ray_view, 0.0)).xyz);
	// Sky has no opaque depth. This distance is independent of Camera3D.far.
	float limit = raw_depth <= 0.000001 ? 100000.0
		: length(unproject(ndc, raw_depth, INV_PROJECTION_MATRIX) - origin_view);
	float height = max(cloud_base_y - ground_y, 10.0);
	vec2 span = storm_interval(eye, ray, limit, height);
	float tau = 0.0;
	float integrated_flash = 0.0;
	if (span.y > span.x && fog_amount > 0.0) {
		const int STEPS = 8;
		float stride = (span.y - span.x) / float(STEPS);
		for (int index = 0; index < STEPS; ++index) {
			vec3 point = eye + ray * (span.x + (float(index) + 0.5) * stride);
			float relative_y = (point.y - ground_y) / height;
			float vertical = smoothstep(-0.16, 0.055, relative_y) * (1.0 - smoothstep(0.78, 1.045, relative_y));
			vec2 relative = (point.xz - storm_center.xz) / outer_radius_m;
			float horizontal = 1.0 - smoothstep(0.52, edge_end, length(relative));
			vec3 cell = (point - storm_center - vec3(wind_offset_m.x, 0.0, wind_offset_m.y)) * (0.00104 / max(fog_scale, 0.1));
			float broad = texture(storm_cells, cell * vec3(0.66, 0.31, 0.66)).r;
			vec3 streak_uv = cell * vec3(2.2, 0.32, 2.2) + vec3(0.0, motion_seconds * 0.04, 0.0);
			float streaks = texture(storm_cells, streak_uv).r;
			float density = horizontal * vertical * mix(0.40, 1.05, broad) * mix(0.75, 1.15, streaks);
			float step_tau = density * stride * extinction_per_m * fog_amount * visual_opacity;
			tau += step_tau;
			if (flash_strength > 0.0001) {
				vec3 from_flash = (point - flash_position) / max(flash_radius_m, 1.0);
				float illumination = exp(-1.45 * dot(from_flash.xz, from_flash.xz) - 0.75 * from_flash.y * from_flash.y);
				integrated_flash += step_tau * illumination;
			}
		}
	}
	float fog_alpha = 1.0 - exp(-tau);
	vec3 fog_color = shaft_radiance * scatter_gain + vec3(0.41, 0.56, 0.84) * (0.65 * flash_strength * integrated_flash / max(tau, 0.001));
	vec3 to_flash = flash_position - eye;
	float flash_distance = dot(to_flash, ray);
	float flare_alpha = 0.0;
	if (flash_strength > 0.0001 && flash_distance > 0.0 && flash_distance < limit) {
		vec3 offset = (to_flash - ray * flash_distance) / max(flash_radius_m, 1.0);
		flare_alpha = 0.21 * flash_strength * exp(-4.4 * dot(offset, offset));
	}
	float alpha = fog_alpha + flare_alpha * (1.0 - fog_alpha);
	if (alpha < 0.001) { discard; }
	ALBEDO = (fog_color * fog_alpha + vec3(0.47, 0.62, 0.88) * flare_alpha * (1.0 - fog_alpha)) / alpha;
	ALPHA = alpha;
}
