shader_type spatial;
render_mode unshaded, fog_disabled, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled;

const float BLIZZARD_MIST_RANGE = 300.0;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler3D density_noise : repeat_enable, filter_linear;
uniform vec3 fog_radiance = vec3(0.0);
uniform vec3 observer_world = vec3(0.0);
uniform vec3 fog_travel = vec3(0.0);
uniform float weather_amount = 0.0;
uniform float trace_distance = 18.0;
uniform float sample_step = 1.2;
uniform float noise_scale = 20.0;
uniform float extinction_per_meter = 0.12;
uniform float density_variation = 0.83;
uniform float shelter = 0.0;
// Extinction, scale height, and ground elevation in meters.
uniform vec3 blizzard_mist_layer = vec3(0.0, 3.3, 0.0);
uniform vec3 blizzard_mist_radiance = vec3(0.0);
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
uniform mat4 roof_from_world = mat4(1.0);
uniform vec3 roof_half_size = vec3(0.0);
uniform bool replace_scalar_shelter = false;
#endif

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
vec2 ray_roof_interval(vec3 world_origin, vec3 world_direction) {
	vec3 p = (roof_from_world * vec4(world_origin, 1.0)).xyz;
	vec3 d = mat3(roof_from_world) * world_direction;
	vec2 safe_direction = mix(vec2(-1.0), vec2(1.0), step(vec2(0.0), d.xz)) * max(abs(d.xz), vec2(0.000001));
	vec2 t0 = (-roof_half_size.xz - p.xz) / safe_direction;
	vec2 t1 = (roof_half_size.xz - p.xz) / safe_direction;
	vec2 near_planes = min(t0, t1);
	vec2 far_planes = max(t0, t1);
	vec2 interval = vec2(max(near_planes.x, near_planes.y), min(far_planes.x, far_planes.y));
	if (d.y > 0.000001) {
		interval.y = min(interval.y, (roof_half_size.y - p.y) / d.y);
	} else if (d.y < -0.000001) {
		interval.x = max(interval.x, (roof_half_size.y - p.y) / d.y);
	} else if (p.y > roof_half_size.y) {
		interval.y = interval.x;
	}
	return interval;
}
#endif

// Integrate a low layer in world space against both opaque receivers and open sky.
vec4 integrate_blizzard_mist(vec3 origin_world, vec3 direction, float scene_distance,
		vec2 roof_interval, float scalar_shelter, float cell_size) {
	float height_scale = max(blizzard_mist_layer.y, 0.1);
	float height = origin_world.y - blizzard_mist_layer.z;
	float end_distance = min(scene_distance, BLIZZARD_MIST_RANGE);
	if (direction.y < -0.0001) {
		end_distance = min(end_distance, max((height + 0.75) / -direction.y, 0.0));
	} else if (direction.y > 0.0001) {
		end_distance = min(end_distance, max((height_scale * 5.0 - height) / direction.y, 0.0));
	}
	vec3 advected = origin_world - fog_travel;
	vec3 pocket_scale = vec3(cell_size * 8.0, cell_size, cell_size * 4.0);
	vec3 scatter = vec3(0.0);
	float transmission = 1.0;
	float begin = 0.0;
	const int steps = 20;
	for (int index = 1; index <= steps; index++) {
		float fraction = float(index) / float(steps);
		float end = fraction * fraction * end_distance;
		float length_exposed = (end - begin) - max(min(end, roof_interval.y) - max(begin, roof_interval.x), 0.0);
		float center = (begin + end) * 0.5;
		begin = end;
		if (length_exposed <= 0.0) {
			continue;
		}
		float elevation = height + direction.y * center;
		vec3 uvw = (advected + direction * center) / pocket_scale;
		float broad = textureLod(density_noise, uvw, 0.0).r;
		float detail = textureLod(density_noise, uvw * vec3(2.0, 4.0, 2.0) + vec3(0.31, 0.63, 0.17), 0.0).g;
		float pocket = smoothstep(0.24, 0.74, broad * 0.78 + detail * 0.22);
		float height_offset = (broad - 0.5) * 1.3 * density_variation;
		float layer = exp(-max(elevation + height_offset, 0.0) / height_scale);
		layer *= smoothstep(-0.75, 0.18, elevation);
		layer *= 1.0 - smoothstep(4.0, 5.0, elevation / height_scale);
		float gust = mix(0.54, 1.65, smoothstep(0.26, 0.74, detail));
		float gust_weight = 1.0 - smoothstep(22.0, 85.0, center);
		float local_density = mix(0.45, 1.55, pocket) * mix(1.0, gust, gust_weight);
		float exposed = 1.0 - scalar_shelter * (1.0 - smoothstep(2.0, 13.0, center));
		// The short wind mist already covers the first few meters of the ray.
		float distance_weight = smoothstep(6.0, 16.0, center);
		float optical_depth = blizzard_mist_layer.x * layer * exposed * distance_weight * length_exposed;
		optical_depth *= mix(1.0, local_density, density_variation);
		float opacity = 1.0 - exp(-optical_depth);
		scatter += transmission * opacity * mix(1.0, mix(0.85, 1.15, pocket), density_variation)
			* blizzard_mist_radiance;
		transmission *= 1.0 - opacity;
		if (transmission < 0.003) {
			break;
		}
	}
	return vec4(scatter, 1.0 - transmission);
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
	vec4 hit_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 view_ray = ray_view.xyz / ray_view.w;
	vec3 view_hit = hit_view.xyz / hit_view.w;
	bool orthographic = abs(PROJECTION_MATRIX[3][3]) > 0.5;
	vec3 direction = orthographic ? -INV_VIEW_MATRIX[2].xyz : normalize(mat3(INV_VIEW_MATRIX) * view_ray);
	vec3 view_offset = orthographic ? mat3(INV_VIEW_MATRIX) * vec3(view_ray.xy, 0.0) : vec3(0.0);
	float hit_distance = orthographic ? -view_hit.z : length(view_hit);
	float distance_limit = scene_z > 0.000001 ? min(trace_distance, hit_distance) : trace_distance;
	float step_length = max(sample_step, distance_limit / 48.0);
	float cell_size = max(noise_scale * 0.625, 0.1);
	vec3 origin = observer_world * 0.6 - fog_travel + view_offset;
	float scalar_shelter = shelter;
	vec2 full_roof_interval = vec2(0.0);
	#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
	vec2 covered_interval = vec2(0.0);
	if (roof_half_size.x > 0.0) {
		full_roof_interval = ray_roof_interval(observer_world + view_offset, direction);
		covered_interval = full_roof_interval;
		covered_interval.x = max(covered_interval.x, step_length);
		covered_interval.y = min(covered_interval.y, distance_limit);
	}
	bool has_covered_path = covered_interval.x < covered_interval.y;
	scalar_shelter = replace_scalar_shelter ? 0.0 : shelter;
	#endif
	float integrated_density = 0.0;
	for (int index = 1; index <= 48; index++) {
		float ray_distance = float(index) * step_length;
		if (ray_distance >= distance_limit) {
			break;
		}
		float exposed_length = min(step_length, distance_limit - ray_distance);
		#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
		if (has_covered_path) {
			// Integrate the exact uncovered fraction of an interval that straddles the eave.
			float blocked = min(ray_distance + exposed_length, covered_interval.y) - max(ray_distance, covered_interval.x);
			exposed_length -= max(0.0, blocked);
			if (exposed_length <= 0.0) {
				continue;
			}
		}
		#endif
		vec3 point = origin + direction * ray_distance;
		float field = textureLod(density_noise, point / cell_size, 0.0).g;
		float density = mix(0.5, clamp(0.5 + (field - 0.49) * 1.1, 0.0, 1.0), density_variation);
		float exposed = 1.0 - scalar_shelter * (1.0 - smoothstep(2.0, 13.0, ray_distance));
		integrated_density += density * exposed * exposed_length;
	}

	float local_opacity = clamp((integrated_density / 16.0) * (extinction_per_meter / 0.12), 0.0, 1.0);
	vec3 local_scattering = fog_radiance * (1.3 * weather_amount * local_opacity);
	vec4 blizzard_mist = vec4(0.0);
	if (blizzard_mist_layer.x > 0.0) {
		float depth = scene_z > 0.000001 ? hit_distance : BLIZZARD_MIST_RANGE;
		blizzard_mist = integrate_blizzard_mist(observer_world + view_offset, direction, depth,
			full_roof_interval, scalar_shelter, cell_size);
	}
	// Premultiplied blending preserves the additive short mist and attenuates the background by the long layer.
	ALBEDO = local_scattering + blizzard_mist.rgb;
	ALPHA = blizzard_mist.a;
}
