shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert_wrap, specular_disabled, skip_vertex_transform;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec4 tint : source_color = vec4(0.68, 0.72, 0.75, 0.10);
instance uniform float impact_lifetime = 0.26;

varying float opacity;
varying float seed;
varying float age;

float spray_noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 weight = fract(point);
	weight = weight * weight * (3.0 - 2.0 * weight);
	vec4 keys = dot(cell, vec2(37.0, 113.0)) + vec4(0.0, 37.0, 113.0, 150.0);
	vec4 corner = fract(sin(keys) * 43758.55);
	return mix(mix(corner.x, corner.y, weight.x), mix(corner.z, corner.w, weight.x), weight.y);
}

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	age = INSTANCE_CUSTOM.z;
	seed = INSTANCE_CUSTOM.w;
	float seconds = age * impact_lifetime;
	vec3 surface_up = normalize(MODEL_MATRIX[1].xyz);
	vec3 drift = vec3(INSTANCE_CUSTOM.x, 0.0, INSTANCE_CUSTOM.y);
	vec3 rise = surface_up * max(0.0, seconds * mix(0.22, 0.38, seed) - seconds * seconds * 0.7);
	center += mat3(VIEW_MATRIX) * (drift * seconds + rise);
	vec2 offset = VERTEX.xy * mix(0.65, 1.12, seed) * (0.75 + age * 0.4);
	VERTEX = center + vec3(offset, 0.0);
	NORMAL = vec3(0.0, 0.0, 1.0);
	float distance_to_eye = length(center);
	opacity = smoothstep(0.0, 0.12, age) * (1.0 - smoothstep(0.18, 0.95, age));
	opacity *= smoothstep(1.6, 3.4, distance_to_eye);
	opacity *= 1.0 - smoothstep(7.0, 15.0, distance_to_eye);
}

void fragment() {
	vec2 point = UV * 2.0 - 1.0;
	float radius = length(point);
	float low = spray_noise(point * vec2(3.0, 5.0) + vec2(seed * 18.0 - age * 2.3, seed * 37.0));
	float high = spray_noise(point * vec2(8.0, 11.0) - vec2(seed * 31.0 + age * 3.4, seed * 19.0));
	float plume = smoothstep(0.14, 0.91, low * 0.66 + high * 0.34);
	float profile = plume * (1.0 - smoothstep(0.13, 1.0, radius));
	float depth = texture(scene_depth, SCREEN_UV).r;
	float surface_fade = 1.0;
	if (depth > 0.000001) {
		#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
			vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
		#else
			vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
		#endif
		vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		surface_fade = smoothstep(0.0, 0.035, VERTEX.z - scene_view.z / scene_view.w);
	}
	ALBEDO = tint.rgb;
	ROUGHNESS = 1.0;
	ALPHA = tint.a * profile * opacity * surface_fade;
}
