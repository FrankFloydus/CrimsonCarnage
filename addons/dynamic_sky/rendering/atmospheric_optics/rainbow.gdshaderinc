// Linear additive radiance. Compose before the sky's final exposure transform.
group_uniforms Rainbow_Runtime;
uniform bool rainbow_enabled = false;
uniform float rainbow_strength : hint_range(0.0, 1.0, 0.001) = 0.0;
uniform float rainbow_cloud_transmission : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float rainbow_exposure : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float rainbow_primary_angle_degrees : hint_range(35.0, 48.0, 0.1) = 42.0;
uniform float rainbow_primary_width_degrees : hint_range(0.5, 6.0, 0.1) = 2.0;
uniform float rainbow_secondary_strength : hint_range(0.0, 1.0, 0.01) = 0.28;
uniform float rainbow_secondary_angle_degrees : hint_range(47.0, 60.0, 0.1) = 51.0;
uniform float rainbow_secondary_width_degrees : hint_range(0.5, 8.0, 0.1) = 2.5;
group_uniforms;


vec3 rainbow_spectral_band(float angle, vec3 centers, float width, float pixel_width) {
	float sigma = max(width * 0.20, pixel_width * 0.65);
	vec3 offset = (vec3(angle) - centers) / max(sigma, 0.001);
	// Each component includes its spectral opacity, so additive composition multiplies it once.
	return exp(-0.5 * offset * offset);
}


vec3 atmospheric_rainbow(vec3 view_direction, vec3 direction_to_sun) {
	if (!rainbow_enabled || rainbow_strength <= 0.0) {
		return vec3(0.0);
	}
	float sun_visibility = clamp(direction_to_sun.y * 3.0, 0.0, 1.0);
	float visibility = sun_visibility * rainbow_cloud_transmission * rainbow_exposure;
	visibility *= smoothstep(-0.005, 0.012, view_direction.y);
	float anti_solar_dot = clamp(dot(view_direction, -direction_to_sun), -1.0, 1.0);
	float angle = degrees(acos(anti_solar_dot));
	float pixel_width = fwidth(angle);
	vec3 primary_centers = vec3(
		rainbow_primary_angle_degrees,
		rainbow_primary_angle_degrees - rainbow_primary_width_degrees * 0.5,
		rainbow_primary_angle_degrees - rainbow_primary_width_degrees
	);
	vec3 secondary_centers = vec3(
		rainbow_secondary_angle_degrees,
		rainbow_secondary_angle_degrees + rainbow_secondary_width_degrees * 0.5,
		rainbow_secondary_angle_degrees + rainbow_secondary_width_degrees
	);
	vec3 primary = rainbow_spectral_band(
		angle, primary_centers, rainbow_primary_width_degrees, pixel_width
	);
	vec3 secondary = rainbow_spectral_band(
		angle, secondary_centers, rainbow_secondary_width_degrees, pixel_width
	);
	return (primary + secondary * rainbow_secondary_strength) * rainbow_strength * visibility;
}
