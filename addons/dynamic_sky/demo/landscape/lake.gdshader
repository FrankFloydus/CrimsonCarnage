shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// Wetness, snow, dust and active rain from DynamicSkySurface.
instance uniform vec4 weather_surface = vec4(0.0);
instance uniform vec2 lake_wind = vec2(2.5, 0.8);

uniform sampler2D lake_bathymetry : filter_linear, repeat_disable;
uniform sampler2D wave_slopes : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D opaque_color : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D opaque_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D opaque_normals : hint_normal_roughness_texture, filter_nearest, repeat_disable;

// Absorption per meter of water, from red to blue.
uniform vec3 absorption_per_meter = vec3(0.39, 0.145, 0.080);
uniform vec3 water_scattering : source_color = vec3(0.076, 0.205, 0.229);
uniform float swell_strength : hint_range(0.0, 2.0) = 1.0;
uniform float rain_ripple_strength : hint_range(0.0, 2.0) = 1.0;
uniform float terrain_reflection_strength : hint_range(0.0, 1.0) = 1.0;

const float WATER_F0 = 0.0204;
const float AIR_TO_WATER = 1.0 / 1.333;
const float GRAVITY = 9.81;
const float SURFACE_TENSION_OVER_DENSITY = 0.000074;
// Wavelength in meters, amplitude in meters, angle relative to the wind, phase.
const vec4 WAVE_BANDS[4] = {
	vec4(18.1, 0.135, 0.09, 0.70),
	vec4(11.7, 0.086, -0.59, 1.86),
	vec4(7.3, 0.057, 1.29, 3.28),
	vec4(0.031, 0.00037, -0.22, 5.72)
};

varying vec2 wave_position;
varying float water_level;


float bed_depth(vec2 uv) {
	// Decode two linear-filtered bytes as one 16-bit signed height relative to the lake plane.
	vec2 packed_depth = textureLod(lake_bathymetry, uv, 0.0).rg;
	return dot(packed_depth, vec2(65280.0, 255.0)) * (96.0 / 65535.0) - 32.0;
}


vec2 wind_axis() {
	return length(lake_wind) > 0.01 ? normalize(lake_wind) : vec2(0.953, 0.304);
}


float wave_amplitude() {
	return swell_strength * mix(0.27, 1.0, smoothstep(0.0, 12.0, length(lake_wind)));
}


vec2 wave_direction(vec2 axis, float angle) {
	return axis * cos(angle) + vec2(-axis.y, axis.x) * sin(angle);
}


vec2 warped_position(vec2 point) {
	// Broad cross-swells break up phase coherence without introducing tiling or cell boundaries.
	vec2 broad = vec2(
		sin(dot(point, vec2(0.058, 0.071)) + TIME * 0.16),
		sin(dot(point, vec2(0.077, -0.059)) - TIME * 0.14)
	);
	vec2 cross_wave = vec2(
		sin(dot(point, vec2(0.131, -0.106)) - TIME * 0.19),
		sin(dot(point, vec2(0.094, 0.149)) + TIME * 0.11)
	);
	return point + broad * 2.30 + cross_wave * 0.72;
}


float wave_phase(vec4 band, vec2 direction, vec2 point, float frequency) {
	float omega = sqrt(GRAVITY * frequency + SURFACE_TENSION_OVER_DENSITY * frequency * frequency * frequency);
	return dot(point, direction) * frequency - TIME * omega + band.w;
}


vec2 hash_impact(vec2 cell) {
	vec3 p = fract(vec3(cell.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.xx + p.yz) * p.zy);
}


vec2 rain_ring(vec2 position, float rain) {
	vec2 cell = floor(position);
	vec2 seed = hash_impact(cell);
	vec2 offset = fract(position) - mix(vec2(0.30), vec2(0.70), seed);
	float age = fract(TIME * (1.08 + seed.x * 0.82) + seed.y);
	float radius = age * (0.25 + seed.y * 0.07);
	float distance = length(offset);
	float band = distance - radius;
	float footprint = fwidth(distance);
	float resolved = 1.0 - smoothstep(0.012, 0.065, footprint);
	float slope = sin(band * 167.0);
	float width = 0.034 + footprint * 0.35;
	float envelope = 1.0 - smoothstep(width * 0.30, width, abs(band));
	float activity = smoothstep(seed.x * 0.89 - 0.10, seed.x * 0.89 + 0.08, rain);
	float fade = (1.0 - age) * smoothstep(0.0, 0.085, age) * envelope * activity;
	return offset / max(distance, 0.01) * slope * fade * resolved;
}


vec2 projected_uv(vec3 point, mat4 projection) {
	vec4 clip = projection * vec4(point, 1.0);
	return clip.xy / clip.w * 0.5 + 0.5;
}


bool is_on_screen(vec2 uv) {
	return all(greaterThan(uv, vec2(0.004))) && all(lessThan(uv, vec2(0.996)));
}


float view_depth(vec2 uv, mat4 inverse_projection) {
	float raw_depth = textureLod(opaque_depth, uv, 0.0).r;
	if (raw_depth <= 0.0000001) {
		return 1e6;
	}
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	raw_depth = raw_depth * 2.0 - 1.0;
#endif
	vec2 zw = inverse_projection[2].zw * raw_depth + inverse_projection[3].zw;
	return -zw.x / zw.y;
}


vec3 opaque_point(vec2 uv, mat4 inverse_projection) {
	float raw_depth = textureLod(opaque_depth, uv, 0.0).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	raw_depth = raw_depth * 2.0 - 1.0;
#endif
	vec4 point = inverse_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	return point.xyz / point.w;
}


vec4 terrain_reflection(
	vec3 start, vec3 direction, vec2 distortion, float roughness,
	mat4 projection, mat4 inverse_projection, mat4 inverse_view
) {
	float reach = mix(115.0, 360.0, smoothstep(15.0, 240.0, length(start)));
	float previous = 0.13;
	float prior_separation = -1.0;
	for (int step = 0; step < 16; step++) {
		float fraction = (float(step) + 1.0) / 16.0;
		float distance = 0.13 + reach * fraction * fraction;
		vec3 probe = start + direction * distance;
		if (probe.z >= -0.08) {
			break;
		}
		vec2 uv = projected_uv(probe, projection);
		if (!is_on_screen(uv)) {
			break;
		}
		float separation = -probe.z - view_depth(uv, inverse_projection);
		if (separation >= 0.0 && prior_separation < 0.0) {
			float low = previous;
			float high = distance;
			for (int refinement = 0; refinement < 4; refinement++) {
				float middle = (low + high) * 0.5;
				vec3 point = start + direction * middle;
				vec2 midpoint_uv = projected_uv(point, projection);
				if (-point.z > view_depth(midpoint_uv, inverse_projection)) {
					high = middle;
				} else {
					low = middle;
				}
			}
			vec3 hit = start + direction * high;
			vec2 hit_uv = projected_uv(hit, projection);
			vec3 surface = opaque_point(hit_uv, inverse_projection);
			float surface_height = (inverse_view * vec4(surface, 1.0)).y;
			float thickness = -hit.z + surface.z;
			if (surface_height > water_level + 0.35 && thickness < 1.80 + high * 0.035) {
				vec2 edge = min(hit_uv, 1.0 - hit_uv);
				vec3 surface_normal = normalize(textureLod(opaque_normals, hit_uv, 0.0).rgb * 2.0 - 1.0);
				float confidence = smoothstep(0.004, 0.085, min(edge.x, edge.y));
				confidence *= 1.0 - smoothstep(reach * 0.61, reach, high);
				confidence *= smoothstep(0.35, 2.4, surface_height - water_level);
				confidence *= smoothstep(0.025, 0.25, dot(surface_normal, -direction));
				confidence *= 1.0 - smoothstep(0.35 + high * 0.008, 1.80 + high * 0.035, thickness);
				confidence *= 0.88;
				float lod = clamp(1.2 + roughness * 9.0 + high * 0.006, 1.0, 3.8);
				vec3 color = textureLod(opaque_color, hit_uv + distortion * confidence, lod).rgb;
				return vec4(color, confidence * terrain_reflection_strength);
			}
		}
		previous = distance;
		prior_separation = separation;
	}
	return vec4(0.0);
}


void vertex() {
	water_level = MODEL_MATRIX[3].y;
	wave_position = (mat3(MODEL_MATRIX) * VERTEX).xz;
	vec2 point = warped_position(wave_position);
	vec2 axis = wind_axis();
	float elevation = 0.0;
	for (int index = 0; index < 2; index++) {
		vec4 band = WAVE_BANDS[index];
		vec2 direction = wave_direction(axis, band.z);
		elevation += band.y * sin(wave_phase(band, direction, point, TAU / band.x));
	}
	float wet_depth = bed_depth(UV);
	VERTEX.y += elevation * wave_amplitude() * smoothstep(0.16, 1.5, wet_depth);
}


void fragment() {
	vec3 world_position = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float water_depth = max(bed_depth(UV) + world_position.y - water_level, 0.0);
	float view_distance = length(VERTEX);
	float rain = weather_surface.w;
	vec2 axis = wind_axis();
	vec2 point = warped_position(wave_position);
	float patch = 0.5 + 0.5 * sin(dot(point, vec2(0.117, -0.065)) + TIME * 0.12)
		* sin(dot(point, vec2(0.071, 0.131)) - TIME * 0.16);
	float energy = wave_amplitude() * mix(0.67, 1.06, patch);
	vec2 sample_x = dFdx(wave_position);
	vec2 sample_y = dFdy(wave_position);
	vec2 gradient = vec2(0.0);
	vec2 broad_gradient = vec2(0.0);
	float unresolved_variance = 0.0;
	for (int index = 0; index < 4; index++) {
		vec4 band = WAVE_BANDS[index];
		vec2 direction = wave_direction(axis, band.z);
		float frequency = TAU / band.x;
		float phase = wave_phase(band, direction, point, frequency);
		float slope = frequency * band.y * energy;
		float footprint = max(abs(dot(sample_x, direction)), abs(dot(sample_y, direction)));
		float resolved = 1.0 - smoothstep(0.95, 3.6, frequency * footprint);
		float shore = index < 2 ? smoothstep(0.16, 1.5, water_depth) : smoothstep(0.03, 0.45, water_depth);
		vec2 band_gradient = direction * (slope * cos(phase) * resolved * shore);
		band_gradient *= index < 3 ? 0.42 : 1.0;
		gradient += band_gradient;
		if (index < 3) {
			broad_gradient += band_gradient;
		}
		unresolved_variance += slope * slope * (1.0 - resolved * resolved) * 0.5;
	}
	vec2 across = vec2(-axis.y, axis.x);
	vec2 local_position = vec2(dot(point, axis), dot(point, across));
	vec2 travel = vec2(TIME * 1.31, TIME * 0.057);
	vec4 spectrum = texture(wave_slopes, (local_position - travel) / 36.0) * 2.0 - 1.0;
	vec4 secondary = texture(wave_slopes, (local_position * 0.73 + travel * 0.63) / 36.0 + vec2(0.39, 0.17))
		* 2.0 - 1.0;
	vec2 spectrum_slope = (spectrum.rg + secondary.rg * 0.55) * 0.29
		+ (spectrum.ba + secondary.ba * 0.45) * 0.19;
	spectrum_slope *= energy * smoothstep(0.03, 0.55, water_depth);
	gradient += axis * spectrum_slope.x + across * spectrum_slope.y;
	float texel_footprint = max(length(sample_x), length(sample_y));
	unresolved_variance += energy * energy * 0.012 * smoothstep(0.03, 0.65, texel_footprint);
	float ripple_fade = 1.0 - smoothstep(19.0, 53.0, view_distance);
	float impact_variance = 0.0;
	if (rain > 0.0 && ripple_fade > 0.0) {
		vec2 rings = rain_ring(wave_position * 2.45, rain)
			+ rain_ring(wave_position * 1.92 + vec2(23.44, 8.57), rain) * 0.78;
		gradient += rings * (0.13 * ripple_fade * rain_ripple_strength);
		impact_variance = length(rings) * 0.028 * ripple_fade * rain_ripple_strength;
	}
	vec3 up = mat3(VIEW_MATRIX) * vec3(0.0, 1.0, 0.0);
	vec3 water_normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
	NORMAL = mat3(VIEW_MATRIX) * water_normal;

	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = WATER_F0 + (1.0 - WATER_F0) * pow(1.0 - facing, 5.0);
	vec3 refracted = refract(-VIEW, NORMAL, AIR_TO_WATER);
	float path = water_depth / max(-dot(refracted, up), 0.48);
	vec3 transmission = exp(-absorption_per_meter * path * mix(1.0, 1.34, rain));
	vec3 bottom_color = vec3(0.0);
	if (path < 22.0) {
		vec3 bottom = VERTEX + refracted * min(path, 16.0);
		vec2 uv = projected_uv(bottom, PROJECTION_MATRIX);
		if (is_on_screen(uv)) {
			vec3 opaque = opaque_point(uv, INV_PROJECTION_MATRIX);
			float opaque_height = (INV_VIEW_MATRIX * vec4(opaque, 1.0)).y;
			if (opaque_height > water_level + 0.05 || opaque.z >= VERTEX.z - 0.025) {
				uv = SCREEN_UV;
			}
		} else {
			uv = SCREEN_UV;
		}
		bottom_color = textureLod(opaque_color, uv, clamp(path * 0.08, 0.0, 2.5)).rgb;
		bottom_color *= 1.0 - smoothstep(15.0, 22.0, path);
	}

	float roughness = sqrt(0.0058 + 0.014 * rain + unresolved_variance * 1.8 + impact_variance);
	// Trace the broad surface, then distort the filtered hit color with the finer waves.
	vec3 broad_normal = mat3(VIEW_MATRIX) * normalize(vec3(-broad_gradient.x, 1.0, -broad_gradient.y));
	float trace_waves = mix(0.44, 0.055, smoothstep(15.0, 105.0, view_distance));
	vec3 reflection_normal = normalize(mix(up, broad_normal, trace_waves));
	vec3 reflected = reflect(-VIEW, reflection_normal);
	if (terrain_reflection_strength > 0.0 && dot(reflected, up) > 0.006 && fresnel > 0.032) {
		vec2 distortion = (NORMAL - broad_normal).xy * mix(0.044, 0.017, smoothstep(10.0, 145.0, view_distance));
		RADIANCE = terrain_reflection(
			VERTEX, reflected, distortion, roughness, PROJECTION_MATRIX, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX
		);
	}

	ALBEDO = water_scattering * (vec3(1.0) - transmission);
	EMISSION = bottom_color * transmission * (1.0 - fresnel);
	METALLIC = 0.0;
	SPECULAR = sqrt(WATER_F0 / 0.16);
	ROUGHNESS = clamp(roughness, 0.055, 0.34);
}
