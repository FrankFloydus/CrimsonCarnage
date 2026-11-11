shader_type fog;

uniform sampler3D density_noise : filter_linear, repeat_enable;
uniform vec3 mist_color : source_color = vec3(0.80, 0.84, 0.90);
uniform float mass_density = 0.0;
uniform float height_scale = 3.0;
uniform float ground_height = 0.0;
uniform vec2 wind_travel = vec2(0.0);
uniform vec3 camera_position = vec3(0.0);
uniform float shelter = 0.0;
// Linear source radiance, independent of density. Godot applies the density during injection.
uniform vec3 ambient_scattering = vec3(0.0);

float scattering_dither(vec3 position) {
	vec3 cell = fract(floor(position * 8.0) * vec3(0.1031, 0.1030, 0.0973));
	cell += dot(cell, cell.yxz + 33.33);
	return fract((cell.x + cell.y) * cell.z);
}

void fog() {
	vec3 point = WORLD_POSITION;
	vec2 advected = (point.xz - wind_travel) / 64.0;
	float elevation = point.y - ground_height;
	vec3 coordinates = vec3(advected.x, point.y / 18.0, advected.y);
	float broad = texture(density_noise, coordinates).r;
	float fine = texture(density_noise, coordinates * 2.0 + vec3(0.24, 0.49, 0.63)).g;
	float pocket = smoothstep(0.26, 0.76, broad * 0.72 + fine * 0.28);
	float layer = exp(-max(elevation, 0.0) / max(height_scale, 0.1));
	layer *= smoothstep(-1.0, 0.22, elevation);
	vec2 from_center = abs(UVW.xz - vec2(0.5));
	float edge = 1.0 - smoothstep(0.39, 0.5, max(from_center.x, from_center.y));
	float sheltered = shelter * (1.0 - smoothstep(2.0, 13.0, length(point - camera_position)));
	DENSITY = mass_density * mix(0.19, 1.36, pocket) * layer * edge * (1.0 - sheltered);
	ALBEDO = mist_color;
	// Fog injection truncates R/G at 1/511 and B at 1/255 after multiplying density.
	// Unbiased spatial rounding preserves faint neutral fill through that packed buffer.
	vec3 packing_step = vec3(1.0 / 511.0, 1.0 / 511.0, 1.0 / 255.0);
	vec3 rounding = packing_step * scattering_dither(point) / max(DENSITY, 0.001);
	EMISSION = ambient_scattering + rounding;
}
