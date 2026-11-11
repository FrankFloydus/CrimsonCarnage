// Use the same world-space footprint on every receiving material that crosses an eave.
float surface_weather_exposure(vec2 ground, vec4 bounds, float yaw_degrees) {
	if (bounds.z <= 0.0 || bounds.w <= 0.0) {
		return 1.0;
	}
	float yaw = radians(yaw_degrees);
	vec2 offset = ground - bounds.xy;
	vec2 local = vec2(dot(offset, vec2(cos(yaw), -sin(yaw))), dot(offset, vec2(sin(yaw), cos(yaw))));
	vec2 margin = abs(local) - bounds.zw;
	float edge_distance = length(max(margin, vec2(0.0))) + min(max(margin.x, margin.y), 0.0);
	float coarse_drift = snow_deposit_noise(local * 1.26 + vec2(3.5, 2.6)) - 0.5;
	float broken_edge = snow_deposit_noise(local * 5.2 + vec2(2.8, 7.1)) - 0.5;
	float windblown_edge = edge_distance + coarse_drift * 0.78 + broken_edge * 0.16;
	return smoothstep(-0.72, 0.36, windblown_edge);
}
