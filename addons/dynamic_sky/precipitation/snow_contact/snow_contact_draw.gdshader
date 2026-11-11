shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D snowflake_atlas : source_color, repeat_disable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.82, 0.88, 0.94, 0.52);
uniform vec2 distance_fade_meters = vec2(5.0, 11.0);

varying float opacity;
varying vec2 atlas_cell;

void vertex() {
	float age = clamp(INSTANCE_CUSTOM.z, 0.0, 1.0);
	float variation = fract(INSTANCE_CUSTOM.x);
	float frame = floor(variation * 4.0);
	atlas_cell = vec2(mod(frame, 2.0), floor(frame * 0.5));
	float distance_to_eye = length((VIEW_MATRIX * MODEL_MATRIX[3]).xyz);
	opacity = (1.0 - smoothstep(0.28, 1.0, age))
		* (1.0 - smoothstep(distance_fade_meters.x, distance_fade_meters.y, distance_to_eye))
		* mix(0.6, 1.0, fract(variation * 6.73));
}

void fragment() {
	vec2 inset_uv = clamp(UV, vec2(0.025), vec2(0.975));
	vec4 flake = texture(snowflake_atlas, (atlas_cell + inset_uv) * 0.5);
	ALBEDO = tint.rgb * mix(vec3(1.0), flake.rgb, 0.42);
	ROUGHNESS = 0.91;
	SPECULAR = 0.15;
	ALPHA = tint.a * flake.a * opacity;
}
