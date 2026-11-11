shader_type particles;
render_mode disable_force;

uniform vec2 wind;
uniform float blizzard : hint_range(0.0, 1.0) = 0.0;

vec2 ground_flow(vec2 world, float phase) {
	float crest = sin(dot(world, vec2(0.27, 0.41)) - TIME * 2.24);
	float eddy = sin(dot(world, vec2(-0.56, 0.23)) - TIME * 1.84 + phase);
	vec2 side = vec2(-wind.y, wind.x);
	return wind * (0.44 + 0.15 * crest) + side * eddy * 0.18;
}

void orient_drift(inout mat4 transform, vec3 normal, vec2 flow, float scale) {
	vec3 direction = normalize(vec3(flow.x, 0.001, flow.y));
	vec3 tangent = normalize(direction - normal * dot(direction, normal));
	vec3 side = cross(tangent, normal);
	transform[0] = vec4(tangent * scale, 0.0);
	transform[1] = vec4(normal * scale, 0.0);
	transform[2] = vec4(side * scale, 0.0);
}

void start() {
	if (RESTART_POSITION || blizzard < 0.02) {
		ACTIVE = false;
	} else {
		float seed = CUSTOM.x;
		vec3 normal = normalize(TRANSFORM[1].xyz);
		vec2 flow = ground_flow(TRANSFORM[3].xz, seed * TAU);
		TRANSFORM[3].xyz += normal * 0.055;
		VELOCITY = vec3(flow.x, mix(0.27, 1.15, seed) * blizzard, flow.y);
		CUSTOM = vec4(VELOCITY.xy, 0.0, VELOCITY.z);
		COLOR = vec4(vec3(mix(0.75, 1.0, seed)), seed);
		orient_drift(TRANSFORM, normal, flow, mix(0.47, 1.12, seed));
	}
}

void process() {
	CUSTOM.z += DELTA / LIFETIME;
	if (CUSTOM.z >= 1.0) {
		ACTIVE = false;
	}
	float seed = COLOR.a;
	vec2 flow = ground_flow(TRANSFORM[3].xz, seed * TAU);
	VELOCITY.xz = mix(VELOCITY.xz, flow, 1.0 - exp(-DELTA * 8.0));
	VELOCITY.y -= DELTA * 4.4;
	vec3 normal = vec3(0.0, 1.0, 0.0);
	if (COLLIDED) {
		float sign_y = COLLISION_NORMAL.y < 0.0 ? -1.0 : 1.0;
		normal = COLLISION_NORMAL * sign_y;
		float penetration = COLLISION_DEPTH * sign_y;
		if (normal.y < 0.38 || penetration > 0.56) {
			ACTIVE = false;
		} else {
			TRANSFORM[3].xyz += normal * (max(penetration, 0.0) + 0.031);
			float bounce = max(0.0, -dot(VELOCITY, normal));
			VELOCITY -= normal * dot(VELOCITY, normal);
			float eddy = 0.5 + 0.5 * sin(dot(TRANSFORM[3].xz, vec2(0.64, 0.37)) - TIME * 2.62 + seed * TAU);
			VELOCITY += normal * min(1.15, bounce * 0.27 + eddy * eddy * 0.72 * blizzard);
		}
	}
	CUSTOM.xyw = VELOCITY;
	orient_drift(TRANSFORM, normal, VELOCITY.xz, mix(0.47, 1.12, seed) * (1.0 + CUSTOM.z * 0.23));
}
