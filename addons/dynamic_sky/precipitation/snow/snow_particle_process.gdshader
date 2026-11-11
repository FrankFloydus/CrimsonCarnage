shader_type particles;
render_mode disable_force, disable_velocity;

uniform sampler2D path_cache : repeat_disable, filter_nearest;
uniform int path_count = 2000;
uniform float sprite_size_meters = 0.01;
uniform float snow_twirl = 1.0;
uniform float custom_time_dilation = 1.0;
uniform float minimum_view_distance = 0.45;
uniform float alpha_scale_distance = 25.0;
uniform float alpha_scale_multiplier = 3.0;
uniform float camera_affects_direction = 1.0;
uniform float motion_stretching = 1.0;
uniform float stretching_speed = 1.3;
uniform float maximum_spawn_distance = 20.0;
uniform vec3 camera_position;
uniform vec3 spawn_origin;
uniform vec4 kill_sphere = vec4(0.0);
uniform vec3 camera_velocity;
uniform vec3 camera_forward_derivative;
uniform bool emit_contact = false;

float random_unit(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return float((word >> 22u) ^ word) / 4294967295.0;
}

vec3 random_direction(inout uint state) {
	float height = random_unit(state) * 2.0 - 1.0;
	float angle = random_unit(state) * TAU;
	float radius = sqrt(max(0.0, 1.0 - height * height));
	return vec3(radius * cos(angle), height, radius * sin(angle));
}

void start() {
	uint seed = RANDOM_SEED ^ NUMBER;
	float density = random_unit(seed);
	int path_index = min(int(random_unit(seed) * float(path_count)), path_count - 1);
	vec4 start_lifetime = texelFetch(path_cache, ivec2(path_index, 0), 0);
	vec4 end_valid = texelFetch(path_cache, ivec2(path_index, 1), 0);
	vec4 normal_hit = texelFetch(path_cache, ivec2(path_index, 2), 0);
	vec3 offset = random_direction(seed) * mix(0.2, 1.0, random_unit(seed)) * 0.25;
	USERDATA1 = vec4(start_lifetime.xyz + offset, start_lifetime.w);
	USERDATA2 = vec4(end_valid.xyz + offset, 0.0);
	vec3 phases;
	phases.x = random_unit(seed) * 9.0;
	phases.y = random_unit(seed) * 9.0;
	phases.z = random_unit(seed) * 9.0;
	USERDATA3 = vec4(phases, mix(0.02, 0.07, random_unit(seed)));
	float alpha = mix(0.15, 0.6, pow(random_unit(seed), 15.0));
	float size = sprite_size_meters * mix(1.0, 2.4, random_unit(seed));
	USERDATA4 = vec4(alpha, size, normal_hit.w, random_unit(seed));
	USERDATA5 = vec4(normal_hit.xyz, 0.0);
	// COLOR carries the two world-normal tilts and the two atlas offsets, not rendered color.
	COLOR = vec4(random_unit(seed), random_unit(seed), 0.0, 0.0);
	COLOR.b = random_unit(seed) < 0.5 ? 0.0 : 0.5;
	COLOR.a = random_unit(seed) < 0.5 ? 0.0 : 0.5;
	CUSTOM = vec4(0.0, 0.0, 0.0, alpha);
	TRANSFORM = mat4(1.0);
	TRANSFORM[0].x = size;
	TRANSFORM[1].y = size;
	TRANSFORM[3] = vec4(USERDATA1.xyz, 1.0);
	VELOCITY = (USERDATA2.xyz - USERDATA1.xyz) / max(USERDATA1.w, 0.000001);
	if (density >= AMOUNT_RATIO || end_valid.w < 0.5 || start_lifetime.w <= 0.0) {
		ACTIVE = false;
	}
}

void process() {
	USERDATA2.w += DELTA;
	float path_lifetime = max(USERDATA1.w, 0.000001);
	float normalized_age = clamp(USERDATA2.w / path_lifetime, 0.0, 1.0);
	vec3 position = mix(USERDATA1.xyz, USERDATA2.xyz, normalized_age);
	float distance_to_camera = distance(camera_position, position);
	// Source bounds use the untwirled position and the union of observer/spawn spheres.
	if (min(distance(position, spawn_origin), distance_to_camera) >= maximum_spawn_distance) {
		ACTIVE = false;
	}
	float time = TIME * custom_time_dilation;
	vec3 phases = USERDATA3.xyz;
	float amplitude = USERDATA3.w;
	// Source sine periods are seconds. Convert its Z-up offset to Godot's Y-up world.
	vec3 twirl = amplitude * vec3(
		sin((time + phases.y) * TAU / 0.8),
		0.4 * sin((time + phases.z) * TAU / 0.4),
		-sin((time + phases.x) * TAU / 0.6)
	);
	twirl *= snow_twirl;
	TRANSFORM[3] = vec4(position + twirl, 1.0);
	vec3 intermediate_velocity = CUSTOM.xyz - twirl * 15.0;
	float speed_alpha = max(1.0 - clamp(length(intermediate_velocity) / 20.0, 0.0, 1.0), 0.15);
	float distance_alpha = mix(1.0, alpha_scale_multiplier, clamp(distance_to_camera / alpha_scale_distance, 0.0, 1.0));
	float visibility = distance_to_camera > minimum_view_distance ? 1.0 : 0.0;
	CUSTOM.w = USERDATA4.x * speed_alpha * distance_alpha * visibility;

	// This final stage deliberately replaces the intermediate twirl velocity used by alpha.
	VELOCITY = (USERDATA2.xyz - USERDATA1.xyz) / path_lifetime;
	vec3 sprite_velocity = VELOCITY - camera_velocity * camera_affects_direction * 0.5;
	sprite_velocity -= camera_forward_derivative * camera_affects_direction;
	CUSTOM.xyz = sprite_velocity;
	float size = USERDATA4.y;
	TRANSFORM[0] = vec4(size, 0.0, 0.0, 0.0);
	TRANSFORM[1] = vec4(0.0, size * (1.0 + length(sprite_velocity) / stretching_speed * motion_stretching), 0.0, 0.0);
	TRANSFORM[2] = vec4(0.0, 0.0, 1.0, 0.0);
	if (distance(position, kill_sphere.xyz) <= kill_sphere.w) {
		ACTIVE = false;
	}

	if (normalized_age >= 1.0) {
		if (ACTIVE && emit_contact && USERDATA4.z > 0.5) {
			vec3 normal = USERDATA5.xyz;
			vec3 reference_axis = abs(normal.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
			vec3 tangent = normalize(cross(normal, reference_axis));
			vec3 bitangent = cross(tangent, normal);
			mat4 impact = mat4(vec4(tangent, 0.0), vec4(normal, 0.0), vec4(bitangent, 0.0), vec4(USERDATA2.xyz - normal * 0.007, 1.0));
			emit_subparticle(impact, vec3(0.0), vec4(1.0), vec4(USERDATA4.w, 0.0, 0.0, 0.0), FLAG_EMIT_POSITION | FLAG_EMIT_ROT_SCALE | FLAG_EMIT_CUSTOM);
		}
		ACTIVE = false;
	}
}
