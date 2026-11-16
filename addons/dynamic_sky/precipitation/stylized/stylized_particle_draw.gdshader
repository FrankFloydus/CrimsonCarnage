shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform bool snowfall = false;
uniform float daylight : hint_range(0.0, 1.0) = 1.0;
uniform vec4 particle_tint : source_color = vec4(0.79, 0.87, 0.99, 1.0);
uniform float particle_opacity : hint_range(0.0, 1.0) = 0.60;
uniform vec2 particle_size = vec2(0.033, 0.23);
uniform vec2 style_scale_opacity = vec2(1.0);
uniform float flurry_strength = 0.0;

varying float particle_fade;
varying float variation;
varying float density;

vec2 projected_up(vec3 center, vec3 upward, mat4 projection, vec2 viewport_size) {
	vec4 base_clip = projection * vec4(center, 1.0);
	vec4 tip_clip = projection * vec4(center + upward * 0.15, 1.0);
	vec2 projected = tip_clip.xy / max(tip_clip.w, 0.01) - base_clip.xy / max(base_clip.w, 0.01);
	vec2 tangent = projected * viewport_size;
	return tangent / max(length(tangent), 0.001);
}

void vertex() {
	vec3 center = MODELVIEW_MATRIX[3].xyz;
	float distance = length(center);
	float age = INSTANCE_CUSTOM.x;
	variation = INSTANCE_CUSTOM.y;
	density = INSTANCE_CUSTOM.z;
	vec2 up;
	float stretch = 1.0;
	if (snowfall) {
		float angle = (variation + age * 0.75) * 6.2831853;
		up = vec2(-sin(angle), cos(angle));
		if (flurry_strength > 0.0 && density > 0.4) {
			vec2 travel = (COLOR.rg - 0.5) * 24.0;
			vec3 upward = mat3(VIEW_MATRIX) * vec3(-travel.x, COLOR.b * 4.0, -travel.y);
			float swept = smoothstep(0.4, 0.78, density) * flurry_strength;
			vec2 direction = mix(up, projected_up(center, upward, PROJECTION_MATRIX, VIEWPORT_SIZE), swept);
			up = direction / max(length(direction), 0.001);
			stretch += swept * 0.88;
		}
	} else {
		// Project two points on a vertical world line so the sprite and fall follow the same path.
		up = projected_up(center, VIEW_MATRIX[1].xyz, PROJECTION_MATRIX, VIEWPORT_SIZE);
	}
	mat2 rotation = mat2(vec2(up.y, -up.x), up);
	float size = mix(0.47, 1.42, pow(INSTANCE_CUSTOM.w, snowfall ? 2.3 : 1.4));
	float pixel_limit = snowfall ? 8.0 : 23.0;
	vec2 proportions = snowfall ? vec2(0.76 + 0.54 * density, 1.0) : vec2(1.0, 0.72 + 0.60 * density);
	proportions.y *= stretch;
	vec2 dimensions = particle_size * size * proportions * style_scale_opacity.x;
	float pixels = 0.5 * VIEWPORT_SIZE.y * abs(PROJECTION_MATRIX[1][1]) * dimensions.y / max(-center.z, 0.25);
	vec2 offset = rotation * (VERTEX.xy * dimensions * min(1.0, pixel_limit / max(pixels, 0.01)));
	POSITION = PROJECTION_MATRIX * vec4(center + vec3(offset, 0.0), 1.0);
	particle_fade = smoothstep(0.0, 0.12, age) * (1.0 - smoothstep(0.76, 1.0, age));
	particle_fade *= smoothstep(1.2, 3.3, distance) * (1.0 - smoothstep(16.0, 28.0, distance));
	particle_fade *= mix(0.47, 1.0, density);
}

float snow_grain(vec2 point, vec2 center, vec2 radius) {
	return 1.0 - smoothstep(0.12, 1.0, length((point - center) / radius));
}

void fragment() {
	vec2 point = UV * 2.0 - 1.0;
	float mask;
	if (snowfall) {
		float lean = variation - 0.5;
		float body = snow_grain(point, vec2(lean * 0.24, -0.06), vec2(0.49, 0.56));
		float shoulder = snow_grain(point, vec2(-0.25, 0.14 + lean * 0.35), vec2(0.38, 0.31));
		float crown = snow_grain(point, vec2(0.17 + lean * 0.32, -0.29), vec2(0.27, 0.39));
		mask = 1.0 - (1.0 - body) * (1.0 - shoulder * density) * (1.0 - crown * 0.76);
	} else {
		float width = mix(0.26, 0.56, UV.y);
		mask = 1.0 - smoothstep(width * 0.22, width, abs(point.x));
		mask *= smoothstep(0.05, 0.68, UV.y) * (1.0 - smoothstep(0.79, 0.98, UV.y));
	}
	ALBEDO = particle_tint.rgb * mix(0.23, snowfall ? 0.76 : 0.57, daylight);
	ALPHA = clamp(mask * particle_opacity * particle_fade * style_scale_opacity.y, 0.0, 1.0);
}
