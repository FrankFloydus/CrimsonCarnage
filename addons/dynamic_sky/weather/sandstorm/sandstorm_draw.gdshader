shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler3D density_noise : repeat_enable, filter_linear_mipmap;
uniform int particle_kind : hint_enum("Suspended grains", "Saltation", "Gust billows") = 0;
uniform vec4 grain_tint : source_color = vec4(0.68, 0.57, 0.43, 0.68);
uniform vec4 scatter_tint : source_color = vec4(0.76, 0.63, 0.48, 0.37);
uniform vec2 near_fade = vec2(0.7, 1.6);
uniform vec2 far_fade = vec2(16.0, 32.0);
uniform float surface_fade_distance : hint_range(0.01, 5.0) = 0.28;
uniform float exposure : hint_range(0.0, 1.0) = 1.0;
uniform float weather_weight : hint_range(0.0, 1.0) = 0.0;
uniform vec2 wind;

varying flat vec3 particle_sample;
varying flat float opacity;

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	float size = length(MODEL_MATRIX[0].xyz);
	float age = INSTANCE_CUSTOM.y;
	float variant = INSTANCE_CUSTOM.z;
	float heading = INSTANCE_CUSTOM.x;
	particle_sample = vec3(heading, age, variant);
	vec3 view_velocity = mat3(VIEW_MATRIX) * vec3(wind.x, -0.06, wind.y);
	vec2 travel = view_velocity.xy - center.xy * view_velocity.z / min(-0.4, center.z);
	float projected_speed = length(travel);
	vec2 offset = VERTEX.xy * size;
	float fade_in = 0.13;
	float fade_out = 0.75;
	if (particle_kind == 2) {
		// Gusts stretch along the wind and climb as they dilute.
		offset *= vec2(1.8 + 1.25 * age, 0.42 + 0.55 * age);
		travel.y = clamp(travel.y, -abs(travel.x) * 0.29, abs(travel.x) * 0.29);
		fade_in = 0.35;
		fade_out = 0.54;
	} else {
		float stretch = 1.0 + min(projected_speed * mix(0.11, 0.29, variant), 5.2);
		offset.x *= stretch;
	}
	vec2 direction = length(travel) > 0.01 ? normalize(travel) : vec2(1.0, 0.0);
	offset = direction * offset.x + vec2(-direction.y, direction.x) * offset.y;
	VERTEX = center + vec3(offset, 0.0);
	opacity = smoothstep(0.0, fade_in, age) * (1.0 - smoothstep(fade_out, 1.0, age));
	opacity *= COLOR.a;
	opacity *= smoothstep(near_fade.x, near_fade.y, -center.z);
	opacity *= 1.0 - smoothstep(far_fade.x, far_fade.y, length(center));
}

vec2 dust_optics(vec2 point) {
	float phase = particle_sample.x;
	float age = particle_sample.y;
	vec3 curl_coordinate = vec3(point * vec2(0.33, 0.22), phase * 7.37 + age * 0.24);
	vec3 curl = texture(density_noise, curl_coordinate).rgb - 0.5;
	vec3 density_coordinate = vec3(point * vec2(0.65, 0.44), phase * 13.15 + age * 0.32);
	density_coordinate.xy += curl.rg * vec2(0.52, 0.68);
	density_coordinate.x -= age * 0.26;
	float body = texture(density_noise, density_coordinate).r;
	float wisps = texture(density_noise, density_coordinate * vec3(2.9, 2.0, 1.73)).g;
	// Erode the bounding envelope using correlated turbulent structure.
	vec2 lobes = point + curl.rg * vec2(0.21, 0.30);
	float envelope = 1.0 - smoothstep(0.29, 1.0, length(lobes));
	float density = smoothstep(0.22, 0.75, body * 0.75 + wisps * 0.25);
	float lit = smoothstep(0.12, 0.72, density * 0.41 + curl.b * 0.31 + point.y * 0.23 + 0.18);
	float alpha = (1.0 - exp(-density * envelope * 1.9)) * envelope;
	return vec2(alpha, lit);
}

float soft_intersection(vec2 screen_uv, float view_z, mat4 inverse_projection) {
	float depth = texture(scene_depth, screen_uv).r;
	if (depth < 0.000001) {
		return 1.0;
	}
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		vec3 ndc = vec3(screen_uv, depth) * 2.0 - 1.0;
	#else
		vec3 ndc = vec3(screen_uv * 2.0 - 1.0, depth);
	#endif
	vec4 scene_view = inverse_projection * vec4(ndc, 1.0);
	return smoothstep(0.0, surface_fade_distance, view_z - scene_view.z / scene_view.w);
}

void fragment() {
	vec2 point = UV * 2.0 - 1.0;
	float alpha;
	vec3 color;
	if (particle_kind == 2) {
		vec2 optics = dust_optics(point);
		color = scatter_tint.rgb * mix(0.69, 1.11, optics.y);
		alpha = scatter_tint.a * optics.x;
	} else {
		float phase = particle_sample.x;
		float variant = particle_sample.z;
		float tip = mix(-0.17, 0.21, phase);
		vec2 grain = vec2(point.x - tip, point.y + point.x * mix(-0.13, 0.13, phase));
		float core_radius = length(grain * vec2(mix(1.4, 1.8, phase), 1.52));
		float filter_width = clamp(fwidth(core_radius), 0.04, 0.39);
		float core = 1.0 - smoothstep(0.28, 0.61 + filter_width, core_radius);
		float tail = exp(-abs(grain.y) * 8.0) * (1.0 - smoothstep(0.14, 0.96, abs(point.x)));
		alpha = grain_tint.a * max(core, tail * mix(0.24, 0.54, variant));
		color = grain_tint.rgb * mix(0.32, 1.05, fract(phase * 5.61));
	}
	ALBEDO = color * mix(vec3(0.15, 0.21, 0.34), vec3(1.0), exposure);
	ALPHA = alpha * opacity * weather_weight
		* soft_intersection(SCREEN_UV, VERTEX.z, INV_PROJECTION_MATRIX);
}
