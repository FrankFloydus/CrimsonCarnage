shader_type particles;
render_mode disable_force, disable_velocity;

void start() {
	// The rain emitter supplies the contact position and a basis aligned to the surface.
	if (RESTART_POSITION) {
		ACTIVE = false;
	}
	CUSTOM.x = 0.0;
	CUSTOM.z = 0.0;
	CUSTOM.w = fract(float((RANDOM_SEED ^ NUMBER) % 1021u) * 0.618034);
}

void process() {
	CUSTOM.x += DELTA;
	CUSTOM.z = CUSTOM.x / LIFETIME;
	if (CUSTOM.z >= 1.0) {
		ACTIVE = false;
	}
}
