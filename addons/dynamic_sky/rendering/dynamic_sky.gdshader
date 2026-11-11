shader_type sky;
render_mode use_half_res_pass;

group_uniforms Runtime;
// Normalized world-space directions from the observer toward the sun and moon.
uniform vec3 sun_direction = vec3(0.0, 0.7071068, -0.7071068);
uniform vec3 moon_direction = vec3(0.0, -0.7071068, 0.7071068);
// Lunar synodic phase. 0 and 1 are new moon, 0.5 is full moon.
uniform float moon_phase : hint_range(0.0, 1.0) = 0.5;
// Rotation from world directions into the coordinates of the star field.
uniform mat3 star_rotation = mat3(1.0);
// Observer position relative to the rig's sea-level origin, in kilometers.
uniform vec3 cloud_observer_position_km = vec3(0.0);
// Brief lightning illumination of the visible sky and cloud cover.
uniform float lightning_flash : hint_range(0.0, 1.0) = 0.0;
// Normalized direction toward a nearby bolt. Zero uses broad cloud lightning.
uniform vec3 lightning_direction = vec3(0.0);
// Position of a visible strike relative to the observer, in kilometers. Zero uses angular lighting.
uniform vec3 lightning_position_km = vec3(0.0);
// Distance in kilometers at which the local cloud flash decays to about a third.
uniform float lightning_radius_km : hint_range(0.05, 2.0, 0.01) = 0.41;
// Multiplier on scattered lightning light inside the cloud volume.
uniform float lightning_cloud_strength : hint_range(0.0, 1.5, 0.01) = 0.78;
// Strength of the suspended mineral haze.
uniform float dust_density : hint_range(0.0, 1.0) = 0.0;

group_uniforms Atmosphere;
// Baked RGB single-scattered radiance and approximate multiple-scattering fill.
uniform sampler3D atmosphere_view : filter_linear, repeat_disable;
// Baked RGB transmittance from a given altitude and direction to space.
uniform sampler2D atmosphere_transmittance : filter_linear, repeat_disable;
// Exposure multiplier for the scattered sky background.
uniform float atmosphere_exposure : hint_range(0.1, 4.0, 0.01) = 0.52;
// Art tint for daylight overhead and at the horizon.
uniform vec3 sky_zenith : source_color = vec3(0.16, 0.39, 0.68);
uniform vec3 sky_horizon : source_color = vec3(0.68, 0.79, 0.91);
// Ground reflection color below the horizon where no geometry covers the sky.
uniform vec3 sky_ground : source_color = vec3(0.29, 0.33, 0.39);

group_uniforms Celestials;
// Angular radii of the disks in degrees.
uniform float sun_angular_radius : hint_range(0.1, 4.0, 0.05) = 0.27;
uniform float moon_angular_radius : hint_range(0.1, 4.0, 0.05) = 0.45;
// Brightness multiplier for the fixed star field. Zero hides stars.
uniform float star_brightness : hint_range(0.0, 4.0, 0.05) = 1.0;

group_uniforms Cloud_Volume;
// Balanced traces at half resolution. High traces denser rays at full resolution.
uniform int volumetric_quality : hint_enum("Balanced", "High") = 0;
// Albedo tint of directly lit clouds and ambient tint inside their shadows.
uniform vec3 cloud_light : source_color = vec3(0.93, 0.95, 0.98);
uniform vec3 cloud_shadow : source_color = vec3(0.34, 0.40, 0.48);
// Balanced ray sample budget. High uses up to 50 percent more view samples.
uniform int cloud_steps : hint_range(12, 96, 1) = 64;
// Horizontal frequency of the upper cloud wisps.
uniform float high_cloud_scale : hint_range(0.5, 16.0, 0.1) = 3.0;
// Peak opacity of the cirrus layer before its local density and weather fades.
uniform float high_cloud_amount : hint_range(0.0, 0.75, 0.01) = 0.0;
group_uniforms;

#include "res://addons/dynamic_sky/rendering/cloud_density.gdshaderinc"
#include "res://addons/dynamic_sky/rendering/optional_sky_layers.gdshaderinc"
#include "res://addons/dynamic_sky/rendering/color_modes/simplified_color.gdshaderinc"
#include "res://addons/dynamic_sky/rendering/atmospheric_optics/rainbow.gdshaderinc"

float hash_point(vec3 point) {
	vec3 phase = fract(point * vec3(0.1031, 0.1137, 0.1379));
	phase += dot(phase, phase.yzx + 19.19);
	return fract((phase.x + phase.y) * phase.z);
}

vec3 transmission_to_space(float cosine, float altitude) {
	float u = (sign(cosine) * sqrt(abs(cosine)) + 0.5) / 1.5;
	float v = sqrt(clamp(altitude * 0.01, 0.0, 1.0));
	vec2 uv = (clamp(vec2(u, v), vec2(0.0), vec2(1.0)) * vec2(191.0, 95.0) + 0.5) / vec2(192.0, 96.0);
	return pow(textureLod(atmosphere_transmittance, uv, 0.0).rgb, vec3(2.2));
}

float moon_illumination() {
	return 0.5 * (1.0 - cos(TAU * moon_phase));
}

float flash_in_direction(vec3 direction) {
	if (dot(lightning_direction, lightning_direction) < 0.001) {
		return lightning_flash * 0.45;
	}
	float alignment = max(dot(direction, lightning_direction), 0.0);
	return lightning_flash * (0.045 + 0.76 * pow(alignment, 13.0));
}

vec3 cloud_flash_radiance(vec3 position, vec3 light, float density, float angular_flash) {
	if (lightning_flash <= 0.0 || lightning_cloud_strength <= 0.0) {
		return vec3(0.0);
	}
	float strength = angular_flash * 0.62;
	if (dot(lightning_position_km, lightning_position_km) >= 0.001) {
		vec3 displacement = position - lightning_position_km;
		float inverse_radius = 1.0 / lightning_radius_km;
		float local_falloff = exp(-dot(displacement, displacement) * inverse_radius * inverse_radius);
		strength = angular_flash * 0.07;
		if (local_falloff > 0.012) {
			vec3 midpoint = cloud_observer_position_km + (position + lightning_position_km) * 0.5;
			float blocking = cloud_density_at(midpoint, altitude_at(midpoint), cloud_coverage_at(midpoint), false);
			float transmission = exp(-blocking * cloud_extinction * length(displacement) * 0.63);
			strength += lightning_flash * local_falloff * (0.28 + 0.72 * transmission);
		}
	}
	float scatter = 0.52 + 0.48 * sqrt(clamp(density, 0.0, 1.0));
	vec3 addition = vec3(0.21, 0.29, 0.43) * strength * scatter * lightning_cloud_strength;
	float headroom = max(0.74 - max(light.r, max(light.g, light.b)), 0.0);
	return addition * min(1.0, headroom / max(addition.b, 0.0001));
}

float low_sun_strength() {
	float sun_y = sun_direction.y;
	return smoothstep(-0.052, 0.011, sun_y) * (1.0 - smoothstep(0.043, 0.24, sun_y));
}

vec3 atmosphere(vec3 direction) {
	if (sky_color_mode == 1) {
		float coverage = cloud_mode == 2 ? 0.0 : cloud_coverage;
		return simple_sky_color(direction, sun_direction, moon_direction, moon_illumination(), coverage, dust_density);
	}
	float view_y = max(direction.y, 0.0);
	float sun_y = clamp(sun_direction.y, -1.0, 1.0);
	float horizontal = length(direction.xz) * length(sun_direction.xz);
	float azimuth = acos(clamp(dot(direction.xz, sun_direction.xz) / max(horizontal, 0.00001), -1.0, 1.0));
	float u = azimuth / PI;
	float v = sqrt(view_y);
	float w = clamp((sign(sun_y) * sqrt(abs(sun_y)) + 0.6) / 1.6, 0.0, 1.0);
	vec3 uvw = (vec3(u, v, w) * vec3(127.0, 79.0, 63.0) + 0.5) / vec3(128.0, 80.0, 64.0);
	vec3 encoded = textureLod(atmosphere_view, uvw, 0.0).rgb;
	vec3 radiance = (pow(vec3(97.0), encoded) - 1.0) * (atmosphere_exposure / 24.0);
	vec3 palette = mix(sky_horizon, sky_zenith, v);
	vec3 tint = palette / max(dot(palette, vec3(0.2126, 0.7152, 0.0722)), 0.08);
	radiance *= mix(vec3(1.0), tint, 0.15) * vec3(1.06, 0.91, 0.73);
	float sunward = max(dot(direction, sun_direction), 0.0);
	float daylight = smoothstep(-0.075, 0.085, sun_y);
	float horizon_reduction = mix(0.51, 1.0, smoothstep(0.0, 0.39, view_y));
	radiance *= mix(mix(0.22, 1.0, pow(sunward, 4.0)), 1.0, daylight) * horizon_reduction;
	// Aerosols close to the horizon spread low-angle sunlight into a broad warm glow.
	radiance += vec3(1.41, 0.72, 0.27) * (pow(sunward, 20.0) + 0.28 * pow(sunward, 5.0)) * exp(-view_y * 3.5) * low_sun_strength();

	float night = 1.0 - smoothstep(-0.18, 0.02, sun_y);
	float blue_hour = smoothstep(-0.20, -0.10, sun_y) * (1.0 - smoothstep(-0.065, 0.025, sun_y));
	radiance += vec3(0.026, 0.019, 0.064) * (0.61 + 0.52 * (1.0 - v)) * blue_hour;
	float moon_high = smoothstep(0.0, 0.35, moon_direction.y);
	float moonward = max(dot(direction, moon_direction), 0.0);
	radiance += night * (vec3(0.0055, 0.0098, 0.031)
		+ vec3(0.0045, 0.0078, 0.019) * (1.0 - v)
		+ vec3(0.018, 0.027, 0.048) * pow(moonward, 52.0) * moon_high * moon_illumination());

	float day = smoothstep(-0.18, 0.15, sun_y);
	float storm_haze = cloud_mode == 2 ? 0.0 : smoothstep(0.76, 1.0, cloud_coverage) * (1.0 - smoothstep(0.015, 0.38, view_y));
	vec3 storm_light = mix(vec3(0.006, 0.012, 0.027), vec3(0.105, 0.151, 0.237), day);
	radiance = mix(radiance, storm_light, storm_haze * 0.89);
	vec3 dust_scatter = mix(vec3(0.012, 0.008, 0.005), vec3(0.190, 0.153, 0.116), day);
	float dusty_air = dust_density * mix(0.98, 0.90, smoothstep(0.0, 0.65, view_y));
	radiance = mix(radiance, dust_scatter, dusty_air);
	vec3 ground = sky_ground * mix(0.004, 0.34, day);
	return mix(radiance, ground, smoothstep(0.0, 0.085, -direction.y));
}

float star_field(vec3 direction) {
	vec3 point = direction * 176.0;
	vec3 cell = floor(point);
	float brightness = hash_point(cell);
	float stellar_band = 1.0 - smoothstep(0.0, 0.42, abs(dot(direction, vec3(0.74, 0.41, 0.53))));
	float threshold = mix(0.979, 0.947, stellar_band);
	if (brightness < threshold) {
		return 0.0;
	}
	vec3 center = vec3(
		hash_point(cell + vec3(7.0, 0.0, 0.0)),
		hash_point(cell + vec3(0.0, 13.0, 0.0)),
		hash_point(cell + vec3(0.0, 0.0, 23.0))
	);
	center = mix(vec3(0.23), vec3(0.77), center);
	float strength = (brightness - threshold) / (1.0 - threshold);
	float radius = mix(0.11, 0.23, strength);
	float distance_to_center = length(fract(point) - center);
	return (1.0 - smoothstep(radius * 0.18, radius, distance_to_center)) * mix(0.06, 1.0, strength * strength);
}

float disk_mask(vec3 direction, vec3 center, float radius_degrees) {
	float radius = radians(radius_degrees);
	float chord = length(direction - center);
	return 1.0 - smoothstep(radius * 0.90, radius * 1.10, chord);
}

vec3 draw_celestials(vec3 color, vec3 direction, bool from_space) {
	float night = from_space ? 1.0 : 1.0 - smoothstep(-0.12, 0.015, sun_direction.y);
	if (celestial_mode != 2 && night > 0.0 && star_brightness > 0.0) {
		float horizon_fade = from_space ? 1.0 : smoothstep(0.004, 0.21, direction.y) * (1.0 - dust_density);
		float background_light = 1.0 - smoothstep(0.02, 0.16, max(color.r, max(color.g, color.b)));
		color += vec3(0.78, 0.87, 1.0) * star_field(star_rotation * direction)
			* night * horizon_fade * background_light * star_brightness;
	}

	if (from_space || sun_direction.y > -0.01) {
		float disk = disk_mask(direction, sun_direction, sun_angular_radius);
		float alignment = max(dot(direction, sun_direction), 0.0);
		float halo = from_space ? pow(alignment, 620.0) * 0.027 : pow(alignment, 270.0) * 0.44 + pow(alignment, 28.0) * 0.022;
		vec3 solar = vec3(1.0, 0.95, 0.88);
		if (!from_space) {
			if (sky_color_mode == 1) {
				float horizon = smoothstep(-0.015, 0.14, sun_direction.y);
				solar = mix(simple_cloud_twilight_tint, simple_cloud_day_tint, horizon) * mix(0.45, 1.0, horizon);
			} else {
				solar = transmission_to_space(max(sun_direction.y, 0.0), 0.0);
			}
			solar *= exp(-dust_density * vec3(1.12, 1.45, 1.86));
		}
		color += solar * halo + pow(solar, vec3(0.78)) * (16.0 * disk);
	}
	if (from_space || moon_direction.y > -0.01) {
		float disk = disk_mask(direction, moon_direction, moon_angular_radius);
		if (disk > 0.0) {
			vec3 pole = abs(moon_direction.y) < 0.95 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
			vec3 axis = normalize(cross(moon_direction, pole));
			vec3 axis_y = cross(axis, moon_direction);
			float radius = radians(moon_angular_radius);
			vec2 surface = vec2(dot(direction, axis), dot(direction, axis_y)) / radius;
			vec3 pattern = textureLod(cloud_noise, vec3(surface * 0.21 + 0.5, 0.43), 0.0).rgb;
			float albedo = mix(0.34, 0.98, smoothstep(0.43, 0.77, pattern.r * 0.87 + pattern.g * 0.13));
			vec3 lunar = vec3(0.80, 0.90, 1.0);
			if (!from_space) {
				if (sky_color_mode == 1) {
					float horizon = smoothstep(-0.012, 0.30, moon_direction.y);
					lunar *= mix(vec3(0.72, 0.48, 0.35), vec3(1.0), horizon) * simple_moon_strength;
				} else {
					lunar *= transmission_to_space(max(moon_direction.y, 0.0), 0.0);
				}
			}
			float surface_depth = sqrt(max(1.0 - dot(surface, surface), 0.0));
			float phase_angle = TAU * moon_phase;
			float terminator = surface.x * sin(phase_angle) - surface_depth * cos(phase_angle);
			float lambert = sqrt(max(terminator, 0.0));
			float illuminated = smoothstep(0.0, 0.065, terminator) * (0.48 + 0.52 * lambert);
			color += lunar * disk * albedo * (illuminated * (0.70 + 1.25 * night) + 0.014 * night);
		}
	}
	return color;
}

float cloud_layer_distance(vec3 direction, float altitude) {
	vec2 layer = cloud_shell_hits(cloud_observer_position_km, direction, altitude);
	float distance = layer.x >= 0.0 ? layer.x : layer.y;
	vec2 ground = cloud_shell_hits(cloud_observer_position_km, direction, 0.0);
	if (ground.x >= 0.0 && ground.x < ground.y && ground.x < distance) {
		return -1.0;
	}
	return distance;
}

float light_through_cloud(vec3 position, vec3 light_dir, vec2 weather) {
	float optical_depth = 0.0;
	float step_length = cloud_thickness_km * 0.10;
	float distance = step_length * 0.5;
	for (int index = 0; index < 7; index++) {
		vec3 point = position + light_dir * distance;
		float height = altitude_at(point);
		if (height >= cloud_base_km + cloud_thickness_km) {
			break;
		}
		float density = cloud_density_at(point, height, weather, false);
		optical_depth += density * step_length;
		distance += step_length * 1.275;
		step_length *= 1.55;
	}
	float deep_shadow = exp(-optical_depth * cloud_extinction);
	float multiple_scatter = exp(-optical_depth * cloud_extinction * 0.27);
	return deep_shadow * 0.64 + multiple_scatter * 0.36;
}

float phase_lobe(float cosine, float eccentricity) {
	float denominator = 1.0 + eccentricity * eccentricity - 2.0 * eccentricity * cosine;
	return (1.0 - eccentricity * eccentricity) / pow(max(denominator, 0.02), 1.5);
}

vec4 upper_clouds(vec3 direction, float distance, vec3 sky_color, vec3 light_color, float daylight) {
	if (distance < 0.0 || high_cloud_amount <= 0.0) {
		return vec4(0.0);
	}
	vec2 point = cloud_observer_position_km.xz + direction.xz * distance;
	vec2 drift = cloud_offset / 128.0;
	vec2 streak_uv = vec2(point.x + point.y * 0.62, point.y - point.x * 0.62);
	streak_uv *= vec2(0.0032, 0.011) * high_cloud_scale;
	streak_uv += drift + vec2(0.19, 0.44);
	float mask = textureLod(cloud_weather, streak_uv, 0.0).b;
	float streak = textureLod(cloud_weather, streak_uv * 2.0 + vec2(0.38, 0.21), 0.0).b;
	float region = textureLod(cloud_weather, point / 176.0 + drift + vec2(0.21, 0.60), 0.0).r;
	float density = smoothstep(0.44, 0.64, mask * 0.81 + streak * 0.19);
	float coverage_fade = smoothstep(0.30, 0.66, cloud_coverage);
	density *= smoothstep(0.48, 0.65, region) * smoothstep(0.025, 0.19, abs(direction.y)) * coverage_fade * high_cloud_amount;
	vec3 radiance = mix(vec3(0.003, 0.005, 0.009), cloud_shadow * 0.84, daylight) + light_color * 0.40;
	radiance = mix(radiance, sky_color, 1.0 - exp(-distance * 0.005));
	return vec4(radiance * density, density);
}

vec4 trace_clouds(vec3 direction, bool high_quality) {
	vec3 sky_color = atmosphere(direction);
	float sunlight = smoothstep(-0.075, 0.045, sun_direction.y);
	float daylight = smoothstep(-0.10, 0.14, sun_direction.y);
	float overcast = smoothstep(0.63, 1.0, cloud_coverage);
	vec3 light_dir = sunlight > 0.025 ? sun_direction : moon_direction;
	float light_cosine = dot(direction, light_dir);
	float phase = 0.61 * phase_lobe(light_cosine, 0.59) + 0.39 * phase_lobe(light_cosine, -0.26);
	phase = min(phase, 3.05);
	vec3 solar = transmission_to_space(sun_direction.y, cloud_base_km + cloud_thickness_km) * sunlight;
	solar *= exp(-dust_density * vec3(1.49, 1.72, 2.01));
	vec3 lunar = vec3(0.065, 0.103, 0.18) * (1.0 - sunlight)
		* smoothstep(0.0, 0.20, moon_direction.y) * moon_illumination();
	vec3 light_color = cloud_light * (solar * mix(0.55, 0.53, overcast) + lunar);
	vec3 ambient = mix(vec3(0.0022, 0.004, 0.009), cloud_shadow * vec3(0.88, 0.97, 1.11) * mix(0.58, 0.68, overcast), daylight);
	ambient += vec3(0.018, 0.025, 0.036) * daylight;
	float forward_twilight = pow(max(dot(direction, sun_direction), 0.0), 6.0) * low_sun_strength();
	ambient += vec3(0.37, 0.182, 0.071) * forward_twilight * (1.0 - dust_density * 0.69);
	if (sky_color_mode == 1) {
		float lunar_strength = moon_illumination();
		light_color = cloud_light * simple_cloud_direct_color(sun_direction, moon_direction, lunar_strength)
			* mix(0.55, 0.53, overcast) * exp(-dust_density * vec3(1.49, 1.72, 2.01));
		ambient = simple_cloud_ambient_color(sun_direction, moon_direction, lunar_strength) * mix(0.54, 0.61, overcast);
	}

	float upper_distance = cloud_layer_distance(direction, 7.2);
	vec4 upper = upper_clouds(direction, upper_distance, sky_color, light_color, daylight);
	vec2 segment = cloud_shell_interval(cloud_observer_position_km, direction, CLOUD_MAX_TRACE_DISTANCE_KM);
	float start = segment.x;
	float end = segment.y;
	if (start >= end) {
		return upper;
	}
	float trace_length = end - start;
	int budget = high_quality ? cloud_steps * 3 / 2 : cloud_steps;
	float minimum_step = high_quality ? 0.040 : 0.062;
	float step_length = max(trace_length / float(budget), minimum_step);
	float distance = start;
	float flash = flash_in_direction(direction);
	float dusty_cloud = smoothstep(0.30, 1.0, dust_density);
	float view_transmittance = 1.0;
	vec3 scattered = vec3(0.0);
	for (int index = 0; index < budget; index++) {
		if (distance >= end || view_transmittance < 0.012) {
			break;
		}
		// Clip the last segment without rescaling the preceding samples.
		float segment_length = min(step_length, end - distance);
		float sample_distance = distance + segment_length * 0.5;
		vec3 observer_relative_position = direction * sample_distance;
		vec3 position = cloud_observer_position_km + observer_relative_position;
		float height = altitude_at(position);
		vec2 weather = cloud_coverage_at(position);
		float visible_detail = 1.0 - smoothstep(8.0, 28.0, sample_distance);
		float density = cloud_density_with_detail(position, height, weather, true, visible_detail);
		if (density > 0.001) {
			float segment_transmittance = exp(-density * cloud_extinction * segment_length);
			float illuminated = light_through_cloud(position, light_dir, weather);
			float height_light = clamp((height - cloud_base_km) / cloud_thickness_km, 0.0, 1.0);
			vec3 lighting = ambient * (0.55 + 0.62 * height_light) * (1.0 - 0.16 * smoothstep(0.18, 0.74, density));
			lighting += light_color * (0.46 + 0.69 * phase) * illuminated;
			lighting += cloud_flash_radiance(observer_relative_position, lighting, density, flash);
			float haze = 1.0 - exp(-sample_distance * (mix(0.013, 0.012, overcast) + 0.043 * dust_density))
				* (1.0 - dusty_cloud * 0.87);
			lighting = mix(lighting, sky_color, haze);
			scattered += view_transmittance * (1.0 - segment_transmittance) * lighting;
			view_transmittance *= segment_transmittance;
		}
		distance += step_length;
	}
	vec3 total = upper_distance >= 0.0 && upper_distance < start
		? upper.rgb + scattered * (1.0 - upper.a)
		: scattered + upper.rgb * view_transmittance;
	float trace_fade = 1.0 - smoothstep(CLOUD_MAX_TRACE_DISTANCE_KM * 0.68, CLOUD_MAX_TRACE_DISTANCE_KM, start);
	vec4 combined = vec4(total, 1.0 - (1.0 - upper.a) * view_transmittance);
	return mix(upper, combined, trace_fade);
}

#include "res://addons/dynamic_sky/rendering/cloud_modes/layered_cloud_modes.gdshaderinc"

void sky() {
	bool from_space = celestial_mode == 1 || cloud_mode == 4;
	bool high_volume = cloud_mode == 0 && volumetric_quality == 1;
	if (from_space) {
		COLOR = vec3(0.0);
		ALPHA = 0.0;
		if (!AT_HALF_RES_PASS) {
			COLOR = space_backdrop(EYEDIR, true);
			if (!AT_CUBEMAP_PASS) {
				COLOR = draw_celestials(COLOR, EYEDIR, true);
				COLOR = draw_space_planet(COLOR, EYEDIR);
			}
		}
	} else if (AT_CUBEMAP_PASS) {
		// The reflection pass captures slow sky and weather color without tracing the moving volume.
		COLOR = atmosphere(EYEDIR);
		if (!AT_HALF_RES_PASS && cloud_mode != 2) {
			float daylight = smoothstep(-0.18, 0.16, sun_direction.y);
			float sky_weight = smoothstep(-0.07, 0.29, EYEDIR.y);
			vec3 cloud_tint = mix(vec3(0.004, 0.007, 0.016), mix(cloud_shadow, cloud_light, 0.26), daylight);
			COLOR = mix(COLOR, cloud_tint, cloud_coverage * cloud_coverage * sky_weight * 0.75);
		}
	} else if (AT_HALF_RES_PASS) {
		vec4 clouds = vec4(0.0);
		float visible_base = cloud_mode == 3 ? dynamic_2d_base_km : cloud_base_km;
		bool has_clouds = cloud_coverage > 0.0;
		if (!high_volume && has_clouds
			&& (EYEDIR.y > 0.0 || altitude_at(cloud_observer_position_km) >= visible_base)) {
			if (cloud_mode == 0) {
				clouds = trace_clouds(EYEDIR, false);
			} else if (cloud_mode == 1) {
				clouds = shade_static_cloud_layer(
					EYEDIR, atmosphere(EYEDIR), sun_direction, moon_direction, cloud_coverage, moon_illumination()
				);
			} else if (cloud_mode == 3) {
				clouds = shade_dynamic_2d_clouds(
					EYEDIR, atmosphere(EYEDIR), sun_direction, moon_direction, cloud_offset,
					cloud_coverage, moon_illumination()
				);
			}
		}
		COLOR = clouds.rgb;
		ALPHA = clouds.a;
	} else {
		vec3 color = atmosphere(EYEDIR);
		if (EYEDIR.y > 0.0) {
			if (celestial_mode != 2) {
				color += space_backdrop(EYEDIR, false);
			}
			color = draw_celestials(color, EYEDIR, false);
			color = draw_space_planet(color, EYEDIR);
			color += aurora_emission(EYEDIR);
			color += flash_in_direction(EYEDIR) * vec3(0.014, 0.023, 0.042);
		}
		vec4 clouds = HALF_RES_COLOR;
		if (high_volume && cloud_coverage > 0.0
			&& (EYEDIR.y > 0.0 || altitude_at(cloud_observer_position_km) >= cloud_base_km)) {
			clouds = trace_clouds(EYEDIR, true);
		}
		COLOR = color * (1.0 - clouds.a) + clouds.rgb;
		COLOR += atmospheric_rainbow(EYEDIR, sun_direction);
	}
}

