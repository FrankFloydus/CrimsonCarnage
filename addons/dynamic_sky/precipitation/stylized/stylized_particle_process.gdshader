shader_type particles;

uniform bool snowfall = false;
uniform vec2 wind = vec2(0.0);

float random_float(uint value) {
	value = (value ^ 61u) ^ (value >> 16u);
	value *= 9u;
	value ^= value >> 4u;
	value *= 668265261u;
	return float((value ^ (value >> 15u)) & 16777215u) / 16777216.0;
}

void start() {
	uint seed = RANDOM_SEED + 7u * NUMBER;
	vec3 sample_point = vec3(random_float(seed), random_float(seed + 1u), random_float(seed + 2u));
	float radius = snowfall ? 21.0 : 17.0;
	vec3 point = EMISSION_TRANSFORM[3].xyz;
	point.xz += (sample_point.xz * 2.0 - 1.0) * radius;
	point.y += mix(3.0, snowfall ? 11.0 : 9.0, sample_point.y);
	TRANSFORM[3].xyz = point;
	CUSTOM = vec4(0.0, random_float(seed + 3u), random_float(seed + 4u), random_float(seed + 5u));
	VELOCITY = vec3(0.0, snowfall ? -1.9 : -11.0, 0.0);
}

void process() {
	CUSTOM.x += DELTA / max(LIFETIME, 0.001);
	if (snowfall) {
		float phase = (CUSTOM.y + CUSTOM.x * mix(0.5, 1.1, CUSTOM.z)) * 6.2831853;
		vec3 point = TRANSFORM[3].xyz;
		vec2 eddy = vec2(sin(point.y * 0.34 + point.z * 0.17), cos(point.x * 0.21 - point.y * 0.24)) * 0.52;
		vec2 flutter = vec2(cos(phase), sin(phase * 1.18)) * mix(0.18, 0.68, CUSTOM.w);
		vec2 travel = wind * (0.21 + 0.13 * CUSTOM.z) + eddy + flutter;
		float fall_speed = mix(1.18, 2.45, CUSTOM.z) + sin(phase * 1.3) * 0.21;
		VELOCITY = vec3(travel.x, -fall_speed, travel.y);
		COLOR = vec4(clamp(vec2(0.5) + travel / 24.0, vec2(0.0), vec2(1.0)), fall_speed / 4.0, 1.0);
	} else {
		VELOCITY = vec3(0.0, -mix(10.0, 15.0, CUSTOM.z), 0.0);
	}
}
