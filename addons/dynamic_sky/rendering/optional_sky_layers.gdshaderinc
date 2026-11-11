group_uniforms Aurora;
// Emission strength. Zero disables the curtain trace.
uniform float aurora_intensity : hint_range(0.0, 3.0, 0.01) = 0.0;
// Direction of the auroral oval in degrees clockwise from world north (-Z).
uniform float aurora_azimuth_degrees : hint_range(-180.0, 180.0, 0.1) = 0.0;
// Ground distance to the nearest curtain in kilometers.
uniform float aurora_distance_km : hint_range(180.0, 1400.0, 1.0) = 480.0;
// Offset along the auroral arc in kilometers, for authored animation.
uniform float aurora_scroll = 0.0;
// Green oxygen emission, high red oxygen emission, and violet nitrogen emission.
uniform vec3 aurora_green : source_color = vec3(0.14, 1.0, 0.49);
uniform vec3 aurora_red : source_color = vec3(0.98, 0.21, 0.25);
uniform vec3 aurora_violet : source_color = vec3(0.44, 0.33, 1.0);

group_uniforms Space;
// Space Only removes the atmosphere and clouds and shows stars around the full sphere.
uniform int celestial_mode : hint_enum("Earth Sky", "Space Only", "Earth Without Stars") = 0;
// Adds the galactic backdrop to the Earth sky at night. Space Only includes it automatically.
uniform bool space_backdrop_on_earth = false;
// Brightness of the backdrop behind the individual stars.
uniform float space_background_strength : hint_range(0.0, 1.0, 0.01) = 0.16;
// Use an assigned equirectangular image as the backdrop. The default backdrop is procedural.
uniform bool use_space_panorama = false;
uniform sampler2D space_background : source_color, filter_linear_mipmap, repeat_enable;
// World direction from the observer to an optional ringed gas giant.
uniform vec3 planet_direction = vec3(0.35, 0.26, -0.90);
// Angular radius of the extra planet, in degrees. Zero hides the planet and rings.
uniform float planet_radius_degrees : hint_range(0.0, 24.0, 0.1) = 0.0;
// Color of the bright gas bands under neutral light.
uniform vec3 planet_color : source_color = vec3(0.85, 0.63, 0.42);
// Apparent ring opening in degrees. Positive values expose the near face of the ring.
uniform float planet_ring_tilt : hint_range(-80.0, 80.0, 0.1) = 24.0;
// Maximum opacity of the ring's bands. Zero hides the rings.
uniform float planet_ring_opacity : hint_range(0.0, 1.0, 0.01) = 0.68;

group_uniforms Cloud_Mode;
// Select the cloud renderer. Clear skips clouds and Space renders above the atmosphere.
uniform int cloud_mode : hint_enum("Volumetric", "Static", "Clear", "2D Dynamic", "Space") = 0;
// Height and horizontal frequency of the stationary layer.
uniform float static_cloud_altitude_km : hint_range(0.3, 8.0, 0.05) = 1.25;
uniform float static_cloud_scale : hint_range(0.2, 6.0, 0.05) = 1.0;
group_uniforms;

float aurora_noise(float coordinate) {
	float cell = floor(coordinate);
	float portion = fract(coordinate);
	float first = fract(sin(cell * 127.17) * 43758.5453);
	float second = fract(sin((cell + 1.0) * 127.17) * 43758.5453);
	return mix(first, second, portion * portion * (3.0 - 2.0 * portion));
}

float aurora_curtain_center(float eastward, float distance, float layer) {
	float shift = eastward + aurora_scroll + layer * 87.0;
	float wave = sin(shift * 0.018) * 71.0 + sin(shift * 0.047 + 1.3) * 25.0;
	float folding = (aurora_noise(shift * 0.041) - 0.5) * 33.0;
	return distance + wave + folding + eastward * eastward / 4900.0;
}

vec3 aurora_emission(vec3 direction) {
	float visibility = (1.0 - smoothstep(-0.20, -0.08, sun_direction.y))
		* smoothstep(0.005, 0.10, direction.y) * (1.0 - dust_density * 0.88);
	if (aurora_intensity <= 0.0 || visibility <= 0.0) {
		return vec3(0.0);
	}
	float azimuth = radians(aurora_azimuth_degrees);
	vec2 magnetic_north = vec2(sin(azimuth), -cos(azimuth));
	vec2 magnetic_east = vec2(-magnetic_north.y, magnetic_north.x);
	float forward = dot(direction.xz, magnetic_north);
	if (forward < 0.19) {
		return vec3(0.0);
	}
	float east = dot(direction.xz, magnetic_east);
	vec3 radiance = vec3(0.0);
	for (int index = 0; index < 3; index++) {
		float layer = float(index);
		float plane = aurora_distance_km + layer * 116.0;
		// Refine the nominal curtain hit against the curved and folded sheet.
		float hit = plane / forward;
		for (int refine = 0; refine < 2; refine++) {
			hit = aurora_curtain_center(east * hit, plane, layer) / forward;
		}
		float extent = 1.0 - smoothstep(470.0, 1020.0, abs(east * hit));
		for (int sample_index = 0; sample_index < 5; sample_index++) {
			float distance = hit + (float(sample_index) - 2.0) * 5.5 / forward;
			vec3 position = direction * distance;
			float eastward = east * distance;
			float center = aurora_curtain_center(eastward, plane, layer);
			float cross_sheet = (forward * distance - center) / 15.0;
			float thickness = exp(-cross_sheet * cross_sheet);
			float along = eastward + aurora_scroll + layer * 61.0;
			float fold_light = mix(0.12, 1.0, smoothstep(0.13, 0.90, aurora_noise(along * 0.030)));
			float shafts = mix(0.22, 1.0, pow(aurora_noise(along * 0.27), 1.7));
			float altitude = length(position + vec3(0.0, 6371.0, 0.0)) - 6371.0;
			float lower_edge = 93.0 + (aurora_noise(along * 0.024) - 0.5) * 15.0;
			float height = altitude - lower_edge;
			float green = smoothstep(0.0, 8.0, height) * exp(-max(height - 8.0, 0.0) / 43.0);
			float red = smoothstep(40.0, 93.0, height) * (1.0 - smoothstep(110.0, 182.0, height));
			float violet = smoothstep(-5.0, 0.0, height) * (1.0 - smoothstep(3.0, 15.0, height));
			vec3 emission = aurora_green * green + aurora_red * red * 0.19 + aurora_violet * violet * 0.28;
			float distance_fade = 1.0 - smoothstep(400.0, 1520.0, distance);
			radiance += emission * thickness * fold_light * shafts * distance_fade * extent * (0.39 - 0.065 * layer);
		}
	}
	return radiance * visibility * aurora_intensity * 0.34;
}

vec3 space_backdrop(vec3 direction, bool from_space) {
	if (space_background_strength <= 0.0 || (!from_space && !space_backdrop_on_earth)) {
		return vec3(0.0);
	}
	float visible = from_space ? 1.0 : (1.0 - smoothstep(-0.22, -0.08, sun_direction.y));
	visible *= from_space ? 1.0 : smoothstep(0.0, 0.16, direction.y) * (1.0 - dust_density);
	if (visible <= 0.0) {
		return vec3(0.0);
	}
	vec3 star_dir = normalize(star_rotation * direction);
	vec3 light;
	if (use_space_panorama) {
		vec2 uv = vec2(atan(star_dir.x, -star_dir.z) / TAU + 0.5, 0.5 - asin(clamp(star_dir.y, -1.0, 1.0)) / PI);
		float pole_margin = 0.5 / float(textureSize(space_background, 0).y);
		uv.y = clamp(uv.y, pole_margin, 1.0 - pole_margin);
		light = textureLod(space_background, uv, 0.0).rgb;
	} else {
		// Unresolved stellar light in a galactic band, broken up by dark dust lanes.
		vec3 axis = normalize(vec3(0.74, 0.41, 0.53));
		float latitude = dot(star_dir, axis);
		vec3 dust = textureLod(cloud_noise, star_dir * 0.58 + vec3(0.4, 0.6, 0.8), 0.0).rgb;
		float band = exp(-pow(latitude * 12.0, 2.0)) * (0.26 + 0.74 * dust.r);
		float lane = exp(-pow((latitude + (dust.g - 0.40) * 0.091) * 43.0, 2.0));
		float bulge = pow(max(dot(star_dir, normalize(vec3(-0.50, 0.52, 0.67))), 0.0), 8.0);
		vec3 color = mix(vec3(0.088, 0.127, 0.22), vec3(0.34, 0.24, 0.17), bulge);
		light = color * band * (0.49 + 0.51 * bulge) * (1.0 - lane * 0.70);
	}
	return light * visible * space_background_strength;
}

vec3 draw_space_planet(vec3 background, vec3 direction) {
	if (planet_radius_degrees <= 0.0 || dot(planet_direction, planet_direction) < 0.00001) {
		return background;
	}
	vec3 center_dir = normalize(planet_direction);
	float center_distance = 1.0 / sin(radians(planet_radius_degrees));
	vec3 center = center_dir * center_distance;
	float projected_center = dot(direction, center);
	if (projected_center <= 0.0 || length(cross(direction, center)) > 2.40) {
		return background;
	}
	float sphere_discriminant = 1.0 - dot(center, center) + projected_center * projected_center;
	float surface_distance = projected_center - sqrt(max(sphere_discriminant, 0.0));
	vec3 axis_hint = abs(center_dir.y) > 0.96 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
	vec3 east = normalize(cross(center_dir, axis_hint));
	vec3 north = cross(east, center_dir);
	float tilt = radians(planet_ring_tilt);
	vec3 pole = north * cos(tilt) - center_dir * sin(tilt);
	float ring_denominator = dot(direction, pole);
	float ring_depth = dot(center, pole) / (abs(ring_denominator) > 0.00001 ? ring_denominator : 0.00001);
	float ring_distance = length(direction * ring_depth - center);
	if (sphere_discriminant > 0.0) {
		vec3 surface = direction * surface_distance - center;
		float latitude = dot(surface, pole);
		vec3 turbulence = textureLod(cloud_noise, surface * vec3(0.81, 1.40, 0.81) + vec3(0.43, 0.17, 0.62), 0.0).rgb;
		float broad_bands = sin(latitude * 25.0 + (turbulence.r - 0.5) * 7.4);
		float fine_bands = sin(latitude * 74.0 + turbulence.b * 5.0);
		float bands = 0.75 + 0.14 * broad_bands + 0.06 * fine_bands - turbulence.g * 0.10;
		vec3 surface_tint = mix(vec3(0.72, 0.69, 0.64), planet_color, 0.58 + 0.31 * broad_bands);
		float lit = max(dot(surface, sun_direction), 0.0);
		float edge = smoothstep(0.0, 0.013, sphere_discriminant);
		float limb = pow(1.0 - max(dot(surface, -direction), 0.0), 5.0);
		vec3 radiance = surface_tint * bands * (0.028 + 0.94 * sqrt(lit));
		radiance += vec3(0.15, 0.12, 0.087) * limb * smoothstep(0.0, 0.30, lit);
		background = mix(background, radiance, edge);
	}
	if (planet_ring_opacity > 0.0 && ring_depth > 0.0 && ring_distance > 1.27 && ring_distance < 2.33
		&& (sphere_discriminant <= 0.0 || ring_depth < surface_distance)) {
		float edge = smoothstep(1.27, 1.38, ring_distance) * (1.0 - smoothstep(2.21, 2.33, ring_distance));
		float gap = 1.0 - smoothstep(0.016, 0.044, abs(ring_distance - 1.93));
		float bands = 0.56 + 0.20 * sin(ring_distance * 61.0) + 0.10 * sin(ring_distance * 118.0);
		float lit = 0.12 + 0.59 * sqrt(abs(dot(pole, sun_direction)));
		vec3 ring_color = mix(vec3(0.69, 0.66, 0.58), planet_color, 0.27);
		background = mix(background, ring_color * lit, edge * bands * (1.0 - 0.75 * gap) * planet_ring_opacity);
	}
	return background;
}
