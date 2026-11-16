group_uniforms Snow_Track_Geometry;
// A SnowTrackReceiver binds these parameters on its local copy of Weather Surface.
uniform bool snow_tracks_enabled = false;
uniform sampler2D snow_track_field : filter_linear, repeat_disable;
uniform vec4 snow_track_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 snow_track_resolution = vec2(4.0);
uniform float snow_track_depth = 0.14;
uniform float snow_track_compression = 0.80;
uniform float snow_track_rim = 0.022;
uniform float snow_track_normal_strength = 1.0;
uniform bool snow_track_retain_grazing_relief = false;
group_uniforms;

float track_normal_strength_for_view(vec3 position, vec3 substrate_normal, vec3 eye) {
	if (!snow_track_retain_grazing_relief || snow_track_normal_strength <= 0.0 || snow_track_normal_strength >= 1.0) {
		return snow_track_normal_strength;
	}
	vec3 to_eye = eye - position;
	float incidence = clamp(dot(to_eye, substrate_normal) / max(length(to_eye), 0.0001), 0.0, 1.0);
	// The reference parallax uses reciprocal incidence with a 0.08 bias. Here it controls
	// only the lighting normal, fading to full slope between about 9 and 6.6 degrees.
	float reciprocal = 1.0 / (incidence + 0.08);
	float grazing = clamp((reciprocal - 1.0 / 0.235) / (1.0 / 0.195 - 1.0 / 0.235), 0.0, 1.0);
	return mix(snow_track_normal_strength, 1.0, grazing);
}

float track_shelter_exposure(vec2 ground, vec4 bounds, float yaw_degrees) {
	if (bounds.z <= 0.0 || bounds.w <= 0.0) {
		return 1.0;
	}
	float yaw = radians(yaw_degrees);
	vec2 offset = ground - bounds.xy;
	vec2 local = vec2(dot(offset, vec2(cos(yaw), -sin(yaw))), dot(offset, vec2(sin(yaw), cos(yaw))));
	vec2 margin = abs(local) - bounds.zw;
	float distance_to_roof = length(max(margin, vec2(0.0))) + min(max(margin.x, margin.y), 0.0);
	return smoothstep(0.0, 0.66, distance_to_roof);
}

float track_snow_height(vec2 uv, float cover) {
	vec2 marks = textureLod(snow_track_field, uv, 0.0).rg;
	vec2 edge = min(uv, 1.0 - uv) * snow_track_rect.zw;
	float feather = smoothstep(0.0, 0.18, min(edge.x, edge.y));
	float packed_snow = snow_track_depth * (1.0 - marks.r * snow_track_compression);
	float piled_snow = snow_track_rim * marks.g * (1.0 - marks.r);
	return (packed_snow + piled_snow) * cover * feather;
}

vec3 track_height_and_gradient(vec2 local_ground, float cover) {
	vec2 uv = (local_ground - snow_track_rect.xy) / snow_track_rect.zw;
	vec2 pixel = 1.0 / snow_track_resolution;
	vec2 offset_x = vec2(pixel.x, 0.0);
	vec2 offset_z = vec2(0.0, pixel.y);
	float height = track_snow_height(uv, cover);
	float rise_x = track_snow_height(uv + offset_x, cover) - track_snow_height(uv - offset_x, cover);
	float rise_z = track_snow_height(uv + offset_z, cover) - track_snow_height(uv - offset_z, cover);
	vec2 gradient = vec2(rise_x, rise_z) / (2.0 * pixel * snow_track_rect.zw);
	return vec3(height, gradient);
}
