shader_type particles;
render_mode disable_force, disable_velocity;

void start() {
	// Only the airborne snow emitter supplies a contact position and surface basis.
	if (RESTART_POSITION) {
		ACTIVE = false;
	} else {
		float variation = fract(CUSTOM.x);
		float angle = TAU * fract(variation * 5.17);
		float size = mix(0.55, 1.12, fract(variation * 9.53));
		vec3 tangent = TRANSFORM[0].xyz;
		vec3 bitangent = TRANSFORM[2].xyz;
		TRANSFORM[0].xyz = (tangent * cos(angle) + bitangent * sin(angle)) * size;
		TRANSFORM[2].xyz = (bitangent * cos(angle) - tangent * sin(angle)) * size;
		CUSTOM.z = 0.0;
	}
}

void process() {
	CUSTOM.z += DELTA / LIFETIME;
	if (CUSTOM.z >= 1.0) {
		ACTIVE = false;
	}
}
