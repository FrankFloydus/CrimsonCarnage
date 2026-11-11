#include "res://addons/dynamic_sky/rendering/cloud_modes/dynamic_2d_cloud_field.gdshaderinc"

group_uniforms Clouds_Static;
// Angular dome with three directional relief samples in RGB and cloud opacity in alpha.
// Zenith is the center and the horizon is the rim of the inscribed disk.
uniform sampler2D static_cloud_dome_map : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform float static_cloud_yaw_degrees : hint_range(-180.0, 180.0, 1.0) = 0.0;
uniform float static_cloud_opacity : hint_range(0.0, 1.0, 0.01) = 1.0;
group_uniforms;

vec3 layered_cloud_lighting(
	vec3 direction, vec3 sky_color, vec3 sun_dir, vec3 moon_dir, float lunar_illumination,
	float altitude, float distance, float density, float directional_light, float ambient_scale
) {
	float daylight = smoothstep(-0.10, 0.15, sun_dir.y);
	float sun_visible = smoothstep(-0.08, 0.06, sun_dir.y);
	vec3 solar = transmission_to_space(sun_dir.y, altitude) * sun_visible;
	solar *= exp(-dust_density * vec3(1.49, 1.72, 2.01));
	vec3 lunar = vec3(0.051, 0.088, 0.155) * lunar_illumination
		* (1.0 - sun_visible) * smoothstep(0.0, 0.25, moon_dir.y);
	vec3 ambient = mix(vec3(0.003, 0.006, 0.012), cloud_shadow * 0.73, daylight);
	vec3 direct = cloud_light * (solar + lunar);
	if (sky_color_mode == 1) {
		ambient = simple_cloud_ambient_color(sun_dir, moon_dir, lunar_illumination);
		direct = cloud_light * simple_cloud_direct_color(sun_dir, moon_dir, lunar_illumination);
	}
	vec3 light_dir = sun_visible > 0.025 ? sun_dir : moon_dir;
	float forward_scatter = pow(clamp(dot(direction, light_dir), 0.0, 1.0), 20.0);
	float thin_edge = (1.0 - density) * forward_scatter * 0.29;
	vec3 radiance = ambient * ambient_scale + direct * (directional_light + thin_edge);
	radiance += cloud_flash_radiance(
		direction * distance, radiance, density, flash_in_direction(direction)
	);
	float haze = 1.0 - exp(-distance * (0.009 + 0.041 * dust_density));
	return mix(radiance, sky_color, haze);
}

vec4 shade_dynamic_2d_cloud_sheet(
	vec3 direction, vec3 sky_color, vec3 sun_dir, vec3 moon_dir, float lunar_illumination,
	vec2 displacement, float coverage, float altitude, float distance, bool upper_sheet
) {
	if (distance < 0.0 || distance >= CLOUD_MAX_TRACE_DISTANCE_KM) {
		return vec4(0.0);
	}
	vec2 point = cloud_observer_position_km.xz + direction.xz * distance;
	vec2 coordinates = dynamic_2d_cloud_coordinates(point, displacement, upper_sheet);
	float mass = dynamic_2d_cloud_density(coordinates);
	float density = dynamic_2d_cloud_thickness(mass, coverage, upper_sheet);

	vec3 light_dir = sun_dir.y > -0.04 ? sun_dir : moon_dir;
	float sunward = dynamic_2d_cloud_density(coordinates + light_dir.xz * 0.027);
	float directional_light = clamp(
		0.69 + (mass - sunward) * 1.7 - density * (upper_sheet ? 0.16 : 0.32), 0.12, 1.0
	);
	vec3 radiance = layered_cloud_lighting(
		direction, sky_color, sun_dir, moon_dir, lunar_illumination, altitude, distance,
		density, directional_light, 1.0
	);
	float horizon_fade = 1.0 - smoothstep(
		CLOUD_MAX_TRACE_DISTANCE_KM * 0.72, CLOUD_MAX_TRACE_DISTANCE_KM, distance
	);
	float alpha = density * horizon_fade * dynamic_2d_opacity;
	alpha *= upper_sheet ? dynamic_2d_upper_opacity : 1.0;
	return vec4(radiance * alpha, alpha);
}

// Two advected maps projected onto separate curved sheets in world space.
vec4 shade_dynamic_2d_clouds(
	vec3 direction, vec3 sky_color, vec3 sun_dir, vec3 moon_dir, vec2 displacement,
	float coverage, float lunar_illumination
) {
	if (coverage <= 0.0 || dynamic_2d_opacity <= 0.0) {
		return vec4(0.0);
	}
	float base_distance = cloud_layer_distance(direction, dynamic_2d_base_km);
	vec4 base = shade_dynamic_2d_cloud_sheet(
		direction, sky_color, sun_dir, moon_dir, lunar_illumination, displacement, coverage,
		dynamic_2d_base_km, base_distance, false
	);
	if (dynamic_2d_upper_opacity <= 0.0) {
		return base;
	}
	float upper_altitude = dynamic_2d_base_km + dynamic_2d_upper_separation_km;
	float upper_distance = cloud_layer_distance(direction, upper_altitude);
	vec4 upper = shade_dynamic_2d_cloud_sheet(
		direction, sky_color, sun_dir, moon_dir, lunar_illumination, displacement, coverage,
		upper_altitude, upper_distance, true
	);
	if (upper_distance > 0.0 && (base_distance <= 0.0 || upper_distance < base_distance)) {
		return upper + base * (1.0 - upper.a);
	}
	return base + upper * (1.0 - base.a);
}

mat2 static_cloud_yaw() {
	float yaw = radians(-static_cloud_yaw_degrees);
	float sine = sin(yaw);
	float cosine = cos(yaw);
	return mat2(vec2(cosine, -sine), vec2(sine, cosine));
}

vec2 static_cloud_dome_uv(vec3 direction, mat2 yaw) {
	vec2 horizontal = yaw * direction.xz;
	float radius = acos(clamp(direction.y, 0.0, 1.0)) / (0.5 * PI);
	float scaled_radius = pow(radius, 1.0 / max(static_cloud_scale, 0.20));
	return vec2(0.5) + 0.5 * horizontal * (scaled_radius / max(length(horizontal), 0.0001));
}

vec3 static_cloud_light_weights(vec3 light_dir, mat2 yaw) {
	vec2 horizontal = yaw * light_dir.xz;
	if (length(horizontal) < 0.001) {
		return vec3(1.0 / 3.0);
	}
	float azimuth = fract(atan(horizontal.y, horizontal.x) / TAU + 1.0);
	vec3 channels = vec3(0.0, 1.0 / 3.0, 2.0 / 3.0);
	vec3 angular_distance = abs(fract(vec3(azimuth) - channels + 0.5) - 0.5);
	vec3 directional_weights = max(vec3(1.0) - angular_distance * 3.0, vec3(0.0));
	float strength = smoothstep(-0.02, 0.15, light_dir.y)
		* smoothstep(0.10, 0.48, length(horizontal));
	return mix(vec3(1.0 / 3.0), directional_weights, strength);
}

// A baked cloud layout in sky directions. Only rotation, coverage, and illumination change it.
vec4 shade_static_cloud_layer(
	vec3 direction, vec3 sky_color, vec3 sun_dir, vec3 moon_dir, float coverage,
	float lunar_illumination
) {
	if (
		coverage <= 0.0 || static_cloud_opacity <= 0.0 || direction.y <= 0.0
		|| textureSize(static_cloud_dome_map, 0).x < 8
	) {
		return vec4(0.0);
	}
	mat2 yaw = static_cloud_yaw();
	vec2 coordinates = static_cloud_dome_uv(direction, yaw);
	vec4 packed_cloud = texture(static_cloud_dome_map, coordinates);
	float density = packed_cloud.a;
	float overcast = smoothstep(0.73, 1.0, coverage);
	float coverage_fade = smoothstep(0.015, 0.39, coverage);
	float opacity = mix(density * coverage_fade, 0.965, overcast);
	opacity *= smoothstep(0.004, 0.075, direction.y) * static_cloud_opacity;

	vec3 light_dir = sun_dir.y > -0.04 ? sun_dir : moon_dir;
	vec3 weights = static_cloud_light_weights(light_dir, yaw);
	float relief = dot(packed_cloud.rgb, weights);
	float shading = 0.038 + relief * relief * 0.83;
	float ambient_scale = mix(0.39, 0.93, relief);
	if (overcast > 0.0) {
		vec3 smoothed = textureLod(static_cloud_dome_map, coordinates, 5.5).rgb;
		shading = mix(shading, 0.16 + dot(smoothed, weights) * 0.28, overcast);
		ambient_scale = mix(ambient_scale, 0.79, overcast);
	}
	float distance = min(static_cloud_altitude_km / max(direction.y, 0.04), 50.0);
	vec3 radiance = layered_cloud_lighting(
		direction, sky_color, sun_dir, moon_dir, lunar_illumination, static_cloud_altitude_km,
		distance, density, shading, ambient_scale
	);
	return vec4(radiance * opacity, opacity);
}
