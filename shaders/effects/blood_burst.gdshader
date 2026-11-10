shader_type spatial;
render_mode cull_disabled, depth_draw_never, skip_vertex_transform;

uniform sampler2D scene_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec4 thin_blood : source_color = vec4(0.37, 0.053, 0.060, 1.0);
uniform vec4 thick_blood : source_color = vec4(0.22, 0.022, 0.032, 1.0);
instance uniform vec4 burst_tint : source_color = vec4(1.0);
uniform float intersection_fade_distance : hint_range(0.001, 0.10, 0.001) = 0.016;

varying flat vec4 particle;
varying vec3 face_side;
varying vec3 face_axis;

float value_noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 weight = smoothstep(0.0, 1.0, fract(point));
	vec4 phase = dot(cell, vec2(37.13, 41.23)) + vec4(0.0, 37.13, 41.23, 78.36);
	vec4 samples = fract(sin(phase) * 11743.29);
	return mix(mix(samples.x, samples.y, weight.x), mix(samples.z, samples.w, weight.x), weight.y);
}

float thread_edge(float across, float width) {
	float feather = clamp(fwidth(across) * 0.52, 0.015, 0.16);
	return (1.0 - smoothstep(max(0.0, width - feather), width + feather, abs(across)))
		* min(1.0, width / feather);
}

float filament(vec2 point, float seed, float age) {
	float along = point.y * 0.5 + 0.5;
	float uneven = value_noise(vec2(along * 11.0, seed));
	float bend = sin(along * 5.6 + seed) * 0.13 + (uneven - 0.5) * 0.19;
	float ends = smoothstep(0.03, 0.25, along) * (1.0 - smoothstep(0.77, 0.99, along));
	float width = (0.034 + 0.18 * uneven * uneven) * ends;
	float cohesion = value_noise(vec2(along * 23.0 - age * 0.6, seed + 38.0));
	float gaps = smoothstep(mix(0.07, 0.42, age), mix(0.34, 0.73, age), cohesion);
	float primary = thread_edge(point.x - bend, width) * gaps;
	float fork_distance = (point.x - bend) * (fract(seed * 0.19) < 0.5 ? -1.0 : 1.0);
	float fork_shape = smoothstep(0.27, 0.47, along) * (1.0 - smoothstep(0.64, 0.86, along));
	float fork = thread_edge(fork_distance - 0.68 * (along - 0.23), 0.057 * fork_shape);
	return clamp(primary + fork * fork_shape * cohesion * 0.67, 0.0, 1.0) * ends;
}

float liquid_lobe(vec2 point, float seed, float age) {
	float along = 0.5 - point.y * 0.5;
	float folds = value_noise(vec2(along * 6.7, seed * 1.13));
	float center = 0.25 * sin(along * 5.4 + seed) + (folds - 0.5) * 0.46;
	float weight = 1.0 - smoothstep(0.23, 0.94, along);
	float width = mix(0.34, 0.78, weight) * mix(0.57, 1.21, folds);
	float boundary = abs(point.x - center) / width;
	vec2 key = vec2(seed, seed * 0.69);
	float coarse = value_noise(point * vec2(4.7, 3.2) + key);
	float streaks = value_noise(point * vec2(16.0, 8.0) - key);
	float flecks = value_noise(point * vec2(43.0, 32.0) + key * 0.58);
	float end = smoothstep(0.02, 0.22, along) * (1.0 - smoothstep(0.68, 1.0, along));
	float edge = 1.0 - smoothstep(0.50, 1.0, boundary + (coarse - 0.5) * 0.34);
	float threshold = mix(0.34, 0.62, smoothstep(0.21, 0.94, age));
	float broken = smoothstep(threshold, threshold + 0.23, 0.46 * coarse + 0.26 * streaks + 0.28 * flecks);
	return edge * end * broken * mix(0.61, 0.92, weight);
}

float droplet(vec2 point, float seed) {
	float taper = mix(1.0, 0.33, smoothstep(-0.67, 0.89, point.y));
	point.x = (point.x + 0.17 * sin(seed) * point.y * point.y) / taper;
	float ripple = value_noise(point * 3.8 + vec2(seed, seed * 0.41));
	float rim = length(point) + (ripple - 0.5) * 0.29;
	return 1.0 - smoothstep(0.58, 0.99, rim);
}

float spray_cloud(vec2 point, float seed, float age) {
	vec2 drift = vec2(seed, -seed * 0.36) + vec2(age * 0.32, age * 0.47);
	float coarse = value_noise(point * 3.2 + drift);
	float flecks = value_noise(point * 22.0 + drift * 2.7);
	float grit = value_noise(point * 43.0 - drift * 1.7);
	float radius = length(point * vec2(1.08, 0.93)) + (coarse - 0.5) * 0.31;
	float edge = 1.0 - smoothstep(0.08, 0.94, radius);
	float body = 0.062 + 0.20 * smoothstep(0.08, 0.89, coarse);
	float spray = smoothstep(0.47, 0.94, flecks * 0.68 + grit * 0.32);
	return edge * (body + spray * 0.21);
}

void vertex() {
	particle = INSTANCE_CUSTOM;
	vec3 center = MODELVIEW_MATRIX[3].xyz;
	vec3 axis = normalize(MODELVIEW_MATRIX[1].xyz + vec3(0.0, 0.000001, 0.0));
	vec3 eye = normalize(-center);
	vec3 side = cross(axis, eye);
	float facing = length(side);
	if (facing > 0.001) {
		side /= facing;
	} else {
		side = normalize(cross(axis, abs(axis.y) < 0.95 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	}
	vec3 view_up = normalize(cross(eye, side));
	vec3 shape_axis = particle.w > 1.5 ? view_up : axis;
	float extent = length(MODELVIEW_MATRIX[1].xyz);
	float width = length(MODELVIEW_MATRIX[0].xyz);
	VERTEX = center + side * VERTEX.x * width + shape_axis * VERTEX.y * extent;
	face_side = side;
	face_axis = view_up;
	NORMAL = eye;
}

void fragment() {
	vec2 point = UV * 2.0 - 1.0;
	float coverage;
	float thickness;
	if (particle.w < 0.5) {
		coverage = particle.w > 0.1
			? liquid_lobe(point, particle.y, particle.x)
			: filament(point, particle.y, particle.x) * 0.72;
		thickness = 0.80;
	} else if (particle.w < 1.5) {
		coverage = droplet(point, particle.y) * 0.86;
		thickness = 0.61 + 0.25 * coverage;
		NORMAL = normalize(NORMAL + face_side * point.x * 0.31 - face_axis * point.y * 0.29);
	} else {
		coverage = spray_cloud(point, particle.y, particle.x);
		thickness = 0.18;
	}

	float alpha = coverage * particle.z * burst_tint.a;
	if (alpha < 0.003) {
		discard;
	}
	float depth = texture(scene_depth, SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 surface = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	float separation = VERTEX.z - surface.z / max(surface.w, 0.000001);
	float soft_depth = intersection_fade_distance * (particle.w > 1.5 ? 3.8 : 1.0);
	ALPHA = alpha * smoothstep(0.0, soft_depth, separation);
	ALBEDO = mix(thin_blood.rgb, thick_blood.rgb, thickness) * burst_tint.rgb;
	ROUGHNESS = particle.w > 1.5 ? 0.86 : 0.52;
	SPECULAR = particle.w > 1.5 ? 0.0 : 0.08;
}
