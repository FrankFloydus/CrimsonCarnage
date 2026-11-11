group_uniforms Cloud_Field;
// Optional 3D formation volume. Red contains convective lobes and green stratiform density.
uniform sampler3D cloud_formation : filter_linear, repeat_enable;
// Repeatable 3D cloud shape and erosion channels.
uniform sampler3D cloud_noise : filter_linear_mipmap, repeat_enable;
// Repeatable map of cloud coverage, type, and high-layer wisps.
uniform sampler2D cloud_weather : filter_linear_mipmap, repeat_enable;
// Combined coverage of the lower cloud volume and upper wisps.
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.45;
// Horizontal wind displacement in kilometers. The field repeats every 128 units.
uniform vec2 cloud_offset = vec2(0.0);
// Lower cloud base and thickness in kilometers above the rig's sea-level origin.
uniform float cloud_base_km : hint_range(0.3, 5.0, 0.05) = 0.60;
uniform float cloud_thickness_km : hint_range(0.3, 6.0, 0.05) = 0.70;
// Extinction per kilometer in dense cloud. Larger values make it more opaque.
uniform float cloud_extinction : hint_range(0.3, 12.0, 0.05) = 10.0;
// Spatial frequency of the lower cloud volume.
uniform float low_cloud_scale : hint_range(0.5, 12.0, 0.1) = 2.4;
group_uniforms;

const float PLANET_RADIUS = 6371.0;
const float CLOUD_MAX_TRACE_DISTANCE_KM = 50.0;

float altitude_at(vec3 point) {
	// Tangent-plane expansion in kilometers around the rig's sea-level origin.
	return point.y + dot(point.xz, point.xz) / (2.0 * PLANET_RADIUS);
}

vec2 cloud_shell_hits(vec3 origin, vec3 direction, float height) {
	float b = dot(origin, direction) + PLANET_RADIUS * direction.y;
	float c = dot(origin.xz, origin.xz) + (origin.y - height) * (2.0 * PLANET_RADIUS + origin.y + height);
	float discriminant = b * b - c;
	if (discriminant < 0.0) {
		return vec2(-1.0);
	}
	float root = sqrt(discriminant);
	// Solve the larger-magnitude root directly to preserve short, nearly vertical hits.
	float distant = -b - (b >= 0.0 ? root : -root);
	float close = abs(distant) > 0.000001 ? c / distant : -b;
	return vec2(min(distant, close), max(distant, close));
}

vec2 cloud_shell_interval(vec3 origin, vec3 direction, float max_distance) {
	vec2 outer = cloud_shell_hits(origin, direction, cloud_base_km + cloud_thickness_km);
	vec2 inner = cloud_shell_hits(origin, direction, cloud_base_km);
	float start = max(outer.x, 0.0);
	float end = min(outer.y, max_distance);
	if (inner.y > start && inner.x < end) {
		if (inner.x > start) {
			end = inner.x;
		} else {
			start = inner.y;
		}
	}
	vec2 ground = cloud_shell_hits(origin, direction, 0.0);
	if (ground.x >= 0.0 && ground.x < ground.y) {
		end = min(end, ground.x);
	}
	return vec2(start, end);
}

vec3 cloud_coordinates(vec3 point) {
	vec3 coordinates = point * vec3(0.102, 0.132, 0.102) * low_cloud_scale;
	coordinates.xz += cloud_offset / 8.0;
	return coordinates + vec3(0.11, 0.41, 0.57);
}

vec2 cloud_coverage_at(vec3 point) {
	vec2 weather_uv = point.xz / 51.0 + cloud_offset / 128.0 + vec2(0.38, 0.72);
	vec2 warp = textureLod(cloud_weather, weather_uv * 2.0 + vec2(0.47, 0.23), 0.0).gb - 0.5;
	return textureLod(cloud_weather, weather_uv + warp * 0.054, 0.0).rg;
}

float noise_cloud_density_at(vec3 point, float relative_height, vec2 weather, bool detail, float coverage) {
	float overcast = smoothstep(0.66, 1.0, coverage);
	float cloud_type = smoothstep(0.26, 0.78, weather.y);
	float core = smoothstep(0.43, 0.69, weather.x);
	// Convective towers share a low flat base. Lower stratiform clouds grow into a connected deck.
	float top = mix(0.57, 0.99, cloud_type * 0.67 + core * 0.33);
	top = mix(top, mix(0.46, 0.77, cloud_type), overcast);
	float base_start = mix(0.017, 0.029 + (1.0 - core) * 0.019, 1.0 - overcast);
	float base = smoothstep(base_start, base_start + mix(0.067, 0.096, 1.0 - overcast), relative_height);
	float cap = 1.0 - smoothstep(top * mix(0.48, 0.63, cloud_type), top, relative_height);
	float profile = base * cap;
	float formation = mix(weather.x, 0.56, overcast * 0.41);
	float formation_weight = mix(0.52, 0.43, overcast);
	float taper = smoothstep(0.38, 0.96, relative_height) * mix(0.11, 0.029, overcast);
	float threshold = mix(1.00, 0.26, pow(coverage, 0.89)) + taper + (1.0 - profile) * 0.73;
	if (mix(1.0, formation, formation_weight) < threshold - 0.018) {
		return 0.0;
	}

	vec3 uvw = cloud_coordinates(point);
	vec3 shape = textureLod(cloud_noise, uvw, 0.0).rgb;
	float scallop = textureLod(cloud_noise, uvw * 2.0 + vec3(0.52, 0.23, 0.79), 0.0).r;
	float billow = shape.r * 0.70 + scallop * 0.24 + shape.g * 0.06;
	float mass = mix(billow, formation, formation_weight) - threshold;
	mass += (shape.g - 0.42) * mix(0.032, 0.084, smoothstep(0.14, 0.52, relative_height));
	if (detail && mass > -0.018) {
		vec2 erosion = textureLod(cloud_noise, uvw * 3.0 + vec3(0.27, 0.61, 0.13), 0.0).gb;
		float edge = 1.0 - smoothstep(0.012, 0.153, mass);
		float cap_detail = mix(0.59, 1.0, smoothstep(0.14, 0.55, relative_height));
		mass -= (0.124 - dot(erosion, vec2(0.115, 0.047))) * edge * cap_detail;
	}
	return smoothstep(-0.017, 0.205, mass);
}


float cloud_density_with_detail(vec3 point, float height, vec2 weather, bool detail, float detail_weight) {
	float relative_height = (height - cloud_base_km) / cloud_thickness_km;
	if (relative_height <= 0.0 || relative_height >= 1.0) {
		return 0.0;
	}
	float coverage = cloud_coverage;
	if (coverage <= 0.0) {
		return 0.0;
	}
	ivec3 formation_size = textureSize(cloud_formation, 0);
	if (formation_size.x <= 4) {
		return noise_cloud_density_at(point, relative_height, weather, detail, coverage);
	}
	float frequency = low_cloud_scale / (2.4 * 23.0);
	vec2 uv = point.xz * frequency + cloud_offset / 128.0 + vec2(0.48, 0.62);
	float overcast = smoothstep(0.68, 0.96, coverage);
	float threshold = mix(0.95, 0.19, pow(coverage, 0.72));
	float slice_count = float(formation_size.y);
	float slices = slice_count - 1.0;
	vec2 raw = textureLod(cloud_formation, vec3(uv.x, (relative_height * slices + 0.5) / slice_count, uv.y), 0.0).rg;
	float support = mix(raw.r, raw.g, overcast);
	// The unwarped support is approximate. Fade it out to avoid slicing through warped lobes.
	float support_fade = smoothstep(threshold - 0.42, threshold - 0.14, support);
	if (support_fade <= 0.0) {
		return 0.0;
	}

	vec3 uvw = cloud_coordinates(point);
	vec3 billows = textureLod(cloud_noise, uvw * 2.0 + vec3(0.12, 0.53, 0.77), 0.0).rgb;
	vec3 erosion = textureLod(cloud_noise, uvw * 5.0 + vec3(0.32, 0.13, 0.64), 0.0).rgb;
	float crown = smoothstep(0.072, 0.38, relative_height);
	float warp_weight = (1.0 - overcast * 0.65) * (1.0 - 0.64 * smoothstep(threshold + 0.06, threshold + 0.32, support));
	vec2 horizontal_warp = ((billows.gb - vec2(0.42, 0.32)) * 0.036
		+ (erosion.rg - vec2(0.73, 0.42)) * (0.013 * detail_weight)) * warp_weight;
	float vertical_warp = ((billows.r - 0.73) * 0.35 + (erosion.b - 0.32) * (0.11 * detail_weight)) * crown * warp_weight;
	float vertical = clamp(relative_height + vertical_warp, 0.0, 1.0);
	uv += horizontal_warp;
	vec2 formation = textureLod(cloud_formation, vec3(uv.x, (vertical * slices + 0.5) / slice_count, uv.y), 0.0).rg;
	float cumulus = formation.r * mix(0.89, 1.10, weather.x);
	float deck = formation.g * 1.10;
	float mass = mix(cumulus, deck, overcast) - threshold;
	if (mass < -0.16) {
		return 0.0;
	}
	mass += (billows.r - 0.73) * mix(0.21, 0.12, overcast);
	if (detail && mass > -0.065) {
		float edge = 1.0 - smoothstep(0.038, 0.26, mass);
		mass -= (0.084 - dot(erosion.gb, vec2(0.095, 0.043))) * edge * mix(0.58, 1.0, crown) * detail_weight;
	}
	return smoothstep(-0.019, 0.28, mass) * support_fade;
}



float cloud_density_at(vec3 point, float height, vec2 weather, bool detail) {
	return cloud_density_with_detail(point, height, weather, detail, 1.0);
}
