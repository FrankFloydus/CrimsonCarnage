shader_type texture_blit;
render_mode blend_disabled;

#include "res://addons/dynamic_sky/rendering/cloud_density.gdshaderinc"
#include "res://addons/dynamic_sky/rendering/cloud_modes/dynamic_2d_cloud_field.gdshaderinc"

uniform vec3 projector_center_km = vec3(0.0);
uniform vec3 projector_right = vec3(1.0, 0.0, 0.0);
uniform vec3 projector_up = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_direction = vec3(0.0, 0.7071068, -0.7071068);
uniform float projector_size_km = 6.0;
uniform int samples_per_ray = 12;
uniform float shadow_strength = 1.0;
uniform int shadow_cloud_mode = 0;

uniform float static_cloud_altitude_km = 1.25;
uniform float static_cloud_scale = 1.0;
uniform float static_cloud_yaw_degrees = 0.0;
uniform float static_cloud_opacity = 1.0;

float volume_optical_depth(vec3 origin) {
	vec2 interval = cloud_shell_interval(origin, sun_direction, CLOUD_MAX_TRACE_DISTANCE_KM);
	float optical_depth = 0.0;
	if (interval.y > interval.x) {
		float step_length = (interval.y - interval.x) / float(samples_per_ray);
		for (int index = 0; index < samples_per_ray; index++) {
			float distance = interval.x + (float(index) + 0.5) * step_length;
			vec3 point = origin + sun_direction * distance;
			vec2 weather = cloud_coverage_at(point);
			float density = cloud_density_at(point, altitude_at(point), weather, true);
			optical_depth += density * cloud_extinction * step_length;
			if (optical_depth >= 7.0) {
				break;
			}
		}
	}
	return optical_depth;
}

float layer_optical_depth(vec3 origin) {
	bool static_layer = shadow_cloud_mode == 1;
	float altitude = static_layer ? static_cloud_altitude_km : dynamic_2d_base_km;
	float distance = cloud_shell_hits(origin, sun_direction, altitude).y;
	if (distance <= 0.0 || distance >= CLOUD_MAX_TRACE_DISTANCE_KM) {
		return 0.0;
	}

	vec2 point = origin.xz + sun_direction.xz * distance;
	float opacity;
	if (static_layer) {
		// The baked dome stays centered on the view. Its ground projector has a fixed world layout.
		float yaw = radians(-static_cloud_yaw_degrees);
		mat2 rotation = mat2(vec2(cos(yaw), -sin(yaw)), vec2(sin(yaw), cos(yaw)));
		vec2 coordinates = rotation * point * (2.0 * static_cloud_scale / DYNAMIC_CLOUD_TILE_KM)
			+ vec2(0.38, 0.19);
		float mass = dynamic_2d_cloud_density(coordinates);
		float thickness = smoothstep(0.31, 0.75, mass) * smoothstep(0.015, 0.39, cloud_coverage);
		opacity = mix(thickness, 0.965, smoothstep(0.73, 1.0, cloud_coverage)) * static_cloud_opacity;
	} else {
		// The lower sheet carries most of the visible mass and determines the ground pattern.
		vec2 coordinates = dynamic_2d_cloud_coordinates(point, cloud_offset, false);
		float mass = dynamic_2d_cloud_density(coordinates);
		opacity = dynamic_2d_cloud_thickness(mass, cloud_coverage, false) * dynamic_2d_opacity;
	}
	float horizon_fade = 1.0 - smoothstep(
		CLOUD_MAX_TRACE_DISTANCE_KM * 0.72, CLOUD_MAX_TRACE_DISTANCE_KM, distance
	);
	float slant = min(1.0 / sun_direction.y, 1.75);
	return 1.65 * opacity * horizon_fade * slant;
}

void blit() {
	vec2 plane = (UV - vec2(0.5)) * projector_size_km;
	vec3 origin = projector_center_km + projector_right * plane.x + projector_up * plane.y;
	float fade = smoothstep(0.035, 0.13, sun_direction.y) * shadow_strength;
	float transmission = 1.0;
	bool has_clouds = cloud_coverage > 0.0;
	if (fade > 0.0 && has_clouds) {
		// Points along this sunlight ray share one texel. Start at the rig's sea-level plane.
		origin -= sun_direction * (origin.y / sun_direction.y);
		float depth = shadow_cloud_mode == 0 ? volume_optical_depth(origin) : layer_optical_depth(origin);
		transmission = mix(1.0, exp(-depth), fade);
	}
	COLOR0 = vec4(vec3(transmission), 1.0);
}
