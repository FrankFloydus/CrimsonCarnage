shader_type spatial;
render_mode unshaded, fog_disabled, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler3D density_noise : repeat_enable, filter_linear;
uniform vec3 fog_radiance = vec3(0.0);
uniform vec3 observer_world = vec3(0.0);
uniform vec2 wind_travel = vec2(0.0);
uniform float weather_amount = 0.0;
uniform float trace_distance = 18.0;
uniform float sample_step = 1.2;
uniform float noise_scale = 20.0;
uniform float extinction_per_meter = 0.12;
uniform float density_variation = 0.83;
uniform float shelter = 0.0;

void vertex() {
	// Reversed-Z fullscreen triangle coverage, independent of the mesh's camera distance.
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	float scene_z = texture(scene_depth, SCREEN_UV).r;
	vec2 screen = SCREEN_UV * 2.0 - 1.0;
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		vec3 ndc = vec3(screen, scene_z * 2.0 - 1.0);
		float far_z = 0.99999;
	#else
		vec3 ndc = vec3(screen, scene_z);
		float far_z = 0.00001;
	#endif
	vec4 ray_view = INV_PROJECTION_MATRIX * vec4(screen, far_z, 1.0);
	vec3 direction = normalize(mat3(INV_VIEW_MATRIX) * (ray_view.xyz / ray_view.w));
	vec4 hit_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	float scene_distance = scene_z > 0.000001 ? length(hit_view.xyz / hit_view.w) : trace_distance;
	float distance_limit = min(trace_distance, scene_distance);
	float step_length = max(sample_step, distance_limit / 48.0);
	float integrated_density = 0.0;
	for (int index = 0; index < 48; index++) {
		float sample_start = float(index) * step_length;
		if (sample_start >= distance_limit) {
			break;
		}
		float sample_length = min(step_length, distance_limit - sample_start);
		float ray_distance = sample_start + 0.5 * sample_length;
		vec3 world = observer_world + direction * ray_distance;
		vec3 coordinates = world / max(noise_scale, 0.1);
		coordinates.xz -= wind_travel / max(noise_scale, 0.1);
		float broad = textureLod(density_noise, coordinates, 0.0).r;
		float fine = textureLod(density_noise, coordinates * 2.1 + vec3(0.19, 0.73, 0.42), 0.0).g;
		float pocket = smoothstep(0.22, 0.78, broad * 0.75 + fine * 0.25);
		float density = mix(0.48, mix(0.08, 1.18, pocket), density_variation);
		float exposed = 1.0 - shelter * (1.0 - smoothstep(2.0, 13.0, ray_distance));
		integrated_density += density * exposed * sample_length;
	}
	ALBEDO = fog_radiance;
	ALPHA = 1.0 - exp(-integrated_density * weather_amount * extinction_per_meter);
}
