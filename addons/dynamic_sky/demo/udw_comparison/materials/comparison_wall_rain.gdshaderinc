group_uniforms Source_Wall_Rain;
// Applies the wetness and material drips used by the source Wall Example.
uniform bool comparison_wall_wet_enabled = false;
// Original capillary height, horizontal and vertical normal gradients, and variation.
uniform sampler2D comparison_wall_drip_field : filter_linear_mipmap_anisotropic, repeat_enable;
// Visible normal strength of the slow film moving down the wall.
uniform float comparison_wall_drip_normal_gain : hint_range(0.0, 2.0, 0.05) = 1.0;
// Speed of the moving material film along world down, in meters per second.
uniform float comparison_wall_drip_speed : hint_range(0.0, 1.0, 0.01) = 0.30;
group_uniforms;


vec2 comparison_wall_drip_normal(vec2 position, float wetness, float rain, float side, float porosity) {
	vec2 uv = position / vec2(1.5, 3.0);
	float scroll = TIME * comparison_wall_drip_speed / 3.0;
	vec4 moving = texture(comparison_wall_drip_field, uv - vec2(0.0, scroll));
	float rain_weight = clamp(rain + 0.05, 0.0, 1.0);
	uv.x += (moving.r - 0.5) * rain_weight * 0.02;
	vec4 channel = texture(comparison_wall_drip_field, uv);
	float threshold = mix(1.0, mix(0.50, 0.46, porosity), side);
	float ridge = channel.r * mix(0.90, 1.10 - moving.a * 0.60, rain_weight) - threshold;
	float alpha = 0.80 * clamp(max(ridge, 0.0) * wetness * wetness * mix(25.0, 3.0, porosity), 0.0, 1.0);
	return (channel.gb - 0.5) * (alpha * mix(1.0, 1.50, porosity));
}


void apply_comparison_wall_rain(vec3 position, vec3 up, mat3 view_from_world, vec4 weather,
		inout vec3 color, inout vec3 normal_view, inout float roughness, inout float specular) {
	float wetness = clamp(weather.x * clamp(up.y + 1.5, 0.0, 1.0), 0.0, 1.0);
	if (wetness <= 0.0) {
		return;
	}
	float porosity = clamp(roughness * 1.6, 0.0, 1.0);
	color *= 1.0 - 0.30 * porosity * wetness;
	roughness = mix(roughness, comparison_water_roughness, 0.80 * wetness);
	specular = mix(specular, 0.5, 0.80 * wetness);
	if (comparison_wall_drip_normal_gain <= 0.0) {
		return;
	}
	float side = clamp((1.0 - abs(up.y)) * 3.0, 0.0, 1.0);
	vec2 weights = pow(abs(up.xz), vec2(4.0));
	weights /= max(weights.x + weights.y, 0.001);
	vec2 drip_x = comparison_wall_drip_normal(vec2(position.z, -position.y), wetness, weather.w, side, porosity);
	vec2 drip_z = comparison_wall_drip_normal(vec2(position.x, -position.y), wetness, weather.w, side, porosity);
	vec3 deviation = weights.x * vec3(0.0, -drip_x.y, drip_x.x) + weights.y * vec3(drip_z.x, -drip_z.y, 0.0);
	deviation -= up * dot(deviation, up);
	normal_view = normalize(normal_view + view_from_world * deviation * comparison_wall_drip_normal_gain);
}


vec2 comparison_wall_tile_relief(vec2 cells) {
	vec2 offset = fract(cells + 0.5) - 0.5;
	vec2 distance_to_joint = abs(offset);
	vec2 edge = smoothstep(vec2(0.0), vec2(0.008), distance_to_joint)
		* (1.0 - smoothstep(vec2(0.016), vec2(0.036), distance_to_joint));
	vec2 footprint = fwidth(cells);
	vec2 detail = 1.0 - smoothstep(vec2(0.02), vec2(0.07), footprint);
	return -sign(offset) * edge * detail * 0.28;
}
