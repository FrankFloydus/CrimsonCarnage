instance uniform vec3 dynamic_sky_wind_velocity = vec3(0.0);
instance uniform vec4 dynamic_sky_foliage_settings = vec4(0.0, 2.0, 0.018, 0.25);

// Model Y is the growth axis. The mask adds leaf and branch flutter over the trunk bend.
vec3 dynamic_sky_bend_foliage(vec3 vertex, mat4 model_matrix, float time, float flutter_mask) {
	vec3 wind = vec3(dynamic_sky_wind_velocity.x, 0.0, dynamic_sky_wind_velocity.z);
	float height = clamp(
		(vertex.y - dynamic_sky_foliage_settings.x) / max(dynamic_sky_foliage_settings.y, 0.001),
		0.0,
		1.0
	);
	if (dot(wind, wind) < 0.000001 || height == 0.0) {
		return vertex;
	}

	float phase = dot(model_matrix[3].xz, vec2(0.093, 0.131));
	float sway = 0.81 + 0.13 * sin(time * 1.7 + phase) + 0.06 * sin(time * 3.3 + phase * 1.31);
	float flutter = sin(time * 8.2 + phase + dot(vertex.xz, vec2(4.1, -3.7)))
		* clamp(flutter_mask, 0.0, 1.0) * dynamic_sky_foliage_settings.w;
	vec3 crosswind = vec3(-wind.z, 0.0, wind.x);
	vec3 world_bend = (wind * sway + crosswind * flutter)
		* (height * height * dynamic_sky_foliage_settings.z);
	return vertex + inverse(mat3(model_matrix)) * world_bend;
}
