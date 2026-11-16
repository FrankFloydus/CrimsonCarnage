group_uniforms Clear_Wisps;
// Linear opacity mask sampled across the sky dome.
uniform sampler2D clear_wisp_texture : hint_default_black, filter_linear_mipmap, repeat_enable;
// Peak opacity of the high cirrus layer in clear weather.
uniform float clear_wisp_amount : hint_range(0.0, 0.5, 0.01) = 0.0;
group_uniforms;

vec4 clear_wisps(vec3 direction) {
	if (direction.y <= 0.0 || clear_wisp_amount <= 0.0) {
		return vec4(0.0);
	}
	vec2 dome = direction.xz / (1.0 + direction.y);
	vec2 drift = cloud_offset / 128.0;
	// Rotate the authored fibers into the prevailing high-altitude flow.
	const mat2 orientation = mat2(vec2(0.974370, 0.224951), vec2(-0.224951, 0.974370));
	vec2 coordinates = (orientation * dome) * (0.54 * high_cloud_scale / 3.0) + vec2(0.75, 0.60);
	float morph = 0.47 + 0.22 * sin(TAU * (drift.x + drift.y));
	float a = texture(clear_wisp_texture, coordinates + drift).r;
	float b = texture(clear_wisp_texture, vec2(1.0) - coordinates + drift + vec2(0.13, 0.23)).r;
	float mask = clamp((mix(a, b, morph) - 0.005) * 2.5, 0.0, 1.0);
	float opacity = mask * smoothstep(0.045, 0.25, direction.y) * clear_wisp_amount * (1.0 - smoothstep(0.0, 0.18, cloud_coverage));
	float daylight = smoothstep(-0.025, 0.24, sun_direction.y);
	float twilight = smoothstep(-0.18, -0.035, sun_direction.y);
	float sunward = pow(max(dot(direction, sun_direction), 0.0), 15.0);
	float moonward = pow(max(dot(direction, moon_direction), 0.0), 14.0) * moon_illumination();
	vec3 night = vec3(0.367187, 0.428386, 0.489583) * (0.016 + 0.033 * moonward);
	vec3 dusk = vec3(1.0, 0.587119, 0.395833) * mix(0.12, 0.52, sunward);
	vec3 noon = vec3(0.476966, 0.473985, 0.526042) * (1.0 + 0.24 * sunward);
	return vec4(mix(mix(night, dusk, twilight), noon, daylight), opacity);
}


