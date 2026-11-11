shader_type spatial;
render_mode cull_back, depth_draw_never, shadows_disabled, skip_vertex_transform;

uniform vec4 snow_color : source_color = vec4(0.87, 0.92, 0.97, 0.94);
uniform vec2 near_fade = vec2(0.31, 0.81);
uniform vec2 far_fade = vec2(12.0, 24.0);
uniform float streak : hint_range(0.0, 6.0) = 1.5;
uniform float streak_taper : hint_range(0.0, 1.0) = 0.0;
uniform float grain_radius : hint_range(0.001, 0.5) = 0.025;
uniform float edge_softness : hint_range(0.0, 1.0) = 0.0;
uniform float minimum_pixel_radius : hint_range(0.0, 2.5) = 0.0;
uniform float subpixel_fade : hint_range(0.0, 2.0) = 2.0;
uniform float shutter_seconds : hint_range(0.0, 0.02) = 0.004;
instance uniform float daylight : hint_range(0.0, 1.0) = 0.75;

varying float opacity;
varying float optical_taper;
varying float longitudinal_position;

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	vec3 offset = mat3(MODELVIEW_MATRIX) * VERTEX;
	float world_radius = grain_radius * length(MODEL_MATRIX[0].xyz);
	float pixel_size = max(0.00001, -center.z * 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y));
	// Keep distant flakes visible while softening their integrated opacity below one pixel.
	float footprint = max(1.0, minimum_pixel_radius * pixel_size / max(world_radius, 0.0001));
	offset *= footprint;
	vec3 view_speed = mat3(VIEW_MATRIX) * vec3(INSTANCE_CUSTOM.x, INSTANCE_CUSTOM.y, INSTANCE_CUSTOM.w);
	vec2 projected = view_speed.xy - center.xy * view_speed.z / min(-0.2, center.z);
	float speed = length(projected);
	float exposure = mix(0.64, 1.0, fract(COLOR.r * 23.47));
	float half_blur = min(speed * shutter_seconds * 0.5, world_radius * streak);
	float stretch = half_blur / max(world_radius * footprint, 0.0001) * exposure;
	vec2 direction = projected / max(speed, 0.001);
	float longitudinal = dot(offset.xy, direction);
	vec2 parallel = direction * longitudinal;
	optical_taper = smoothstep(0.05, 1.4, stretch) * streak_taper;
	longitudinal_position = longitudinal / max(world_radius * footprint, 0.0001);
	vec2 across = (offset.xy - parallel) * (1.0 - optical_taper * 0.42);
	offset.xy = parallel * (1.0 + stretch) + across;
	VERTEX = center + offset;
	NORMAL = normalize(mat3(MODELVIEW_MATRIX) * NORMAL);
	float age = INSTANCE_CUSTOM.z;
	opacity = smoothstep(0.0, 0.10, age) * (1.0 - smoothstep(0.77, 1.0, age));
	opacity *= smoothstep(near_fade.x, near_fade.y, -center.z);
	opacity *= 1.0 - smoothstep(far_fade.x, far_fade.y, length(center));
	opacity *= inversesqrt(1.0 + stretch * 0.23);
	opacity /= pow(footprint, subpixel_fade);
}

void fragment() {
	ALBEDO = snow_color.rgb * COLOR.rgb;
	ROUGHNESS = 0.84;
	SPECULAR = 0.13;
	BACKLIGHT = ALBEDO * 0.40;
	// Fine ice forwards scattered skylight even when a crystal face receives little direct light.
	EMISSION = ALBEDO * mix(0.012, 0.62, daylight);
	float feather = 1.0 - smoothstep(0.08, 1.1, abs(longitudinal_position)) * optical_taper;
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float filter_width = max(0.06, fwidth(facing) * 0.9);
	float soft_edge = smoothstep(0.03 - filter_width, 0.58 + filter_width, facing);
	ALPHA = snow_color.a * opacity * feather * mix(1.0, soft_edge, edge_softness);
}
