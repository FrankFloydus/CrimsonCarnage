// The existing Exposure Settings and Water Regions supply the physical cutoff.
const int MAX_RAIN_WATER_REGIONS = 8;
uniform float rain_water_plane = -1e20;
uniform int rain_water_count = 0;
uniform vec4 rain_water_regions[24];

bool rain_contact_below_water(vec3 point) {
	if (point.y <= rain_water_plane) {
		return true;
	}
	for (int i = 0; i < rain_water_count; ++i) {
		vec4 x = rain_water_regions[i * 3];
		vec4 z = rain_water_regions[i * 3 + 1];
		vec4 shape = rain_water_regions[i * 3 + 2];
		if (point.y > shape.x) {
			continue;
		}
		vec2 p = vec2(dot(x.xy, point.xz) + x.z, dot(z.xy, point.xz) + z.z);
		if (shape.y > 0.5 ? dot(p, p) <= x.w * x.w : all(lessThanEqual(abs(p), vec2(x.w, z.w)))) {
			return true;
		}
	}
	return false;
}
