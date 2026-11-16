shader_type particles;
render_mode disable_force;

#include "res://addons/dynamic_sky/precipitation/rain/rain_contact_water.gdshaderinc"

uniform vec2 spawn_radii = vec2(0.0, 13.0);
uniform float spawn_half_height : hint_range(0.1, 12.0) = 3.6;
uniform vec2 fall_speed_range = vec2(5.8, 9.3);
uniform vec2 drop_scale_range = vec2(0.57, 1.25);
uniform float contact_chance : hint_range(0.0, 1.0) = 0.0;
uniform float contact_surface_offset : hint_range(-0.05, 0.05) = 0.004;
uniform float collision_radius = 0.015;
uniform float spawn_exponent = 1.7;
uniform bool storm_spray_contact = false;
uniform vec2 wind;
uniform float storm;
uniform bool camera_biased_volume = false;
uniform vec3 fall_camera_position;
uniform vec3 fall_camera_forward = vec3(0.0, 0.0, -1.0);
uniform vec4 fall_volume = vec4(20.0, 6.0, 0.5, 0.9);
uniform float fall_radial_distribution = 1.0;

float random_unit(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return float((word >> 22u) ^ word) / 4294967295.0;
}

vec3 rain_velocity(float fall_speed, inout uint seed) {
	// Convert the rig's physical wind to the source's normalized calm/rain/storm scale.
	float wind_strength = clamp((length(wind) - 4.0) / 7.7047, 0.0, 1.0);
	float strong_wind = pow(clamp((wind_strength - 0.2) / 0.8, 0.0, 1.0), 2.5);
	vec2 direction = length(wind) > 0.001 ? normalize(wind) : vec2(0.0);
	vec2 horizontal = direction * (9.0 * strong_wind * fall_speed / 7.5);
	vec3 velocity = vec3(horizontal.x, -fall_speed, horizontal.y);
	float vertical = random_unit(seed) * 2.0 - 1.0;
	float azimuth = random_unit(seed) * TAU;
	float radius = sqrt(max(1.0 - vertical * vertical, 0.0));
	vec3 jitter = vec3(radius * cos(azimuth), vertical, radius * sin(azimuth));
	velocity = mix(velocity, jitter * length(velocity), mix(0.01, 0.228, wind_strength));
	velocity.y = min(velocity.y, -0.1);
	return velocity;
}

vec3 camera_biased_birth(inout uint seed) {
	vec2 forward = fall_camera_forward.xz;
	float forward_length = length(forward);
	float wide_angle = mix(-0.5, 0.5, random_unit(seed));
	float narrow_angle = mix(-0.2, 0.2, random_unit(seed));
	float bias = pow(max(random_unit(seed), 0.000001), fall_volume.w * forward_length);
	float angle = mix(mix(narrow_angle, wide_angle, bias), wide_angle, pow(abs(fall_camera_forward.y), 3.0)) * TAU;
	vec2 heading = forward_length < 0.02 ? vec2(1.0, 0.0) : forward / forward_length;
	vec2 direction = vec2(heading.x * cos(angle) - heading.y * sin(angle), heading.x * sin(angle) + heading.y * cos(angle));
	float radial_weight = pow(random_unit(seed), fall_radial_distribution);
	float radius = fall_volume.x * mix(0.1, 1.0, radial_weight) * sqrt(random_unit(seed));
	float height = fall_volume.y * (random_unit(seed) - 0.25);
	vec3 spawn_origin = fall_camera_position + fall_camera_forward * fall_volume.z;
	return spawn_origin + vec3(direction.x * radius, height, direction.y * radius);
}

void start() {
	uint seed = RANDOM_SEED ^ NUMBER;
	if (random_unit(seed) > pow(AMOUNT_RATIO, spawn_exponent)) {
		ACTIVE = false;
	}
	if (camera_biased_volume) {
		TRANSFORM[3] = vec4(camera_biased_birth(seed), 1.0);
	} else {
		float angle = random_unit(seed) * TAU;
		vec2 squared_radii = spawn_radii * spawn_radii;
		float radius = sqrt(mix(squared_radii.x, squared_radii.y, random_unit(seed)));
		float height = mix(-spawn_half_height, spawn_half_height, random_unit(seed));
		vec3 offset = vec3(cos(angle) * radius, height, sin(angle) * radius);
		TRANSFORM[3] = EMISSION_TRANSFORM * vec4(offset, 1.0);
	}
	float drop_weight = random_unit(seed);
	float size = mix(drop_scale_range.x, drop_scale_range.y, drop_weight);
	TRANSFORM[0] = vec4(size, 0.0, 0.0, 0.0);
	TRANSFORM[1] = vec4(0.0, size, 0.0, 0.0);
	TRANSFORM[2] = vec4(0.0, 0.0, size, 0.0);
	float fall_speed = mix(fall_speed_range.x, fall_speed_range.y, random_unit(seed));
	VELOCITY = rain_velocity(fall_speed, seed);
	if (!camera_biased_volume) {
		TRANSFORM[3].xz -= VELOCITY.xz * 0.40;
	}
	CUSTOM = vec4(VELOCITY.x, -VELOCITY.y, 0.0, VELOCITY.z);
	// Size, texture shape, refractive angle/strength, and alpha use independent draws.
	float shape_seed = random_unit(seed);
	float angle_seed = random_unit(seed);
	float refraction_seed = random_unit(seed);
	float alpha_seed = random_unit(seed);
	COLOR = vec4(shape_seed, angle_seed, refraction_seed, alpha_seed);
}

void process() {
	CUSTOM.z += DELTA / LIFETIME;
	bool inside_volume = true;
	if (camera_biased_volume) {
		vec3 position = TRANSFORM[3].xyz;
		vec3 spawn_origin = fall_camera_position + fall_camera_forward * fall_volume.z;
		inside_volume = min(distance(position, fall_camera_position), distance(position, spawn_origin)) < fall_volume.x;
	}
	if (!inside_volume) {
		ACTIVE = false;
	} else if (COLLIDED) {
		float orientation = COLLISION_NORMAL.y < 0.0 ? -1.0 : 1.0;
		vec3 normal = COLLISION_NORMAL * orientation;
		float penetration = COLLISION_DEPTH * orientation;
		// Native heightfield depth is measured from the bottom of the collision sphere.
		float center_to_surface = penetration - collision_radius * normal.y;
		float limit = length(VELOCITY) * DELTA * 1.4 + 0.025;
		uint seed = (RANDOM_SEED ^ NUMBER) + 73u;
		float chance = contact_chance * (storm_spray_contact ? storm : 1.0);
		if (normal.y > 0.35 && center_to_surface >= -0.03 && center_to_surface < limit && random_unit(seed) < chance) {
			vec3 tangent = normalize(cross(normal, vec3(0.0, 0.0, 1.0)));
			vec3 bitangent = cross(tangent, normal);
			vec3 receiver = TRANSFORM[3].xyz + normal * center_to_surface;
			if (!rain_contact_below_water(receiver)) {
				vec3 position = receiver + normal * contact_surface_offset;
				mat4 impact = mat4(vec4(tangent, 0.0), vec4(normal, 0.0), vec4(bitangent, 0.0), vec4(position, 1.0));
				vec4 payload = vec4(VELOCITY.xz, storm, random_unit(seed));
				uint flags = FLAG_EMIT_POSITION | FLAG_EMIT_ROT_SCALE | FLAG_EMIT_CUSTOM;
				emit_subparticle(impact, vec3(0.0), vec4(1.0), payload, flags);
			}
		}
		ACTIVE = false;
	}
}
