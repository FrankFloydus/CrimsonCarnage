#ifndef DYNAMIC_SKY_RAIN_SPLASH_LIGHT
#define DYNAMIC_SKY_RAIN_SPLASH_LIGHT

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D receiver_color : hint_screen_texture, repeat_disable, filter_linear;

varying flat vec3 receiver_view;

vec3 splash_receiver_radiance(vec3 view_hit, mat4 projection, mat4 inverse_projection, vec2 viewport) {
	vec4 clip = projection * vec4(view_hit, 1.0);
	if (clip.w <= 0.001) { return vec3(0.0); }
	vec2 uv = (clip.xy / clip.w) * 0.5 + 0.5;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) { return vec3(0.0); }
	float depth = texture(scene_depth, uv).r;
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		vec3 ndc = vec3(uv, depth) * 2.0 - 1.0;
	#else
		vec3 ndc = vec3(uv * 2.0 - 1.0, depth);
	#endif
	vec4 resolved = inverse_projection * vec4(ndc, 1.0);
	float gap = abs(view_hit.z - resolved.z / max(resolved.w, 0.00001));
	// Fade the reflected fill when another receiver lies behind or in front of the hit.
	float attach = 1.0 - smoothstep(0.06, 0.25, gap);
	vec2 edge = 0.5 / viewport;
	vec3 incident = texture(receiver_color, clamp(uv, edge, 1.0 - edge)).rgb;
	return min(incident * 8.0, vec3(0.85)) * attach;
}

#endif
