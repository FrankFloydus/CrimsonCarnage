shader_type particles;
render_mode disable_force;

uniform vec2 spawn_radii = vec2(0.0, 13.0);
uniform float spawn_half_height : hint_range(0.1, 12.0) = 3.6;
uniform vec2 fall_speed_range = vec2(5.8, 9.3);
uniform vec2 drop_scale_range = vec2(0.57, 1.25);
uniform float contact_chance : hint_range(0.0, 1.0) = 0.0;
uniform float contact_surface_offset : hint_range(-0.05, 0.05) = -0.010;
uniform bool storm_spray_contact = false;
uniform vec2 wind;
uniform float storm;

float random_unit(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return float((word >> 22u) ^ word) / 4294967295.0;
}

vec2 drop_wind(float speed, vec2 position) {
	float size_weight = smoothstep(fall_speed_range.x, fall_speed_range.y, speed);
	float wind_response = mix(0.108, 0.54, storm) * mix(1.0, 0.54, size_weight);
	vec2 base = wind * wind_response;
	float pulse = sin(dot(position, vec2(0.22, 0.17)) - TIME * 0.87);
	float curl = sin(dot(position, vec2(-0.16, 0.25)) - TIME * 1.04);
	return base + storm * (base * pulse * 0.24 + vec2(-base.y, base.x) * curl * 0.11);
}

void start() {
	uint seed = RANDOM_SEED ^ NUMBER;
	if (random_unit(seed) > AMOUNT_RATIO) {
		ACTIVE = false;
	}
	float angle = random_unit(seed) * TAU;
	vec2 squared_radii = spawn_radii * spawn_radii;
	float radius = sqrt(mix(squared_radii.x, squared_radii.y, random_unit(seed)));
	float height = mix(-spawn_half_height, spawn_half_height, random_unit(seed));
	vec3 offset = vec3(cos(angle) * radius, height, sin(angle) * radius);
	TRANSFORM[3] = EMISSION_TRANSFORM * vec4(offset, 1.0);
	float drop_weight = random_unit(seed);
	float size = mix(drop_scale_range.x, drop_scale_range.y, drop_weight * drop_weight);
	TRANSFORM[0] = vec4(size, 0.0, 0.0, 0.0);
	TRANSFORM[1] = vec4(0.0, size, 0.0, 0.0);
	TRANSFORM[2] = vec4(0.0, 0.0, size, 0.0);
	CUSTOM.y = mix(fall_speed_range.x, fall_speed_range.y, drop_weight);
	vec2 drift = drop_wind(CUSTOM.y, TRANSFORM[3].xz);
	// Modest upwind bias keeps the storm field centered without rotating with the camera.
	TRANSFORM[3].xz -= drift * 0.40;
	CUSTOM.xzw = vec3(drift.x, 0.0, drift.y);
	VELOCITY = vec3(drift.x, -CUSTOM.y, drift.y);
}

void process() {
	CUSTOM.z += DELTA / LIFETIME;
	float phase = float(INDEX) * 2.4 + CUSTOM.z * 8.0;
	vec2 flutter = vec2(sin(phase), cos(phase * 1.3)) * 0.045;
	vec2 drift = drop_wind(CUSTOM.y, TRANSFORM[3].xz) + flutter;
	CUSTOM.xw = drift;
	VELOCITY = vec3(drift.x, -CUSTOM.y, drift.y);
	if (COLLIDED) {
		float orientation = COLLISION_NORMAL.y < 0.0 ? -1.0 : 1.0;
		vec3 normal = COLLISION_NORMAL * orientation;
		float penetration = COLLISION_DEPTH * orientation;
		float limit = length(VELOCITY) * DELTA * 1.4 + 0.025;
		uint seed = (RANDOM_SEED ^ NUMBER) + 73u;
		float chance = contact_chance * (storm_spray_contact ? storm : 1.0);
		if (normal.y > 0.35 && penetration >= -0.03 && penetration < limit && random_unit(seed) < chance) {
			vec3 tangent = normalize(cross(normal, vec3(0.0, 0.0, 1.0)));
			vec3 bitangent = cross(tangent, normal);
			vec3 position = TRANSFORM[3].xyz + normal * (penetration + contact_surface_offset);
			mat4 impact = mat4(vec4(tangent, 0.0), vec4(normal, 0.0), vec4(bitangent, 0.0), vec4(position, 1.0));
			vec4 payload = vec4(wind, storm, random_unit(seed));
			uint flags = FLAG_EMIT_POSITION | FLAG_EMIT_ROT_SCALE | FLAG_EMIT_CUSTOM;
			emit_subparticle(impact, vec3(0.0), vec4(1.0), payload, flags);
		}
		ACTIVE = false;
	}
}
