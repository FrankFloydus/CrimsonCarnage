shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D scene_color : hint_screen_texture, repeat_disable, filter_linear;
uniform vec4 tint : source_color = vec4(0.63, 0.69, 0.75, 0.29);
// Near fade begins and ends at x/y, far fade begins and ends at z/w, in meters.
uniform vec4 view_depth_range = vec4(0.9, 2.5, 9.0, 14.0);
uniform float surface_fade_distance : hint_range(0.01, 2.0) = 0.16;
uniform float shutter_seconds : hint_range(0.01, 0.1) = 0.028;
uniform float minimum_pixel_width : hint_range(0.5, 2.0) = 1.2;
uniform float refraction_pixels : hint_range(0.0, 2.0) = 0.85;
uniform float transmission_weight : hint_range(0.0, 1.0) = 0.67;
uniform float storm_opacity_boost : hint_range(0.0, 2.0) = 0.2;
uniform float storm_shutter_boost : hint_range(0.0, 1.0) = 0.1;
instance uniform float storm = 0.0;

varying float phase;
varying float opacity;
varying vec2 screen_across;

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	float depth = max(-center.z, 0.1);
	float scale = length(MODEL_MATRIX[0].xyz);
	vec2 offset = VERTEX.xy * scale;
	vec3 velocity = vec3(INSTANCE_CUSTOM.x, -INSTANCE_CUSTOM.y, INSTANCE_CUSTOM.w);
	vec3 view_velocity = mat3(VIEW_MATRIX) * velocity;
	vec2 projected_velocity = view_velocity.xy - center.xy * view_velocity.z / min(center.z, -0.2);
	float speed = length(projected_velocity);
	vec2 along = speed > 0.001 ? projected_velocity / speed : vec2(0.0, -1.0);
	vec2 across = vec2(-along.y, along.x);
	phase = fract(scale * 31.27);
	float shutter = shutter_seconds * (1.0 + storm * storm_shutter_boost);
	float exposure = clamp(speed * shutter * mix(0.83, 1.13, phase), 0.024, 0.37);
	offset.y *= exposure;
	// Give subpixel streaks enough coverage to rasterize, preserving their opacity budget.
	float pixels = abs(offset.x) * VIEWPORT_SIZE.x * PROJECTION_MATRIX[0][0] / depth;
	float pixel_expansion = clamp(minimum_pixel_width / max(pixels, 0.01), 1.0, 7.0);
	offset.x *= pixel_expansion;
	VERTEX = center + vec3(across * offset.x + along * offset.y, 0.0);
	screen_across = vec2(across.x, -across.y);
	float age = INSTANCE_CUSTOM.z;
	opacity = smoothstep(0.015, 0.13, age) * (1.0 - smoothstep(0.76, 1.0, age));
	opacity *= smoothstep(view_depth_range.x, view_depth_range.y, depth);
	opacity *= 1.0 - smoothstep(view_depth_range.z, view_depth_range.w, depth);
	opacity *= min(1.0, sqrt(0.16 / exposure)) * mix(0.53, 1.0, phase) / pixel_expansion;
}

void fragment() {
	vec2 point = UV * 2.0 - 1.0;
	float cross_section = 1.0 - smoothstep(0.0, 1.0, abs(point.x));
	float taper = 1.0 - smoothstep(0.09, 1.0, abs(point.y + 0.09));
	float pearl = exp(-abs(point.y + 0.27) * 13.0);
	float glint = smoothstep(0.72, 1.0, phase) * pearl;
	float profile = cross_section * (taper * 0.86 + glint * 0.18);

	float opaque_depth = texture(scene_depth, SCREEN_UV).r;
	float surface_fade = 1.0;
	if (opaque_depth > 0.000001) {
		#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
			vec3 ndc = vec3(SCREEN_UV, opaque_depth) * 2.0 - 1.0;
		#else
			vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, opaque_depth);
		#endif
		vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		surface_fade = smoothstep(0.0, surface_fade_distance, VERTEX.z - scene_view.z / scene_view.w);
	}

	vec3 color = tint.rgb;
	if (transmission_weight > 0.0) {
		vec2 displacement = screen_across * point.x * refraction_pixels / VIEWPORT_SIZE;
		vec3 refracted = texture(scene_color, SCREEN_UV + displacement).rgb;
		vec3 scatter = mix(tint.rgb, vec3(0.87, 0.92, 0.97), glint * 0.48);
		color = mix(scatter, refracted, transmission_weight * (1.0 - glint * 0.51));
	}
	ALBEDO = color;
	ALPHA = tint.a * profile * opacity * surface_fade * (1.0 + storm * storm_opacity_boost);
}
