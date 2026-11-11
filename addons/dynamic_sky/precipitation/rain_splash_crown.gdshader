shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;

uniform sampler2D splash_atlas : source_color, repeat_disable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.78, 0.82, 0.86, 0.38);
uniform float visible_fraction : hint_range(0.0, 1.0) = 0.36;

varying float progress;
varying float opacity;

vec4 sample_frame(float frame, vec2 uv) {
	vec2 cell = vec2(mod(frame, 2.0), floor(frame * 0.5));
	vec4 splash = texture(splash_atlas, (cell + uv) * 0.5);
	return vec4(splash.rgb * splash.a, splash.a);
}

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	vec3 surface_up = normalize(mat3(VIEW_MATRIX) * MODEL_MATRIX[1].xyz);
	vec3 across = cross(surface_up, normalize(-center));
	if (length(across) < 0.005) {
		across = mat3(VIEW_MATRIX) * MODEL_MATRIX[0].xyz;
	}
	float variation = INSTANCE_CUSTOM.w;
	float size = mix(0.66, 1.22, variation);
	vec2 quad = VERTEX.xy;
	float base_offset = abs(quad.y) * 0.28;
	VERTEX = center + normalize(across) * quad.x * size;
	VERTEX += surface_up * (quad.y + base_offset) * size;
	progress = clamp(INSTANCE_CUSTOM.z / 0.42, 0.0, 1.0);
	opacity = (1.0 - step(visible_fraction, fract(variation * 13.47)));
	opacity *= smoothstep(0.0, 0.15, progress) * (1.0 - smoothstep(0.46, 1.0, progress));
	opacity *= 1.0 - smoothstep(7.0, 13.0, length(center));
}

void fragment() {
	float atlas_frame = progress * 3.0;
	float first_frame = floor(atlas_frame);
	vec4 first = sample_frame(first_frame, UV);
	vec4 second = sample_frame(min(first_frame + 1.0, 3.0), UV);
	vec4 splash = mix(first, second, fract(atlas_frame));
	ALBEDO = tint.rgb * splash.rgb / max(splash.a, 0.001);
	ALPHA = tint.a * splash.a * opacity;
}
