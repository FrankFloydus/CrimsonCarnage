float snow_deposit_cell(vec2 cell) {
	vec3 p = fract(vec3(cell.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}


float snow_deposit_noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 t = fract(point);
	t = t * t * (3.0 - 2.0 * t);
	float a = mix(snow_deposit_cell(cell), snow_deposit_cell(cell + vec2(1.0, 0.0)), t.x);
	float b = mix(snow_deposit_cell(cell + vec2(0.0, 1.0)), snow_deposit_cell(cell + 1.0), t.x);
	float footprint = max(length(dFdx(point)), length(dFdy(point)));
	return mix(mix(a, b, t.y), 0.5, smoothstep(0.24, 0.85, footprint));
}


float snow_deposition(vec2 ground, float facing_up, float coverage, float exposure, float scale) {
	if (coverage <= 0.015) {
		return 0.0;
	}
	vec2 point = ground * scale;
	vec2 warp = vec2(
		snow_deposit_noise(point * 0.59 + vec2(1.7, 8.2)),
		snow_deposit_noise(point * 0.67 + vec2(6.6, 2.4))
	) - 0.5;
	vec2 drift = vec2(point.x * 0.77 + point.y * 0.41, point.y * 1.52) + warp * 0.87;
	float patch = snow_deposit_noise(drift * 0.49) * 0.70
		+ snow_deposit_noise(drift * 1.46 + vec2(4.5, 2.1)) * 0.23
		+ snow_deposit_noise(drift * 5.6 + vec2(8.1, 6.3)) * 0.07;
	float settled = coverage * exposure;
	float retention = smoothstep(0.32, 0.86, facing_up);
	float threshold = mix(0.26, 0.66, patch) + (1.0 - retention) * 0.34;
	float feather = clamp(0.12 + fwidth(threshold) * 0.82, 0.12, 0.20);
	float broken_cover = smoothstep(threshold - feather, threshold + feather, settled) * retention;
	float blanket = smoothstep(0.68, 0.97, settled) * smoothstep(0.70, 0.92, facing_up);
	return mix(broken_cover, 1.0, blanket) * smoothstep(0.015, 0.12, settled);
}
