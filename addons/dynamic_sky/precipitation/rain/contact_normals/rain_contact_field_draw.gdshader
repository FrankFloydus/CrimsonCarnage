shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

uniform float height_origin_m;
uniform float metres_per_texel = 0.015625;
varying float hit_age;
varying float seed;
varying vec3 hit_normal;
varying vec3 tangent_x;
varying vec3 tangent_z;
varying vec2 uv_plane;
varying float height_m;

void vertex() {
	hit_age = INSTANCE_CUSTOM.x;
	seed = INSTANCE_CUSTOM.w;
	hit_normal = normalize(MODEL_MATRIX[1].xyz);
	tangent_x = normalize(MODEL_MATRIX[0].xyz);
	tangent_z = normalize(MODEL_MATRIX[2].xyz);
	// The saved ripple mesh is horizontal in particle space. Crown and rebound
	// share the base RID but have vertical meshes and never enter the field.
	float lifetime = mix(0.15, 0.25, seed);
	bool eligible = abs(NORMAL.y) >= 0.9 && hit_age >= 0.0 && hit_age < lifetime && hit_normal.y >= 0.35;
	float diameter_m = mix(0.07, 0.14, seed);
	uv_plane = UV - vec2(0.5);
	VERTEX.xz = uv_plane * diameter_m;
	vec3 position_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	height_m = position_world.y;
	POSITION = eligible ? PROJECTION_MATRIX * VIEW_MATRIX * vec4(position_world, 1.0) : vec4(2.0, 2.0, 2.0, 1.0);
}

void fragment() {
	float radius = length(uv_plane);
	float height_relative = height_m - height_origin_m;
	if (radius >= 0.5 || abs(height_relative) > 12.0) { discard; }
	float lifetime = mix(0.15, 0.25, seed);
	float age01 = hit_age / lifetime;
	float edge = clamp(5.0 * (1.0 - 2.0 * radius), 0.0, 1.0);
	float age_envelope = min(age01 * 10.0, clamp((1.0 - age01) / 0.9, 0.0, 1.0));
	float opacity = mix(0.10, 0.25, seed) * edge * age_envelope * pow(hit_normal.y, 7.0);
	float footprint = metres_per_texel / mix(0.07, 0.14, seed);
	float aa = 1.0 - smoothstep(0.19, 0.36, footprint);
	float wave = -sin(TAU * (2.5 * radius - 3.0 * hit_age));
	vec2 slope_local = uv_plane * (wave * opacity * aa / max(radius, 0.001));
	vec3 slope = tangent_x * slope_local.x + tangent_z * slope_local.y;
	// Black clears to invalid height. Keeping data at 0.125..0.875 leaves room
	// for half-float precision and a nearest lookup that never mixes floors.
	ALBEDO = vec3(0.5 + 1.75 * slope.xz, 0.5 + height_relative / 32.0);
}
