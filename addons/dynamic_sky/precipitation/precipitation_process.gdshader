shader_type particles;
render_mode disable_force;

uniform vec3 box_half_size = vec3(10.0, 3.5, 10.0);
uniform vec2 fall_speed_range = vec2(5.5, 9.0);
uniform vec2 particle_scale_range = vec2(0.55, 1.45);
uniform float particle_size_bias : hint_range(0.5, 4.0) = 1.0;
uniform vec2 wind_coupling_range = vec2(1.0);
uniform vec2 wind_strength_range = vec2(7.0, 14.0);
uniform float large_particle_drag : hint_range(0.0, 1.0) = 1.0;
uniform float flutter_speed : hint_range(0.0, 4.0) = 0.0;
uniform float gust_influence : hint_range(0.0, 1.0) = 0.0;
uniform float upwind_spawn_seconds : hint_range(0.0, 4.0) = 0.0;
uniform float billow_fraction : hint_range(0.0, 1.0) = 0.0;
uniform vec2 billow_scale_range = vec2(30.0, 60.0);
uniform float splash_probability : hint_range(0.0, 1.0) = 0.0;
uniform bool snow_contact_enabled = false;
uniform float snow_contact_probability : hint_range(0.0, 1.0) = 0.0;
uniform float contact_normal_offset : hint_range(-0.03, 0.03) = -0.007;
uniform vec2 wind;

float random_unit(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return float((word >> 22u) ^ word) / 4294967295.0;
}

vec2 wind_drift(float fall_speed) {
	float storm_weight = smoothstep(wind_strength_range.x, wind_strength_range.y, length(wind));
	float large_drop_weight = smoothstep(fall_speed_range.x, fall_speed_range.y, fall_speed);
	float coupling = mix(wind_coupling_range.x, wind_coupling_range.y, storm_weight);
	return wind * coupling * mix(1.0, large_particle_drag, large_drop_weight);
}

void start() {
	uint seed = RANDOM_SEED ^ NUMBER;
	if (random_unit(seed) > AMOUNT_RATIO) {
		ACTIVE = false;
	}
	vec3 random_position;
	random_position.x = random_unit(seed);
	random_position.y = random_unit(seed);
	random_position.z = random_unit(seed);
	vec3 offset = (random_position * 2.0 - 1.0) * box_half_size;
	TRANSFORM[3] = EMISSION_TRANSFORM * vec4(offset, 1.0);
	bool billow = random_unit(seed) < billow_fraction;
	vec2 scale_range = billow ? billow_scale_range : particle_scale_range;
	float particle_weight = random_unit(seed);
	float size = mix(scale_range.x, scale_range.y, pow(particle_weight, particle_size_bias));
	TRANSFORM[0] = vec4(size, 0.0, 0.0, 0.0);
	TRANSFORM[1] = vec4(0.0, size, 0.0, 0.0);
	TRANSFORM[2] = vec4(0.0, 0.0, size, 0.0);
	// Pack horizontal drift, fall speed, and age for the draw shader.
	CUSTOM.y = mix(fall_speed_range.x, fall_speed_range.y, particle_weight);
	vec2 drift = wind_drift(CUSTOM.y);
	TRANSFORM[3].xz -= drift * upwind_spawn_seconds;
	CUSTOM.x = drift.x;
	CUSTOM.z = 0.0;
	CUSTOM.w = drift.y;
	VELOCITY = vec3(drift.x, -CUSTOM.y, drift.y);
}

void process() {
	CUSTOM.z += DELTA / LIFETIME;
	float phase = float(INDEX) * 2.4 + CUSTOM.z * 8.0;
	vec2 drift = wind_drift(CUSTOM.y) + flutter_speed * vec2(sin(phase), cos(phase * 1.3));
	if (gust_influence > 0.0) {
		vec2 position = TRANSFORM[3].xz;
		float gust = sin(dot(position, vec2(0.16, 0.11)) - TIME * 0.52);
		float crosswind = sin(dot(position, vec2(-0.14, 0.19)) - TIME * 0.68);
		drift += gust_influence * (drift * gust + vec2(-drift.y, drift.x) * crosswind * 0.35);
	}
	CUSTOM.x = drift.x;
	CUSTOM.w = drift.y;
	VELOCITY = vec3(drift.x, -CUSTOM.y, drift.y);
	if (COLLIDED) {
		// Reject deep overlaps such as drops that began below a roof or ground surface.
		uint seed = (RANDOM_SEED ^ NUMBER) + 49u;
		float penetration_limit = length(VELOCITY) * DELTA * 1.4 + 0.025;
		// The heightfield reports a downward normal and signed depth. Orient impacts up.
		float orientation = COLLISION_NORMAL.y < 0.0 ? -1.0 : 1.0;
		vec3 normal = COLLISION_NORMAL * orientation;
		float penetration = COLLISION_DEPTH * orientation;
		float contact_probability = splash_probability + (snow_contact_enabled ? snow_contact_probability : 0.0);
		if (normal.y > 0.35 && penetration >= -0.03 && penetration < penetration_limit && random_unit(seed) < contact_probability) {
			vec3 tangent = normalize(cross(normal, vec3(0.0, 0.0, 1.0)));
			vec3 bitangent = cross(tangent, normal);
			vec3 position = TRANSFORM[3].xyz + normal * (penetration + contact_normal_offset);
			mat4 impact = mat4(vec4(tangent, 0.0), vec4(normal, 0.0), vec4(bitangent, 0.0), vec4(position, 1.0));
			vec4 contact = vec4(random_unit(seed), 0.0, 0.0, 0.0);
			uint flags = FLAG_EMIT_POSITION | FLAG_EMIT_ROT_SCALE | FLAG_EMIT_CUSTOM;
			emit_subparticle(impact, vec3(0.0), vec4(1.0), contact, flags);
		}
		ACTIVE = false;
	}
}
