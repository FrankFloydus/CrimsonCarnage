shader_type canvas_item;
render_mode unshaded;

uniform vec2 night_grade = vec2(0.0);
uniform bool night_grade_linear_buffer = false;
uniform sampler2D scene_color : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D frost_texture : filter_linear_mipmap, repeat_enable;
uniform float wetness = 0.0;
uniform float frost = 0.0;
uniform float heat = 0.0;
uniform vec2 droplet_travel = vec2(0.0);
uniform float horizon = 0.5;
uniform float droplet_scale = 1.0;
uniform float droplet_refraction = 0.00833;
uniform float frost_opacity = 0.67;
uniform float frost_scale = 1.2;
uniform float frost_refraction = 0.00194;
uniform vec4 frost_tint : source_color = vec4(0.79, 0.86, 0.92, 1.0);
uniform float heat_refraction = 0.0024;
uniform float heat_horizon_width = 0.24;


vec3 hash_cell(vec2 cell) {
	vec3 p = fract(vec3(cell.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yzz) * p.zyx);
}


vec4 water_beads(vec2 lens, float grid, vec2 travel, float activity, float seed_offset) {
	vec2 point = lens * grid - travel * grid;
	// Different neighbor indices can name different drops across a grid boundary.
	// Differentiate the continuous lens coordinates before selecting a droplet.
	vec2 point_dx = dFdx(point);
	vec2 point_dy = dFdy(point);
	vec2 cell = floor(point);
	vec2 displacement = vec2(0.0);
	float coverage = 0.0;
	float dome = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 neighbor = cell + vec2(float(x), float(y));
			vec3 seed = hash_cell(neighbor + vec2(seed_offset, 13.47));
			float alive = smoothstep(seed.z * 0.94 - 0.04, seed.z * 0.94 + 0.08, activity);
			vec2 center = neighbor + mix(vec2(0.22), vec2(0.78), seed.xy);
			vec2 scale = vec2(mix(0.86, 1.16, seed.y), mix(0.72, 1.08, seed.x));
			vec2 local = (point - center) * scale;
			float radius = mix(0.088, 0.175, seed.x);
			local.x += local.y * local.y * 0.40;
			float local_length = length(local);
			float radial = local_length / radius;
			vec2 local_dx = point_dx * scale;
			vec2 local_dy = point_dy * scale;
			local_dx.x += 0.8 * local.y * local_dx.y;
			local_dy.x += 0.8 * local.y * local_dy.y;
			vec2 radial_gradient = local / (radius * max(local_length, 0.0001));
			float pixel_edge = clamp(
				abs(dot(radial_gradient, local_dx)) + abs(dot(radial_gradient, local_dy)),
				0.015, 0.65
			);
			float silhouette = (1.0 - smoothstep(0.95 - pixel_edge, 1.0 + pixel_edge, radial)) * alive;
			float cap = sqrt(max(1.0 - radial * radial, 0.0));
			vec2 normal = local / max(radius * max(cap, 0.28), 0.001);
			displacement += normal * silhouette * 0.44;
			coverage = max(coverage, silhouette);
			dome = max(dome, cap * silhouette);
		}
	}
	return vec4(displacement, coverage, dome);
}


vec3 index_gradient(vec2 point) {
	vec2 cell = floor(point);
	vec2 local = fract(point);
	float a = hash_cell(cell).x;
	float b = hash_cell(cell + vec2(1.0, 0.0)).x;
	float c = hash_cell(cell + vec2(0.0, 1.0)).x;
	float d = hash_cell(cell + vec2(1.0)).x;
	vec2 weight = local * local * (3.0 - 2.0 * local);
	vec2 derivative = 6.0 * local * (1.0 - local);
	float cross_term = a - b - c + d;
	float value = a + (b - a) * weight.x + (c - a) * weight.y + cross_term * weight.x * weight.y;
	vec2 gradient = derivative * (vec2(b - a, c - a) + cross_term * weight.yx);
	return vec3(value, gradient);
}


vec3 encode_display_rgb(vec3 linear_color) {
	vec3 color = max(linear_color, vec3(0.0));
	return mix(1.055 * pow(color, vec3(1.0 / 2.4)) - 0.055, 12.92 * color,
		lessThanEqual(color, vec3(0.0031308)));
}


vec3 decode_display_rgb(vec3 display_color) {
	vec3 color = max(display_color, vec3(0.0));
	return mix(pow((color + 0.055) / 1.055, vec3(2.4)), color / 12.92,
		lessThanEqual(color, vec3(0.04045)));
}


vec3 apply_night_grade(vec3 color) {
	vec3 display_color = night_grade_linear_buffer ? encode_display_rgb(color) : color;
	float luma = dot(display_color, vec3(0.2126, 0.7152, 0.0722));
	if (luma >= night_grade.y) {
		return color;
	}
	float gain = mix(0.08, 1.0, smoothstep(0.025, max(night_grade.y, 0.026), luma));
	float neutral_end = min(0.25, night_grade.y);
	float neutral_start = min(0.12, 0.5 * neutral_end);
	float neutral = 0.07 * (1.0 - smoothstep(neutral_start, neutral_end, luma));
	vec3 graded = mix(display_color, vec3(luma), neutral) * gain;
	vec3 blended = mix(display_color, graded, night_grade.x);
	return night_grade_linear_buffer ? decode_display_rgb(blended) : blended;
}


void fragment() {
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 lens = (SCREEN_UV - vec2(0.5)) * vec2(aspect, 1.0);
	vec2 offset = vec2(0.0);
	float water_mask = 0.0;
	float water_dome = 0.0;
	if (wetness > 0.001) {
		vec2 point = lens / droplet_scale;
		vec4 small = water_beads(point, 16.7, vec2(0.0), wetness * 0.78, 4.39);
		vec4 large = water_beads(point, 8.3, droplet_travel / droplet_scale, wetness * 0.60, 31.72);
		offset += (small.xy * 0.59 + large.xy) * droplet_refraction * droplet_scale;
		water_mask = max(small.z, large.z);
		water_dome = max(small.w, large.w);
	}
	if (heat > 0.001 && horizon > -0.5 && horizon < 1.3) {
		vec2 thermal_position = lens * vec2(34.0, 18.0) + vec2(TIME * 0.14, TIME * 1.22);
		vec2 gradient = index_gradient(thermal_position).yz;
		gradient += index_gradient(thermal_position * 2.11 + vec2(17.4, -TIME * 0.58)).yz * 0.38;
		gradient += index_gradient(thermal_position * 4.07 + vec2(8.3, TIME * 0.42)).yz * 0.13;
		float band = (SCREEN_UV.y - horizon - 0.055) / max(heat_horizon_width, 0.01);
		float layer = exp(-band * band * 3.0);
		layer *= smoothstep(0.0, 0.06, SCREEN_UV.y) * (1.0 - smoothstep(0.89, 1.0, SCREEN_UV.y));
		offset += gradient * vec2(0.52, 1.0) * heat * heat_refraction * layer;
	}

	float ice_mask = 0.0;
	float ice_blur = 0.0;
	if (frost > 0.001 && textureSize(frost_texture, 0).x > 4) {
		vec2 ice_uv = lens * (1.30 / frost_scale) + vec2(0.43, 0.61);
		float density = texture(frost_texture, ice_uv).r;
		vec2 edge = min(SCREEN_UV, 1.0 - SCREEN_UV);
		float edge_distance = min(edge.x, edge.y);
		float growth = smoothstep(-0.06, 0.16, frost - edge_distance * 1.78);
		ice_mask = smoothstep(0.012, 0.32, density) * growth * frost_opacity;
		vec2 texel = 1.0 / vec2(textureSize(frost_texture, 0));
		vec2 gradient = vec2(
			texture(frost_texture, ice_uv + vec2(texel.x, 0.0)).r
				- texture(frost_texture, ice_uv - vec2(texel.x, 0.0)).r,
			texture(frost_texture, ice_uv + vec2(0.0, texel.y)).r
				- texture(frost_texture, ice_uv - vec2(0.0, texel.y)).r
		);
		offset += gradient * frost_refraction * growth;
		ice_blur = ice_mask * 2.7;
	}
	offset.x /= aspect;
	vec2 sample_uv = clamp(SCREEN_UV + offset, SCREEN_PIXEL_SIZE * 0.5, 1.0 - SCREEN_PIXEL_SIZE * 0.5);
	float blur = max(ice_blur, water_dome * 0.75);
	vec3 color = textureLod(scene_color, sample_uv, blur).rgb;
	if (night_grade.x > 0.001) {
		color = apply_night_grade(color);
	}
	if (water_mask > 0.0) {
		float rim = water_mask * (1.0 - water_dome) * (1.0 - water_dome);
		float brightness = dot(color, vec3(0.2126, 0.7152, 0.0722));
		color += vec3(brightness * 0.038) * rim;
	}
	if (ice_mask > 0.0) {
		float illumination = clamp(dot(color, vec3(0.2126, 0.7152, 0.0722)) * 0.75 + 0.22, 0.08, 0.92);
		color = mix(color, frost_tint.rgb * illumination, ice_mask * 0.71);
	}
	COLOR = vec4(color, 1.0);
}
