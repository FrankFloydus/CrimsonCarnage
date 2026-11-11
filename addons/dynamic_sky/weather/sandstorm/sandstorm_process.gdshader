shader_type particles;
render_mode disable_force;

uniform int particle_kind : hint_enum("Suspended grains", "Saltation", "Gust billows") = 0;
uniform vec3 spawn_half_extents = vec3(16.0, 4.5, 16.0);
uniform vec2 size_range = vec2(0.016, 0.054);
uniform vec2 drift_range = vec2(0.65, 1.04);
uniform vec2 wind;
uniform bool surface_collision = false;

float random_unit(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return float((word >> 22u) ^ word) / 4294967295.0;
}

vec2 gust_velocity(vec2 position) {
	float speed = length(wind);
	vec2 along = speed > 0.05 ? wind / speed : vec2(1.0, 0.0);
	vec2 across = vec2(-along.y, along.x);
	vec2 advected = position - wind * (TIME * 0.67);
	float band = sin(dot(advected, along) * 0.29 + sin(dot(advected, across) * 0.19) * 1.4);
	float eddy = sin(dot(advected, across) * 0.36 + dot(advected, along) * 0.12);
	return wind * (1.0 + 0.34 * band) + across * (0.20 * speed * eddy);
}

void start() {
	uint seed = RANDOM_SEED ^ NUMBER;
	if (random_unit(seed) > AMOUNT_RATIO) {
		ACTIVE = false;
	}
	float phase = random_unit(seed);
	float variant = random_unit(seed);
	vec3 offset;
	offset.x = (random_unit(seed) * 2.0 - 1.0) * spawn_half_extents.x;
	offset.y = (random_unit(seed) * 2.0 - 1.0) * spawn_half_extents.y;
	offset.z = (random_unit(seed) * 2.0 - 1.0) * spawn_half_extents.z;
	float size = mix(size_range.x, size_range.y, pow(variant, 1.7));
	float coupling = mix(drift_range.x, drift_range.y, variant);
	TRANSFORM[0] = vec4(size, 0.0, 0.0, 0.0);
	TRANSFORM[1] = vec4(0.0, size, 0.0, 0.0);
	TRANSFORM[2] = vec4(0.0, 0.0, size, 0.0);
	TRANSFORM[3] = EMISSION_TRANSFORM * vec4(offset, 1.0);
	// Start upwind so the fully developed part of the gust passes through the view.
	TRANSFORM[3].xz -= wind * (LIFETIME * coupling * 0.47);
	vec2 drift = gust_velocity(TRANSFORM[3].xz) * coupling;
	VELOCITY = vec3(drift.x, 0.0, drift.y);
	COLOR = vec4(1.0);
	if (particle_kind == 1 && surface_collision) {
		// Seek the nearest rendered surface before becoming visible.
		TRANSFORM[3].y += mix(0.76, 2.4, phase);
		VELOCITY.y = -6.0;
		COLOR.a = 0.0;
	}
	// Phase, normalized age, size/drag variation, and launch altitude.
	CUSTOM = vec4(phase, 0.0, variant, TRANSFORM[3].y);
}

void process() {
	CUSTOM.y += DELTA / LIFETIME;
	float t = CUSTOM.y * LIFETIME;
	float phase = CUSTOM.x * TAU;
	float coupling = mix(drift_range.x, drift_range.y, CUSTOM.z);
	vec2 drift = gust_velocity(TRANSFORM[3].xz) * coupling;
	float speed = length(wind);
	float vertical = 0.0;
	if (particle_kind == 1) {
		if (surface_collision) {
			vertical = VELOCITY.y - 12.0 * DELTA;
			if (COLLIDED) {
				// Godot's heightfield reports a downward normal and signed penetration.
				float orientation = COLLISION_NORMAL.y < 0.0 ? -1.0 : 1.0;
				vec3 normal = COLLISION_NORMAL * orientation;
				float penetration = COLLISION_DEPTH * orientation;
				if (normal.y > 0.45 && penetration > -0.05 && penetration < 0.48) {
					TRANSFORM[3].xyz += normal * (max(penetration, 0.0) + 0.006);
					if (vertical < 0.0 || COLOR.a < 0.5) {
						float bounce = fract(sin(phase + t * 19.2) * 43758.55);
						vertical = mix(0.97, 2.8, bounce) * smoothstep(3.0, 16.0, speed);
						COLOR.a = 1.0;
						CUSTOM.w = TRANSFORM[3].y;
					}
				} else if (COLOR.a < 0.5) {
					ACTIVE = false;
				}
			}
			if (TRANSFORM[3].y < CUSTOM.w - 0.72) {
				COLOR.a = 0.0;
			}
		} else {
			float hop = fract(t * mix(3.8, 6.4, CUSTOM.z) + CUSTOM.x);
			float height = mix(0.065, 0.43, CUSTOM.z) * smoothstep(3.0, 16.0, speed);
			TRANSFORM[3].y = CUSTOM.w + 0.035 + 4.0 * hop * (1.0 - hop) * height;
			drift *= mix(0.78, 1.13, hop);
		}
	} else if (particle_kind == 2) {
		vertical = mix(0.08, 0.42, CUSTOM.z) + 0.18 * sin(phase + t * 1.0);
	} else {
		float flutter = mix(0.32, 1.42, smoothstep(0.0, 14.0, speed));
		drift += vec2(sin(t * 2.9 + phase), cos(t * 2.1 + phase)) * flutter;
		vertical = mix(-0.35, -0.09, CUSTOM.z) + sin(t * 3.5 + phase) * flutter * 0.57;
	}
	VELOCITY.xz = mix(VELOCITY.xz, drift, 1.0 - exp(-DELTA * 9.0));
	VELOCITY.y = vertical;
}
