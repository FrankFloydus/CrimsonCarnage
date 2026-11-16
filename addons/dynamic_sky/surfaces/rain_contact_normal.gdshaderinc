#ifndef DYNAMIC_SKY_RAIN_CONTACT_NORMAL
#define DYNAMIC_SKY_RAIN_CONTACT_NORMAL

// A runtime-local material receives the atlas for its own World3D.
uniform sampler2D rain_contact_field : filter_nearest, repeat_disable;
uniform vec4 rain_contact_mapping = vec4(0.0);
uniform float rain_contact_gain = 0.0;

vec3 rain_contact_surface_stamp(vec3 point, float footprint) {
	vec2 uv = (point.xz - rain_contact_mapping.xy) * rain_contact_mapping.z + vec2(0.5);
	vec2 edge = min(uv, vec2(1.0) - uv);
	float edge_metres = min(edge.x, edge.y) / rain_contact_mapping.z;
	float weight = smoothstep(0.05, 0.65, edge_metres) * (1.0 - smoothstep(0.012, 0.04, footprint));
	if (weight <= 0.0) {
		return vec3(0.0);
	}
	vec3 stamp = texture(rain_contact_field, uv).rgb;
	if (stamp.b < 0.11) {
		return vec3(0.0);
	}
	float height_m = (stamp.b - 0.5) * 32.0 + rain_contact_mapping.w;
	weight *= 1.0 - smoothstep(0.018, 0.036, abs(point.y - height_m));
	return vec3((stamp.rg - vec2(0.5)) / 1.75, weight);
}

#endif
