shader_type particles;
render_mode disable_force;

uniform sampler2D path_cache : filter_nearest, repeat_disable;
uniform int path_count = 0;
uniform float sprite_alpha = 0.33;
uniform float sprite_scale = 1.0;
uniform bool spot = false;
uniform vec3 camera_position;
uniform vec3 spawn_origin;

float random_unit(inout uint state) {
	state = state * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return float((word >> 22u) ^ word) / 4294967295.0;
}

void start() {
	uint seed = RANDOM_SEED ^ NUMBER;
	int path = min(int(random_unit(seed) * float(path_count)), max(path_count - 1, 0));
	vec4 start_path = texelFetch(path_cache, ivec2(path, 0), 0);
	vec4 end_path = texelFetch(path_cache, ivec2(path, 1), 0);
	ACTIVE = path_count > 0 && end_path.w >= 0.5 && start_path.w >= 0.01 && random_unit(seed) <= AMOUNT_RATIO;
	float lifetime = start_path.w;
	vec2 size_bounds = spot ? vec2(0.015, 0.030) : vec2(0.70, 1.50);
	float size = mix(size_bounds.x, size_bounds.y, random_unit(seed)) * sprite_scale;
	float luminance = mix(0.20, spot ? 0.90 : 1.0, random_unit(seed));
	vec2 opacity_bounds = spot ? vec2(0.30, 0.50) : vec2(0.10, 0.30);
	float opacity = sprite_alpha * mix(opacity_bounds.x, opacity_bounds.y, random_unit(seed));
	float rotation = random_unit(seed) * TAU;
	float tile = min(floor(random_unit(seed) * 4.0), 3.0);
	TRANSFORM[0] = vec4(size, 0.0, 0.0, 0.0);
	TRANSFORM[1] = vec4(0.0, size, 0.0, 0.0);
	TRANSFORM[2] = vec4(0.0, 0.0, size, 0.0);
	float vertical = random_unit(seed) * 2.0 - 1.0;
	float angle = random_unit(seed) * TAU;
	float horizontal = sqrt(max(0.0, 1.0 - vertical * vertical));
	vec3 offset = vec3(horizontal * cos(angle), vertical, horizontal * sin(angle));
	offset *= 0.25 * mix(0.2, 1.0, pow(random_unit(seed), 1.0 / 3.0));
	TRANSFORM[3] = vec4(start_path.xyz + offset, 1.0);
	VELOCITY = (end_path.xyz - start_path.xyz) / max(lifetime, 0.01);
	COLOR = vec4(vec3(luminance), opacity);
	CUSTOM = vec4(rotation, 0.0, tile, lifetime);
}

void process() {
	CUSTOM.y += DELTA / max(CUSTOM.w, 0.01);
	float distance_to_field = min(distance(TRANSFORM[3].xyz, camera_position), distance(TRANSFORM[3].xyz, spawn_origin));
	if (CUSTOM.y >= 1.0 || distance_to_field >= 20.0) {
		ACTIVE = false;
	}
}

