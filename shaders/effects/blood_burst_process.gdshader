shader_type particles;
render_mode disable_force, disable_velocity;

uniform int layer : hint_enum("Liquid", "Drops", "Mist") = 0;
uniform vec2 speed_range = vec2(3.2, 7.2);
uniform float spread : hint_range(0.0, 1.5, 0.01) = 0.57;
uniform float drag : hint_range(0.1, 16.0, 0.1) = 5.1;
uniform float gravity : hint_range(0.0, 15.0, 0.1) = 8.5;
uniform vec2 width_range = vec2(0.12, 0.27);
uniform vec2 life_range = vec2(0.29, 0.51);
uniform vec2 trail_range = vec2(0.065, 0.15);
uniform int variation = 0;

uint hash_seed(uint seed) {
	seed = seed * 747796405u + 2891336453u;
	seed = ((seed >> ((seed >> 28u) + 4u)) ^ seed) * 277803737u;
	return (seed >> 22u) ^ seed;
}

float roll(uint seed) {
	return float(hash_seed(seed) & 65535u) / 65536.0;
}

vec3 flight(vec3 origin, vec3 velocity, float seconds) {
	float damped_time = (1.0 - exp(-drag * seconds)) / drag;
	float fall = gravity * (seconds - damped_time) / drag;
	return origin + velocity * damped_time - vec3(0.0, fall, 0.0);
}

void start() {
	uint seed = hash_seed(uint(variation) * 23629u + INDEX * 11939u);
	float bearing = TAU * fract(float(INDEX) * 0.61803399 + roll(seed + 1u) * 0.24 + float(variation) * 0.27);
	float distance = pow(roll(seed + 2u), layer == 0 ? 0.65 : 0.49);
	vec2 fan = vec2(cos(bearing) * 0.93, sin(bearing)) * spread * distance;
	fan.y += layer == 0 ? 0.17 : 0.10;
	float speed_roll = roll(seed + 3u);
	float speed = mix(speed_range.x, speed_range.y, layer == 1 ? pow(speed_roll, 1.6) : speed_roll);
	float lifespan = mix(life_range.x, life_range.y, roll(seed + 4u));
	bool cohesive = layer == 0 && roll(seed + 8u) < 0.34;
	float delay = cohesive ? mix(0.025, 0.105, roll(seed + 9u)) : 0.0;
	if (cohesive) {
		lifespan += 0.085;
		fan.y += mix(0.19, 0.48, roll(seed + 10u));
		speed *= mix(0.75, 0.91, roll(seed + 11u));
	}
	vec3 direction = normalize(mat3(EMISSION_TRANSFORM) * vec3(fan, -1.0));
	vec3 origin = EMISSION_TRANSFORM[3].xyz;
	USERDATA1 = vec4(origin, lifespan);
	float size_roll = roll(seed + 5u);
	// Fine spray is much more common than the heavier droplets.
	size_roll = layer == 1 ? pow(size_roll, 3.4) : size_roll;
	USERDATA2 = vec4(direction * speed, mix(width_range.x, width_range.y, size_roll));
	USERDATA3 = vec4(mix(trail_range.x, trail_range.y, roll(seed + 6u)), 0.0, delay, 0.0);
	float pattern = roll(seed + 7u) * 83.0 + float(variation) * 7.31;
	CUSTOM = vec4(0.0, pattern, 0.0, float(layer) + (cohesive ? 0.25 : 0.0));
	TRANSFORM = mat4(1.0);
	TRANSFORM[3].xyz = origin;
}

void process() {
	USERDATA3.y += DELTA;
	float seconds = max(0.0, USERDATA3.y - USERDATA3.z);
	bool cohesive = CUSTOM.w > 0.1 && CUSTOM.w < 0.5;
	float age = min(seconds / USERDATA1.w, 1.0);
	vec3 origin = USERDATA1.xyz;
	vec3 velocity = USERDATA2.xyz;
	float width = USERDATA2.w;
	vec3 front = flight(origin, velocity, seconds);
	vec3 tangent = normalize(velocity * exp(-drag * seconds) - vec3(0.0, gravity * (1.0 - exp(-drag * seconds)) / drag, 0.0));
	vec3 center = front;
	float extent = width;
	if (layer == 0) {
		// Each tongue grows from the hit before its trailing end releases into flight.
		float trail = USERDATA3.x * mix(1.0, cohesive ? 0.55 : 0.27, smoothstep(0.16, 0.88, age));
		vec3 rear = flight(origin, velocity, max(0.0, seconds - trail));
		vec3 span = front - rear;
		tangent = normalize(span + tangent * 0.0001);
		center = (front + rear) * 0.5;
		extent = max(cohesive ? 0.14 : 0.025, length(span)) * (cohesive ? 0.91 : 1.28);
		width *= mix(0.60, 1.07, smoothstep(0.0, 0.085, seconds)) * mix(1.0, cohesive ? 0.61 : 0.27, smoothstep(0.29, 0.88, age));
		if (cohesive) {
			width *= 3.18;
		}
	} else if (layer == 1) {
		float length_jitter = mix(1.45, 4.45, fract(CUSTOM.y * 0.41));
		extent *= mix(length_jitter, 1.06, smoothstep(0.015, 0.19, seconds));
	} else {
		width *= mix(0.62, 1.35, smoothstep(0.0, 0.64, age));
		extent = width * 1.03;
	}
	float attack = smoothstep(0.001, layer == 2 ? 0.033 : 0.014, seconds);
	float release = 1.0 - smoothstep(layer == 0 ? (cohesive ? 0.41 : 0.21) : 0.36, 1.0, age);
	CUSTOM.x = age;
	CUSTOM.z = attack * release;
	vec3 reference = abs(tangent.y) < 0.98 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 side = normalize(cross(tangent, reference));
	TRANSFORM = mat4(vec4(side * width, 0.0), vec4(tangent * extent, 0.0),
		vec4(cross(side, tangent), 0.0), vec4(center, 1.0));
	ACTIVE = age < 1.0;
}
