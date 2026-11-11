group_uniforms Simplified_Color;
// Sky Atmosphere uses atmospheric scattering. Simplified Color uses authored solar and lunar palettes.
uniform int sky_color_mode : hint_enum("Sky Atmosphere", "Simplified Color") = 0;
// Original gamma-encoded color volumes keyed by view elevation, relative azimuth, and light elevation.
uniform sampler3D simple_sun_lut : filter_linear, repeat_disable;
uniform sampler3D simple_moon_lut : filter_linear, repeat_disable;
uniform float simple_sky_exposure : hint_range(0.25, 3.0, 0.01) = 1.0;
uniform float simple_moon_strength : hint_range(0.0, 3.0, 0.01) = 1.0;
// Sky palette multipliers after lookup. The baked palette itself is editable in simplified_palette.json.
uniform vec3 simple_day_sky_tint : source_color = vec3(1.0);
uniform vec3 simple_twilight_sky_tint : source_color = vec3(1.0);
uniform vec3 simple_night_sky_tint : source_color = vec3(1.0);
uniform vec3 simple_dust_tint : source_color = vec3(0.54, 0.35, 0.20);
// Direct light color and ambient fill used by cloud rendering in Simplified Color mode.
uniform vec3 simple_cloud_day_tint : source_color = vec3(1.0, 0.93, 0.81);
uniform vec3 simple_cloud_twilight_tint : source_color = vec3(1.0, 0.53, 0.26);
uniform vec3 simple_cloud_night_tint : source_color = vec3(0.43, 0.56, 0.87);
uniform vec3 simple_cloud_day_ambient : source_color = vec3(0.34, 0.43, 0.58);
uniform vec3 simple_cloud_twilight_ambient : source_color = vec3(0.16, 0.18, 0.32);
uniform vec3 simple_cloud_night_ambient : source_color = vec3(0.012, 0.020, 0.044);
group_uniforms;

float simple_daylight(float sun_y) {
	return smoothstep(-0.10, 0.28, sun_y);
}

float simple_twilight(float sun_y) {
	return smoothstep(-0.24, -0.085, sun_y) * (1.0 - smoothstep(0.02, 0.25, sun_y));
}

float simple_lut_elevation(float elevation) {
	return 0.5 + 0.5 * sign(elevation) * sqrt(clamp(abs(elevation), 0.0, 1.0));
}

vec3 simple_lut_coordinates(vec3 view_direction, vec3 light_direction, vec3 size) {
	float horizontal = length(view_direction.xz) * length(light_direction.xz);
	float azimuth = clamp(dot(view_direction.xz, light_direction.xz) / max(horizontal, 0.0001), -1.0, 1.0);
	vec3 coordinates = vec3(
		simple_lut_elevation(view_direction.y),
		azimuth * 0.5 + 0.5,
		simple_lut_elevation(light_direction.y)
	);
	return (coordinates * (size - 1.0) + 0.5) / size;
}

vec3 simple_sky_fallback(vec3 view_ray, vec3 solar_dir) {
	float day = simple_daylight(solar_dir.y);
	float twilight = simple_twilight(solar_dir.y);
	float height = pow(max(view_ray.y, 0.0), 0.56);
	vec3 horizon = mix(vec3(0.006, 0.012, 0.034), vec3(0.40, 0.60, 0.75), day);
	vec3 zenith = mix(vec3(0.0015, 0.0028, 0.009), vec3(0.043, 0.19, 0.49), day);
	float warm = pow(max(dot(view_ray, solar_dir), 0.0), 2.0);
	horizon = mix(horizon, mix(vec3(0.15, 0.13, 0.25), vec3(0.76, 0.29, 0.08), warm), twilight * 0.85);
	vec3 sky = mix(horizon, zenith, height);
	vec3 ground = mix(vec3(0.002, 0.005, 0.010), vec3(0.08, 0.13, 0.20), day);
	return mix(sky, ground, smoothstep(0.0, 0.75, -view_ray.y));
}

vec3 simple_sky_color(
		vec3 view_ray, vec3 solar_dir, vec3 lunar_dir,
		float lunar_phase, float coverage, float dust_amount
) {
	float day = simple_daylight(solar_dir.y);
	float twilight = simple_twilight(solar_dir.y);
	vec3 sun_size = vec3(textureSize(simple_sun_lut, 0));
	vec3 moon_size = vec3(textureSize(simple_moon_lut, 0));
	vec3 color;
	if (sun_size.x >= 16.0) {
		vec3 encoded = textureLod(simple_sun_lut, simple_lut_coordinates(view_ray, solar_dir, sun_size), 0.0).rgb;
		color = pow(encoded, vec3(2.2));
	} else {
		color = simple_sky_fallback(view_ray, solar_dir);
	}
	float moon_weight = (1.0 - day) * clamp(lunar_phase, 0.0, 1.0) * simple_moon_strength;
	if (moon_weight > 0.001 && moon_size.x >= 16.0) {
		vec3 encoded = textureLod(simple_moon_lut, simple_lut_coordinates(view_ray, lunar_dir, moon_size), 0.0).rgb;
		color += pow(encoded, vec3(2.2)) * moon_weight;
	}
	vec3 palette_tint = mix(simple_night_sky_tint, simple_day_sky_tint, day);
	color *= mix(palette_tint, simple_twilight_sky_tint, twilight);
	float overcast = smoothstep(0.61, 1.0, coverage);
	float haze = 1.0 - smoothstep(-0.08, 0.48, abs(view_ray.y));
	vec3 neutral_horizon = mix(vec3(0.012, 0.016, 0.025), vec3(0.34, 0.39, 0.46), day);
	color = mix(color, neutral_horizon, overcast * haze * 0.32);
	vec3 dust = simple_dust_tint * mix(0.035, 1.0, day);
	color = mix(color, dust, pow(clamp(dust_amount, 0.0, 1.0), 1.2) * mix(0.70, 0.96, haze));
	return color * simple_sky_exposure;
}

vec3 simple_cloud_direct_color(vec3 solar_dir, vec3 lunar_dir, float lunar_phase) {
	float sunlight = smoothstep(-0.075, 0.045, solar_dir.y);
	vec3 solar = mix(simple_cloud_day_tint, simple_cloud_twilight_tint, simple_twilight(solar_dir.y));
	float moonlight = smoothstep(0.0, 0.20, lunar_dir.y) * clamp(lunar_phase, 0.0, 1.0);
	vec3 lunar = simple_cloud_night_tint * moonlight * 0.15 * simple_moon_strength;
	return solar * sunlight + lunar * (1.0 - sunlight);
}

vec3 simple_cloud_ambient_color(vec3 solar_dir, vec3 lunar_dir, float lunar_phase) {
	float day = simple_daylight(solar_dir.y);
	vec3 ambient = mix(simple_cloud_night_ambient, simple_cloud_day_ambient, day);
	ambient = mix(ambient, simple_cloud_twilight_ambient, simple_twilight(solar_dir.y) * 0.85);
	float moon_fill = smoothstep(0.0, 0.40, lunar_dir.y) * clamp(lunar_phase, 0.0, 1.0);
	return ambient + simple_cloud_night_tint * moon_fill * (1.0 - day) * 0.024 * simple_moon_strength;
}
