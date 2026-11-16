#ifndef DYNAMIC_SKY_RAIN_PUDDLES
#define DYNAMIC_SKY_RAIN_PUDDLES

const float RAIN_POOL_MAX_SLOPE_VARIANCE = 0.00028;

vec2 rain_puddle_hash(vec2 cell) {
	vec3 p = fract(vec3(cell.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.xx + p.yz) * p.zy);
}

float rain_puddle_noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 blend = smoothstep(vec2(0.0), vec2(1.0), fract(point));
	float low = mix(rain_puddle_hash(cell).x, rain_puddle_hash(cell + vec2(1.0, 0.0)).x, blend.x);
	float high = mix(rain_puddle_hash(cell + vec2(0.0, 1.0)).x, rain_puddle_hash(cell + vec2(1.0)).x, blend.x);
	return mix(low, high, blend.y);
}

vec2 rain_puddle_coverage(vec2 ground, float scale, float threshold, float cavity_bias,
		float occlusion, float wetness, float up, float footprint) {
	float saturation = smoothstep(0.32, 0.90, wetness);
	float slope = smoothstep(0.91, 0.985, up);
	vec2 point = ground * scale;
	float basin = rain_puddle_noise(point) * 0.83
		+ rain_puddle_noise(point * 3.17 + vec2(2.9, 7.1)) * 0.17;
	basin += cavity_bias * smoothstep(0.02, 0.20, 1.0 - occlusion) * 0.26;
	float lip = threshold + mix(0.12, -0.045, saturation);
	float bank_width = clamp(0.021 + footprint * scale * 0.70, 0.021, 0.13);
	float cover = smoothstep(lip - bank_width, lip + bank_width, basin);
	float depth = smoothstep(lip - bank_width, lip + 0.16, basin);
	return vec2(cover, depth) * saturation * slope;
}

float rain_puddle_lod(float footprint) {
	return 1.0 - smoothstep(0.008, 0.033, footprint);
}

float rain_puddle_filtered_roughness(float roughness, float pool_depth, float resolved_normal, float slope_variance) {
	// GGX uses squared perceptual roughness. Combine its square with the missing tangent slope variance.
	float unresolved = pool_depth * pool_depth * (1.0 - resolved_normal * resolved_normal) * slope_variance;
	if (unresolved <= 0.0) {
		return roughness;
	}
	float alpha = roughness * roughness;
	return sqrt(sqrt(alpha * alpha + unresolved));
}

float rain_procedural_pool_variance(float scale, float rain) {
	// The procedural ring kernel's full-rain, per-axis variance scales with the square of its repeats per meter.
	float full_rain_variance = min(0.000104 * scale * scale, RAIN_POOL_MAX_SLOPE_VARIANCE);
	float ring_occupancy = rain * (0.86 + 0.14 * rain);
	return full_rain_variance * ring_occupancy;
}

// xz holds the pool normal offset. y holds a separate, longer-lived roughness spot.
vec3 rain_puddle_impacts(
		vec2 ground, float scale, float rain, float footprint, float time,
		bool include_wet_film, out vec2 film_normal) {
	film_normal = vec2(0.0);
	vec2 coordinates = ground * scale;
	vec2 home = floor(coordinates);
	vec2 normal_offset = vec2(0.0);
	float spots = 0.0;
	float detail = rain_puddle_lod(footprint);
	float radius_scale = min(1.0, 9.0 / scale);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell = home + vec2(float(x), float(y));
			vec2 random = rain_puddle_hash(cell + vec2(4.2, 32.1));
			vec2 center = cell + mix(vec2(0.14), vec2(0.86), random);
			vec2 offset = (coordinates - center) / scale;
			float radius = length(offset);
			float ring_period = mix(0.29, 0.48, random.x);
			float ring_lifetime = mix(0.17, 0.25, random.y);
			float seconds = fract(time / ring_period + random.y) * ring_period;
			float age = seconds / ring_lifetime;
			float density = smoothstep(random.x - 0.16, random.x + 0.16, rain);
			if (age < 1.0 && radius < 0.10 * radius_scale && density > 0.0) {
				float ring_radius = mix(0.009, 0.070, age) * mix(0.86, 1.14, random.x) * radius_scale;
				float width = mix(0.0065, 0.011, age) * radius_scale;
				float filtered_width = sqrt(width * width + footprint * footprint * 0.36);
				float phase = (radius - ring_radius) / filtered_width;
				float envelope = smoothstep(0.0, 0.09, age) * (1.0 - smoothstep(0.46, 1.0, age));
				float trough_phase = phase + 1.85;
				float profile_slope = -phase * exp(-0.5 * phase * phase)
					+ 0.28 * trough_phase * exp(-0.5 * trough_phase * trough_phase);
				float height_slope = profile_slope * (0.0052 * width / (filtered_width * filtered_width))
					* envelope * smoothstep(0.0, 0.004, radius);
				normal_offset -= offset / max(radius, 0.001) * height_slope * density;
			}
			if (include_wet_film) {
				// Bound each thin-film mark to a 7–14 cm diameter and a 0.15–0.25 s lifetime.
				float diameter = mix(0.07, 0.14, random.x);
				float unit_radius = radius / diameter;
				float film_age = seconds / mix(0.15, 0.25, random.y);
				if (unit_radius < 0.5 && film_age < 1.0 && density > 0.0) {
					float aperture = clamp((1.0 - 2.0 * unit_radius) * 5.0, 0.0, 1.0);
					float age_fade = min(film_age * 10.0, (1.0 - film_age) / 0.90);
					float radians_per_meter = TAU * 2.5 / diameter;
					float footprint_cycles = 2.5 * footprint / diameter;
					float antialias = 1.0 - smoothstep(0.28, 0.52, footprint_cycles);
					vec2 radial = offset / max(radius, 0.001);
					float angle = random.y * TAU;
					float alignment = dot(radial, vec2(cos(angle), sin(angle)));
					float quadratic = 2.0 * alignment * alignment - 1.0;
					float cubic = alignment * (4.0 * alignment * alignment - 3.0);
					float wave_radius = radius * (1.0 + 0.095 * quadratic);
					float around_ring = clamp(0.70 + 0.24 * alignment + 0.13 * cubic, 0.34, 1.0);
					float wave = sin(wave_radius * radians_per_meter - 3.0 * TAU * time);
					float slope = wave * aperture * age_fade * antialias * density * around_ring;
					film_normal -= radial * slope * smoothstep(0.0, 0.004, radius);
				}
			}
			vec2 spot_random = rain_puddle_hash(cell + vec2(25.4, 16.8));
			vec2 spot_center = cell + mix(vec2(0.12), vec2(0.88), spot_random);
			float spot_radius = length((coordinates - spot_center) / scale);
			float spot_age = fract(time * mix(0.95, 1.28, spot_random.y) + spot_random.x);
			float spot_size = mix(0.020, 0.035, spot_random.y);
			float spot = (1.0 - smoothstep(spot_size * 0.28, spot_size, spot_radius))
				* (1.0 - smoothstep(0.32, 1.0, spot_age))
				* smoothstep(spot_random.x - 0.18, spot_random.x + 0.18, rain);
			spots = max(spots, spot);
		}
	}
	film_normal *= detail;
	return vec3(normal_offset.x, spots, normal_offset.y) * detail;
}

vec3 rain_puddle_impacts(vec2 ground, float scale, float rain, float footprint, float time) {
	vec2 unused_film_normal;
	return rain_puddle_impacts(ground, scale, rain, footprint, time, false, unused_film_normal);
}

#endif
