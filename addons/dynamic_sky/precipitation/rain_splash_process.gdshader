shader_type particles;
render_mode disable_force;

#include "res://addons/dynamic_sky/precipitation/rain/rain_contact_water.gdshaderinc"

uniform float impact_lifetime = 0.34;
uniform bool external_impacts = false;
uniform bool cached_impacts = false;
uniform sampler2D impact_cache : filter_nearest, repeat_disable;
uniform int impact_path_count = 0;
uniform float duplicate_radius = 0.22;
uniform float trajectory_radius = 20.0;
uniform float collision_radius = 0.015;
uniform float contact_chance = 0.92;
uniform float contact_surface_offset = 0.004;
uniform vec2 camera_forward = vec2(0.0, -1.0);
uniform vec2 wind = vec2(0.0);

const float SEARCH_SPEED = 45.0;
const float SEARCH_HEIGHT = 8.0;

float random_unit(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return float((word >> 22u) ^ word) / 4294967295.0;
}

void start() {
	uint seed = RANDOM_SEED ^ NUMBER;
	if (external_impacts) {
		// Runoff supplies a surface basis only. Falling rain also supplies horizontal impact velocity and variation.
		ACTIVE = !RESTART_POSITION && !RESTART_ROT_SCALE;
		VELOCITY = vec3(0.0);
		vec2 impact_wind = RESTART_CUSTOM ? vec2(0.0) : CUSTOM.xy;
		float variation = RESTART_CUSTOM ? random_unit(seed) : CUSTOM.w;
		CUSTOM = vec4(0.0, impact_wind, variation);
	} else if (cached_impacts) {
		float rate_sample = random_unit(seed);
		int row = min(int(random_unit(seed) * float(impact_path_count)), max(impact_path_count - 1, 0));
		vec4 hit = texelFetch(impact_cache, ivec2(row, 0), 0);
		vec3 normal = texelFetch(impact_cache, ivec2(row, 1), 0).xyz;
		ACTIVE = impact_path_count > 0 && hit.a > 0.5 && rate_sample < pow(AMOUNT_RATIO, 1.7) * contact_chance;
		if (ACTIVE) {
			vec3 reference_axis = abs(normal.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
			vec3 tangent = normalize(cross(normal, reference_axis));
			vec3 bitangent = cross(tangent, normal);
			float phase = random_unit(seed) * TAU;
			float distance_to_camera = distance(hit.xyz, EMISSION_TRANSFORM[3].xyz);
			float distance_weight = clamp((distance_to_camera - 3.0) / max(trajectory_radius - 3.0, 0.01), 0.0, 1.0);
			float spread = mix(duplicate_radius, duplicate_radius * 4.0, distance_weight);
			vec3 contact = hit.xyz + (tangent * cos(phase) + bitangent * sin(phase)) * spread * random_unit(seed);
			ACTIVE = !rain_contact_below_water(contact);
			vec3 center = contact + normal * contact_surface_offset;
			TRANSFORM = mat4(vec4(tangent, 0.0), vec4(normal, 0.0), vec4(bitangent, 0.0), vec4(center, 1.0));
			VELOCITY = vec3(0.0);
			CUSTOM = vec4(0.0, wind, random_unit(seed));
		}
	} else {
		if (random_unit(seed) > pow(AMOUNT_RATIO, 1.7)) {
			ACTIVE = false;
		}
		float angle = random_unit(seed) * TAU;
		float radius = 8.2 * sqrt(random_unit(seed));
		vec2 offset = vec2(cos(angle), sin(angle)) * radius + camera_forward * 3.2;
		float jitter = random_unit(seed);
		TRANSFORM = EMISSION_TRANSFORM;
		TRANSFORM[3].xyz += vec3(offset.x, SEARCH_HEIGHT + jitter * 0.35, offset.y);
		VELOCITY = vec3(wind.x * 0.26, -SEARCH_SPEED, wind.y * 0.26);
		CUSTOM = vec4(-1.0, wind, jitter);
	}
}

void process() {
	if (CUSTOM.x >= 0.0) {
		CUSTOM.x += DELTA;
		if (CUSTOM.x >= impact_lifetime) {
			ACTIVE = false;
		}
	} else if (COLLIDED) {
		// Godot's heightfield tests the bottom of the sphere and reports down-facing winding.
		float orientation = COLLISION_NORMAL.y < 0.0 ? -1.0 : 1.0;
		vec3 normal = COLLISION_NORMAL * orientation;
		float signed_distance = COLLISION_DEPTH * orientation - collision_radius * normal.y;
		uint seed = (RANDOM_SEED ^ NUMBER) + 73u;
		float crossing_limit = length(VELOCITY) * DELTA * 1.4 + 0.06;
		if (normal.y < 0.35 || signed_distance < -0.03 || signed_distance > crossing_limit ||
				random_unit(seed) >= contact_chance) {
			ACTIVE = false;
		} else {
			vec3 tangent = normalize(cross(normal, vec3(0.0, 0.0, 1.0)));
			vec3 bitangent = cross(tangent, normal);
			vec3 contact = TRANSFORM[3].xyz + normal * signed_distance;
			if (rain_contact_below_water(contact)) {
				ACTIVE = false;
			} else {
				contact += normal * contact_surface_offset;
				TRANSFORM = mat4(vec4(tangent, 0.0), vec4(normal, 0.0), vec4(bitangent, 0.0), vec4(contact, 1.0));
				VELOCITY = vec3(0.0);
				CUSTOM.x = 0.0;
			}
		}
	}
}
