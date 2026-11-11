shader_type particles;
render_mode disable_force, disable_velocity;

void start() {
	if (RESTART_POSITION || RESTART_CUSTOM) {
		ACTIVE = false;
	}
	vec2 wind = CUSTOM.xy;
	float seed = CUSTOM.w;
	vec3 surface_up = normalize(TRANSFORM[1].xyz);
	TRANSFORM[3].xyz += surface_up * 0.012;
	vec2 drift = wind * mix(0.018, 0.037, seed);
	CUSTOM = vec4(drift, 0.0, seed);
}

void process() {
	CUSTOM.z += DELTA / LIFETIME;
	if (CUSTOM.z >= 1.0) {
		ACTIVE = false;
	}
}
