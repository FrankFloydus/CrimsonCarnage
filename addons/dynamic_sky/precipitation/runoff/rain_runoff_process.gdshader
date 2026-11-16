shader_type particles;
render_mode disable_force, disable_velocity;

// Initial speed, gravity, and terminal speed, also read by the CPU impact scheduler.
uniform vec3 fall_settings;
uniform float sprite_scale = 1.0;
uniform vec2 sprite_size_range = vec2(0.58, 1.08);

void start() {
	if (RESTART_POSITION || RESTART_CUSTOM) {
		ACTIVE = false;
	}
	// CPU supplies a cached solid receiver or the authored water cutoff below the eave.
	USERDATA1 = vec4(TRANSFORM[3].y, CUSTOM.x, CUSTOM.z, 0.0);
	CUSTOM = vec4(0.0);
	float seed = fract(float((RANDOM_SEED ^ NUMBER) % 1021u) * 0.618034);
	float size = mix(sprite_size_range.x, sprite_size_range.y, seed) * sprite_scale;
	COLOR = vec4(seed, fract(seed * 19.671), fract(seed * 61.57), fract(seed * 97.31));
	TRANSFORM[0] = vec4(size, 0.0, 0.0, 0.0);
	TRANSFORM[1] = vec4(0.0, size, 0.0, 0.0);
	TRANSFORM[2] = vec4(0.0, 0.0, size, 0.0);
}

void process() {
	USERDATA1.w += DELTA;
	float elapsed = USERDATA1.w;
	float acceleration_time = min(elapsed, (fall_settings.z - fall_settings.x) / fall_settings.y);
	float distance = fall_settings.x * acceleration_time + 0.5 * fall_settings.y * acceleration_time * acceleration_time;
	distance += fall_settings.z * (elapsed - acceleration_time);
	TRANSFORM[3].y = USERDATA1.x - distance;
	CUSTOM.y = min(fall_settings.x + fall_settings.y * elapsed, fall_settings.z);
	CUSTOM.z = elapsed / LIFETIME;
	if (CUSTOM.z >= 1.0 || (USERDATA1.z > 0.01 && TRANSFORM[3].y <= USERDATA1.y)) {
		ACTIVE = false;
	}
}
