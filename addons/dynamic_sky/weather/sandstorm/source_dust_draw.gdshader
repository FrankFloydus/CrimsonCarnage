shader_type spatial;
render_mode unshaded, fog_disabled, blend_mix, cull_back, depth_draw_never, shadows_disabled, skip_vertex_transform;

uniform sampler2D atlas : filter_linear_mipmap, repeat_disable;
uniform sampler2D scene_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 dust_radiance = vec3(0.50, 0.40, 0.32);
uniform float exposure = 1.0;
uniform float shelter = 0.0;
uniform float depth_fade_distance = 1.0;
uniform bool spot = false;
uniform mat4 roof_from_world = mat4(1.0);
uniform vec3 roof_half_size = vec3(0.0);

varying flat float opacity;
varying flat float particle_luminance;
varying flat vec2 tile;

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	float size = length(MODEL_MATRIX[0].xyz);
	float angle = INSTANCE_CUSTOM.x;
	float sine = sin(angle);
	float cosine = cos(angle);
	vec2 offset = mat2(vec2(cosine, sine), vec2(-sine, cosine)) * VERTEX.xy * size;
	VERTEX = center + vec3(offset, 0.0);
	float life_weight = clamp((0.5 - abs(INSTANCE_CUSTOM.y - 0.5)) * 5.0, 0.0, 1.0);
	opacity = COLOR.a * life_weight * step(0.45, length(center));
	particle_luminance = COLOR.r;
	float frame = INSTANCE_CUSTOM.z;
	tile = vec2(mod(frame, 2.0), floor(frame * 0.5));
}

float soft_intersection(vec2 screen_uv, float view_z, mat4 inverse_projection) {
	float depth = texture(scene_depth, screen_uv).r;
	if (depth < 0.000001) {
		return 1.0;
	}
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		vec3 ndc = vec3(screen_uv, depth) * 2.0 - 1.0;
	#else
		vec3 ndc = vec3(screen_uv * 2.0 - 1.0, depth);
	#endif
	vec4 scene_view = inverse_projection * vec4(ndc, 1.0);
	return clamp((view_z - scene_view.z / scene_view.w) / depth_fade_distance, 0.0, 1.0);
}

void fragment() {
	vec2 inset = 2.0 / vec2(textureSize(atlas, 0));
	vec2 atlas_uv = tile * 0.5 + mix(inset, vec2(0.5) - inset, UV);
	vec3 sample_value = texture(atlas, atlas_uv).rgb;
	// The original dust card art has a denser histogram than the generated atlas.
	float card_mask = min(1.0, sqrt(max(sample_value.g - 0.0035, 0.0)) * 1.65);
	float mask = spot ? sample_value.g : card_mask;
	vec3 night_factor = vec3(0.013, 0.021, 0.038);
	float roof_exposure = 1.0;
	if (roof_half_size.x > 0.0) {
		vec3 position = (roof_from_world * INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		vec2 side_margin = roof_half_size.xz - abs(position.xz);
		float covered_margin = min(min(side_margin.x, side_margin.y), roof_half_size.y - position.y);
		roof_exposure = 1.0 - smoothstep(0.0, 0.30, covered_margin);
	}
	ALBEDO = dust_radiance * particle_luminance * mix(night_factor, vec3(1.0), exposure);
	ALPHA = mask * opacity * (1.0 - shelter) * roof_exposure * mix(spot ? 0.30 : 0.58, 1.0, exposure)
		* soft_intersection(SCREEN_UV, VERTEX.z, INV_PROJECTION_MATRIX);
}


