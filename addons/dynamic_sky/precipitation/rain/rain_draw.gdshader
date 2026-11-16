shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled, skip_vertex_transform, vertex_lighting;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D scene_color : hint_screen_texture, repeat_disable, filter_linear;
uniform vec4 tint : source_color = vec4(0.69, 0.75, 0.79, 0.0925);
uniform vec4 view_depth_range = vec4(0.15, 1.0, 8.9, 14.5);
uniform float surface_fade_distance : hint_range(0.01, 2.0) = 0.01;
uniform float shutter_seconds : hint_range(0.001, 0.1) = 0.024;
uniform float minimum_pixel_width : hint_range(0.5, 2.0) = 1.0;
uniform float refraction_pixels : hint_range(0.0, 2.0) = 0.82;
uniform float transmission_weight : hint_range(0.0, 1.0) = 0.64;
uniform float storm_opacity_boost : hint_range(0.0, 2.0) = 0.0;
uniform float storm_shutter_boost : hint_range(0.0, 1.0) = 0.0;
instance uniform float storm = 0.0;
// Half camera translation velocity plus one meter times its forward-vector derivative.
instance uniform vec3 camera_motion = vec3(0.0);

varying vec4 particle_random;
varying float opacity;
varying flat float transverse_padding;

float depth_gap(vec2 uv, float view_z, mat4 inverse_projection) {
	float depth = texture(scene_depth, uv).r;
	if (depth <= 0.000001) { return 100000.0; }
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		vec3 ndc = vec3(uv, depth) * 2.0 - 1.0;
	#else
		vec3 ndc = vec3(uv * 2.0 - 1.0, depth);
	#endif
	vec4 scene_view = inverse_projection * vec4(ndc, 1.0);
	return view_z - scene_view.z / max(scene_view.w, 0.000001);
}

float limit_projected_trail(vec3 center, vec3 direction, float height, mat4 projection, vec2 viewport) {
	// A perspective projection sends a point and its trail to the same screen line.
	// Solve for the greatest trail length whose far tip stays inside the angular budget.
	vec4 origin = projection * vec4(center, 1.0);
	vec4 tip_offset = projection * vec4(-direction * (1.5 * height), 0.0);
	if (origin.w <= 0.0001) { return 0.0; }
	float max_pixels = viewport.y * 0.12;
	float clip_depth_squared = origin.w * origin.w;
	vec2 homogeneous_delta = (tip_offset.xy * origin.w - origin.xy * tip_offset.w) * viewport * 0.5;
	float coefficient = length(homogeneous_delta) - max_pixels * origin.w * tip_offset.w;
	float cap = max_pixels * clip_depth_squared;
	float scale = coefficient > cap ? cap / coefficient : 1.0;
	// Protect the trailing vertices if the eye is almost parallel to the fall direction.
	if (tip_offset.w < -0.0001) {
		scale = min(scale, max(origin.w - 0.04, 0.0) / -tip_offset.w);
	}
	return height * scale;
}

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	float depth = max(-center.z, 0.10);
	float size = length(MODEL_MATRIX[0].xyz);
	float width = abs(VERTEX.x) * 2.0 * size;
	vec3 world_velocity = vec3(INSTANCE_CUSTOM.x, -INSTANCE_CUSTOM.y, INSTANCE_CUSTOM.w);
	vec3 view_velocity = mat3(VIEW_MATRIX) * (world_velocity - camera_motion);
	float speed = length(view_velocity);
	vec3 direction = speed > 0.001 ? view_velocity / speed : vec3(0.0, -1.0, 0.0);
	vec3 side = cross(-center / max(length(center), 0.0001), direction);
	side = length(side) > 0.001 ? normalize(side) : vec3(1.0, 0.0, 0.0);
	vec2 projected_side = side.xy - center.xy * side.z / min(center.z, -0.10);
	vec2 pixel_basis = vec2(PROJECTION_MATRIX[0][0] * VIEWPORT_SIZE.x, PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float pixel_width = length(projected_side * pixel_basis) * width * 0.5 / depth;
	float expansion = clamp(minimum_pixel_width / max(pixel_width, 0.01), 1.0, 12.0);
	// Leave raster support for the filtered profile at the edges of narrow quads.
	transverse_padding = 1.0 + 0.75 / max(pixel_width * expansion, 0.75);
	float exposure = shutter_seconds * (1.0 + storm * storm_shutter_boost);
	float height = min(width + size * speed * exposure, 0.90);
	height = limit_projected_trail(center, direction, height, PROJECTION_MATRIX, VIEWPORT_SIZE);
	// Source UV pivot (0.5,-0.5) makes the entire sprite trail the moving point.
	VERTEX = center + side * (UV.x - 0.5) * width * expansion * transverse_padding
		- direction * (UV.y + 0.5) * height;
	particle_random = COLOR;
	float angle = particle_random.g * TAU;
	vec2 normal_spread = vec2(cos(angle), sin(angle)) * particle_random.b * particle_random.b * 0.42;
	NORMAL = normalize(mat3(VIEW_MATRIX) * vec3(normal_spread.x, 0.50, normal_spread.y));
	float age = INSTANCE_CUSTOM.z;
	opacity = smoothstep(0.0, 0.05, age) * (1.0 - smoothstep(0.94, 1.0, age));
	opacity *= smoothstep(view_depth_range.x, view_depth_range.y, depth);
	opacity *= 1.0 - smoothstep(view_depth_range.z, view_depth_range.w, depth);
	opacity *= max(1.0 - speed / 50.0, 0.20) / expansion;
}

float filtered_cross_section(float x, float width, float footprint_variance) {
	// The Gaussian exp(-x*x/w*w) has variance w*w/2. A one-pixel box adds gradient^2/12.
	float filtered_width = sqrt(width * width + footprint_variance);
	float coordinate = x / filtered_width;
	return exp(-coordinate * coordinate) * width / filtered_width;
}

void fragment() {
	// Original analytic profile: independently seeded asymmetric head, broken shaft and tail.
	// The source's red sprite channel was measured for extent; no vendor texture is used.
	float y = UV.y;
	float bend = sin(y * 7.5 + particle_random.r * TAU) * 0.06;
	float x = (UV.x - 0.5) * transverse_padding - bend;
	float head_width = mix(0.10, 0.21, particle_random.r);
	vec2 footprint = vec2(dFdx(x), dFdy(x));
	float footprint_variance = min(dot(footprint, footprint) / 6.0, 0.16);
	float head_y = (y - 0.14) / 0.11;
	float head = filtered_cross_section(x, head_width, footprint_variance) * exp(-head_y * head_y)
		* smoothstep(0.0, 0.09, y);
	float shaft_width = mix(0.09, 0.18, 1.0 - y);
	float shaft = filtered_cross_section(x, shaft_width, footprint_variance) * smoothstep(0.05, 0.18, y)
		* (1.0 - smoothstep(0.42, 1.0, y));
	shaft *= 0.56 + 0.17 * sin(y * 27.0 + particle_random.r * 33.0);
	float mask = clamp(head + shaft, 0.0, 1.0);
	float surface = smoothstep(0.0, surface_fade_distance, depth_gap(SCREEN_UV, VERTEX.z, INV_PROJECTION_MATRIX));
	float alpha_variation = mix(0.648649, 1.351351, particle_random.a);
	ALBEDO = tint.rgb;
	ROUGHNESS = 0.18;
	SPECULAR = 0.42;
	EMISSION = vec3(0.0);
	if (transmission_weight > 0.0) {
		float amplitude = particle_random.b * particle_random.b;
		vec3 backdrop = texture(scene_color, SCREEN_UV).rgb;
		if (refraction_pixels > 0.0) {
			float angle = particle_random.g * TAU;
			vec2 shift = vec2(cos(angle), sin(angle)) * (amplitude * refraction_pixels) / VIEWPORT_SIZE;
			vec2 edge = 0.5 / VIEWPORT_SIZE;
			vec2 full_uv = clamp(SCREEN_UV + shift, edge, 1.0 - edge);
			vec2 half_uv = clamp(SCREEN_UV + shift * 0.5, edge, 1.0 - edge);
			// Do not borrow opaque foreground across a roof/object edge.
			if (depth_gap(full_uv, VERTEX.z, INV_PROJECTION_MATRIX) < 0.0) { full_uv = SCREEN_UV; }
			if (depth_gap(half_uv, VERTEX.z, INV_PROJECTION_MATRIX) < 0.0) { half_uv = SCREEN_UV; }
			backdrop = mix(texture(scene_color, full_uv).rgb, texture(scene_color, half_uv).rgb, 0.8);
		}
		EMISSION += backdrop * tint.rgb * (mix(10.0, 4.0, amplitude) * transmission_weight);
	}
	// Straight-alpha blending: Godot applies this alpha once to lit + emissive radiance.
	ALPHA = clamp(tint.a * alpha_variation * mask * opacity * surface * (1.0 + storm * storm_opacity_boost), 0.0, 1.0);
}
