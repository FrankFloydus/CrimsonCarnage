shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec4 tint : source_color = vec4(0.70, 0.78, 0.85, 0.50);
uniform float visible_fraction : hint_range(0.0, 1.0) = 0.38;
uniform vec2 launch_speed_range = vec2(0.48, 0.99);
uniform vec2 outward_speed_range = vec2(0.14, 0.48);

varying float opacity;

void vertex() {
	float elapsed = INSTANCE_CUSTOM.x;
	float seed = INSTANCE_CUSTOM.w;
	float azimuth = TAU * fract(seed * 17.51);
	float up_speed = mix(launch_speed_range.x, launch_speed_range.y, fract(seed * 27.13));
	float outward_speed = mix(outward_speed_range.x, outward_speed_range.y, fract(seed * 41.17));
	vec3 surface_up = normalize(MODEL_MATRIX[1].xyz);
	vec3 outward = cos(azimuth) * MODEL_MATRIX[0].xyz + sin(azimuth) * MODEL_MATRIX[2].xyz;
	vec3 displacement = (surface_up * up_speed + outward * outward_speed) * elapsed;
	displacement.y -= 4.905 * elapsed * elapsed;
	vec3 world_position = MODEL_MATRIX[3].xyz + displacement;
	vec3 center = (VIEW_MATRIX * vec4(world_position, 1.0)).xyz;
	float distance_to_eye = length(center);
	float height = dot(displacement, surface_up);
	float size = mix(0.55, 1.18, fract(seed * 57.41));
	VERTEX = center + vec3(VERTEX.xy * size, 0.0);
	opacity = (1.0 - step(visible_fraction, fract(seed * 9.59))) * smoothstep(0.0, 0.006, height);
	opacity *= smoothstep(0.25, 0.55, distance_to_eye);
	opacity *= 1.0 - smoothstep(4.0, 9.0, distance_to_eye);
}

void fragment() {
	float profile = 1.0 - smoothstep(0.15, 1.0, length(UV * 2.0 - 1.0));
	float depth = texture(scene_depth, SCREEN_UV).r;
	float surface_fade = 1.0;
	if (depth > 0.000001) {
		#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
			vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
		#else
			vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
		#endif
		vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		surface_fade = smoothstep(0.0, 0.028, VERTEX.z - scene_view.z / scene_view.w);
	}
	ALBEDO = tint.rgb;
	ALPHA = tint.a * profile * opacity * surface_fade;
}
