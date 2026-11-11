shader_type particles;
render_mode disable_force;

uniform vec3 spawn_half_size = vec3(8.0, 2.5, 8.0);
uniform vec2 size_range = vec2(0.56, 1.28);
uniform vec2 fall_speed_range = vec2(0.5, 1.1);
uniform float wind_coupling = 0.63;
uniform float flutter_frequency = 3.1;
uniform float air_drag = 2.4;
uniform vec2 wind = vec2(0.0);
uniform float gustiness = 0.0;

const float CONTACT_FADE_SECONDS = 0.34;

float random_unit(inout uint seed) {
	seed = seed * 747796405u + 2891336453u;
	uint word = ((seed >> ((seed >> 28u) + 4u)) ^ seed) * 277803737u;
	return float((word >> 22u) ^ word) / 4294967295.0;
}

void place_axes(inout mat4 transform, float size, vec3 x, vec3 y, vec3 z) {
	transform[0] = vec4(x * size, 0.0);
	transform[1] = vec4(y * size, 0.0);
	transform[2] = vec4(z * size, 0.0);
}

void turn_in_flight(inout mat4 transform, vec3 velocity, vec4 state, float age) {
	vec2 drift = velocity.xz;
	vec3 axis = normalize(vec3(drift.x + 0.001, 0.0, drift.y));
	vec3 side = cross(axis, vec3(0.0, 1.0, 0.0));
	float phase = state.x * TAU;
	float yaw = sin(age * flutter_frequency + phase) * (0.72 + gustiness * 0.30);
	vec3 heading = axis * cos(yaw) + side * sin(yaw);
	vec3 hinge = cross(heading, vec3(0.0, 1.0, 0.0));
	float pitch = sin(age * flutter_frequency * 1.31 + phase) * 0.78;
	vec3 x = heading * cos(pitch) + vec3(0.0, sin(pitch), 0.0);
	vec3 up = cross(hinge, x);
	float handedness = state.x < 0.5 ? -1.0 : 1.0;
	float roll = phase + handedness * age * (flutter_frequency + 0.8) + sin(age * 4.8 + phase) * 0.45;
	vec3 y = up * cos(roll) + hinge * sin(roll);
	place_axes(transform, state.z, x, y, cross(x, y));
}

void start() {
	uint seed = RANDOM_SEED ^ NUMBER;
	if (random_unit(seed) > AMOUNT_RATIO) {
		ACTIVE = false;
	} else {
		vec3 sample_position;
		sample_position.x = random_unit(seed);
		sample_position.y = random_unit(seed);
		sample_position.z = random_unit(seed);
		vec3 offset = (sample_position * 2.0 - 1.0) * spawn_half_size;
		vec2 drift = wind * wind_coupling;
		offset.xz -= drift * 0.65;
		TRANSFORM[3] = EMISSION_TRANSFORM * vec4(offset, 1.0);
		float phase = random_unit(seed);
		float size = mix(size_range.x, size_range.y, random_unit(seed));
		CUSTOM = vec4(phase, 0.0, size, 0.0);
		VELOCITY = vec3(drift.x, -mix(fall_speed_range.x, fall_speed_range.y, phase), drift.y);
		turn_in_flight(TRANSFORM, VELOCITY, CUSTOM, 0.0);
	}
}

void process() {
	CUSTOM.y += DELTA / LIFETIME;
	if (CUSTOM.w > 0.0) {
		CUSTOM.w += DELTA;
		ACTIVE = CUSTOM.w < CONTACT_FADE_SECONDS;
	} else if (COLLIDED) {
		// Discard particles initialized below a roof or surface. Shallow ground impacts settle briefly.
		float orientation = COLLISION_NORMAL.y < 0.0 ? -1.0 : 1.0;
		vec3 normal = COLLISION_NORMAL * orientation;
		float penetration = COLLISION_DEPTH * orientation;
		if (normal.y < 0.55 || penetration > length(VELOCITY) * DELTA + 0.035) {
			ACTIVE = false;
		} else {
			vec3 direction = normalize(vec3(wind.x + 0.001, 0.0, wind.y));
			vec3 side = normalize(cross(direction, normal));
			TRANSFORM[3].xyz += normal * (max(penetration, 0.0) + 0.010);
			place_axes(TRANSFORM, CUSTOM.z, cross(normal, side), normal, side);
			VELOCITY = vec3(0.0);
			CUSTOM.w = 0.001;
		}
	} else {
		float age = CUSTOM.y * LIFETIME;
		vec3 position = TRANSFORM[3].xyz;
		float phase = age * flutter_frequency + CUSTOM.x * TAU;
		float gust = sin(dot(position.xz, vec2(0.21, -0.13)) - TIME * 1.18);
		vec2 drift = wind * wind_coupling * (1.0 + gust * gustiness * 0.32);
		vec2 crosswind = normalize(vec2(-wind.y + 0.001, wind.x));
		drift += crosswind * sin(phase) * (0.42 + gustiness * 0.94);
		float settle = mix(fall_speed_range.x, fall_speed_range.y, CUSTOM.x);
		float lift = sin(phase * 1.43) * (0.24 + gustiness * 0.58) + gust * gustiness * 0.67;
		vec3 target_velocity = vec3(drift.x, lift - settle, drift.y);
		VELOCITY = mix(VELOCITY, target_velocity, 1.0 - exp(-air_drag * DELTA));
		turn_in_flight(TRANSFORM, VELOCITY, CUSTOM, age);
	}
}
