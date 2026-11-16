#ifndef DYNAMIC_SKY_RADIAL_MATERIAL_FIELD
#define DYNAMIC_SKY_RADIAL_MATERIAL_FIELD

uniform bool dynamic_sky_radial_material_enabled = false;
uniform sampler2D dynamic_sky_radial_material_field : filter_nearest, repeat_disable;

vec4 dynamic_sky_radial_weather_at(vec3 position_world, vec4 baseline) {
	if (!dynamic_sky_radial_material_enabled) {
		return baseline;
	}
	vec4 header = texelFetch(dynamic_sky_radial_material_field, ivec2(0, 0), 0);
	vec2 local = position_world.xz - header.xy;
	vec3 coverage = baseline.xyz;
	int count = clamp(int(header.z), 0, 8);
	for (int index = 0; index < count; index++) {
		vec4 cell = texelFetch(dynamic_sky_radial_material_field, ivec2(1 + index * 2, 0), 0);
		vec2 offset = local - cell.xy;
		float distance_squared = dot(offset, offset);
		if (distance_squared >= cell.z * cell.z) {
			continue;
		}
		float weight = 1.0;
		if (distance_squared > cell.w * cell.w) {
			// Source WOV uses the authored inner radius, rather than the broader gameplay plateau.
			weight = pow(clamp((cell.z - sqrt(distance_squared)) / (cell.z - cell.w), 0.0, 1.0), 1.4);
		}
		vec4 target = texelFetch(dynamic_sky_radial_material_field, ivec2(2 + index * 2, 0), 0);
		coverage = mix(coverage, target.xyz, weight * target.w);
	}
	return vec4(coverage, baseline.w);
}

#endif
