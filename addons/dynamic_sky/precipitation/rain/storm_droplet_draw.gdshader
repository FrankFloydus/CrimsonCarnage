shader_type spatial;
render_mode cull_disabled, depth_draw_never, diffuse_lambert_wrap, skip_vertex_transform;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform float droplet_index : hint_range(0.0, 2.0, 1.0) = 0.0;
uniform vec4 tint : source_color = vec4(0.77, 0.82, 0.86, 0.57);
instance uniform float impact_lifetime = 0.26;

varying float opacity;

void vertex() {
	float seed = fract(INSTANCE_CUSTOM.w * 17.29 + droplet_index * 0.381966);
	float variation = fract(seed * 31.17 + 0.263);
	float seconds = INSTANCE_CUSTOM.z * impact_lifetime;
	float flight_seconds = mix(0.11, 0.185, variation);
	float angle = seed * TAU;
	vec3 normal = normalize(MODEL_MATRIX[1].xyz);
	float launch_speed = flight_seconds * 4.905 * normal.y;
	vec3 tangent = normalize(MODEL_MATRIX[0].xyz);
	vec3 bitangent = normalize(MODEL_MATRIX[2].xyz);
	vec3 horizontal = (tangent * cos(angle) + bitangent * sin(angle)) * mix(0.07, 0.19, variation);
	vec3 wind = vec3(INSTANCE_CUSTOM.x, 0.0, INSTANCE_CUSTOM.y);
	horizontal += (wind - normal * dot(wind, normal)) * 0.20;
	vec3 position = MODEL_MATRIX[3].xyz + horizontal * seconds;
	position += normal * launch_speed * seconds;
	position.y -= 4.905 * seconds * seconds;
	vec3 center = (VIEW_MATRIX * vec4(position, 1.0)).xyz;
	float size = mix(0.56, 1.0, seed);
	VERTEX = center + vec3(VERTEX.xy * size, 0.0);
	NORMAL = vec3(0.0, 0.0, 1.0);
	opacity = smoothstep(0.0, 0.009, seconds) * (1.0 - smoothstep(flight_seconds * 0.75, flight_seconds, seconds));
	opacity *= smoothstep(1.0, 2.3, length(center)) * (1.0 - smoothstep(6.0, 12.0, length(center)));
}

void fragment() {
	vec2 point = UV * 2.0 - 1.0;
	float profile = exp(-dot(point, point) * 3.8) * (1.0 - smoothstep(0.65, 1.0, length(point)));
	float opaque_depth = texture(scene_depth, SCREEN_UV).r;
	float surface_fade = 1.0;
	if (opaque_depth > 0.000001) {
		#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
			vec3 ndc = vec3(SCREEN_UV, opaque_depth) * 2.0 - 1.0;
		#else
			vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, opaque_depth);
		#endif
		vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		surface_fade = smoothstep(0.0, 0.008, VERTEX.z - scene_view.z / scene_view.w);
	}
	ALBEDO = tint.rgb;
	NORMAL = normalize(vec3(point * 0.55, 0.85));
	ROUGHNESS = 0.18;
	SPECULAR = 0.64;
	ALPHA = tint.a * profile * opacity * surface_fade;
}
