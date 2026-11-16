shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;

uniform sampler2D scene_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform float energy = 0.0;
uniform vec3 strike_position;
uniform vec3 strike_forward;
uniform float sun_elevation = -1.0;
uniform float cloud_base_m = 650.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float depth_m(vec2 uv, mat4 inv_projection) {
	float z = texture(scene_depth, clamp(uv, vec2(0.0), vec2(1.0))).r;
	if (z <= 0.0000001) {
		return 1e6;
	}
	vec4 point = inv_projection * vec4(uv * 2.0 - 1.0, z, 1.0);
	return -point.z / point.w;
}

void fragment() {
	vec3 light_direction = -normalize(strike_forward);
	vec4 pixel_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 1.0, 1.0);
	vec3 world_ray = mat3(INV_VIEW_MATRIX) * normalize(pixel_view.xyz / pixel_view.w);
	vec3 camera_forward = -INV_VIEW_MATRIX[2].xyz;
	float q = clamp(dot(world_ray, light_direction) * 0.5 + 0.5, 0.0, 1.0);
	float facing = clamp(dot(camera_forward, light_direction) * 0.5 + 0.5, 0.0, 1.0);
	float distance_limit = max(0.9 * distance(CAMERA_POSITION_WORLD, strike_position), 0.1);
	float far_mask = clamp((depth_m(SCREEN_UV, INV_PROJECTION_MATRIX) - 100.0) / distance_limit, 0.0, 1.0);
	float visible = 0.0;
	vec4 clip = PROJECTION_MATRIX * vec4(mat3(VIEW_MATRIX) * light_direction, 1.0);
	if (clip.w > 0.0) {
		vec2 light_uv = clip.xy / clip.w * 0.5 + 0.5;
		vec2 edges = clamp(3.0 * (vec2(1.0) - 2.0 * abs(clamp(light_uv, vec2(0.0), vec2(1.0)) - 0.5)), vec2(0.0), vec2(1.0));
		float edge = min(edges.x, edges.y);
		if (edge > 0.0) {
			// Preserve a one-centimeter transition at the sampled occluder depth.
			visible = clamp(100.0 * (depth_m(light_uv - vec2(0.01, 0.0), INV_PROJECTION_MATRIX) - distance_limit), 0.0, 1.0);
			visible += clamp(100.0 * (depth_m(light_uv, INV_PROJECTION_MATRIX) - distance_limit), 0.0, 1.0);
			visible += clamp(100.0 * (depth_m(light_uv + vec2(0.01, 0.0), INV_PROJECTION_MATRIX) - distance_limit), 0.0, 1.0);
			visible *= edge / 3.0;
		}
	}
	float sun_gain = 1.0 + 2.0 * clamp(3.0 * sun_elevation, 0.0, 1.0);
	float radial = mix(0.9, 1.0, pow(q, 50.0));
	float cloud_mask = 1.0 - clamp((CAMERA_POSITION_WORLD.y - cloud_base_m) / 300.0, 0.0, 1.0);
	ALBEDO = vec3(0.495, 0.612833, 1.0) * (energy * q * q * facing * sun_gain * radial * cloud_mask * (far_mask + visible));
	ALPHA = 1.0;
}
