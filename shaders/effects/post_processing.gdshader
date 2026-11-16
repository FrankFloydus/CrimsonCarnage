shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D scene_color : hint_screen_texture, filter_linear, repeat_disable;
instance uniform bool painterly_preview_enabled = true;

group_uniforms Painterly;
uniform float painterly_strength : hint_range(0.0, 1.0, 0.01) = 0.0;
// Reach of the brush along its long axis in render pixels.
uniform float brush_radius : hint_range(2.0, 12.0, 0.5) = 7.0;
// Contrast of the elongated paint marks and their fine bristle texture.
uniform float brush_stroke_strength : hint_range(0.0, 1.0, 0.01) = 0.7;
// How much of the source is retained around high-contrast edges.
uniform float edge_sharpness : hint_range(0.0, 1.0, 0.01) = 0.9;
// Peak-to-peak brightness variation from the paper texture.
uniform float paper_grain_strength : hint_range(0.0, 0.2, 0.01) = 0.06;

group_uniforms Vignette;
uniform float vignette_strength : hint_range(0.0, 1.0, 0.01) = 0.0;
// Distances are normalized so each edge midpoint is one unit from the center.
uniform float vignette_start : hint_range(0.0, 1.4, 0.01) = 0.52;
uniform float vignette_feather : hint_range(0.01, 1.4, 0.01) = 0.65;

group_uniforms Posterization;
uniform float posterization_strength : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform int posterization_levels : hint_range(2, 64, 1) = 16;

group_uniforms Dithering;
// Peak-to-peak color offset in the screen's color range before quantization.
uniform float dither_strength : hint_range(0.0, 0.25, 0.001) = 0.0;
// Width and height of a dither cell in render pixels.
uniform int dither_pixel_size : hint_range(1, 8, 1) = 1;
group_uniforms;

const mat4 BAYER = mat4(
	vec4(0.0, 12.0, 3.0, 15.0),
	vec4(8.0, 4.0, 11.0, 7.0),
	vec4(2.0, 14.0, 1.0, 13.0),
	vec4(10.0, 6.0, 9.0, 5.0)
);
const vec3 LUMINANCE = vec3(0.2126, 0.7152, 0.0722);
const vec2 BRUSH_AXIS = vec2(0.940, 0.342);
const vec2 BRUSH_NORMAL = vec2(-0.342, 0.940);

vec4 color_moments(vec3 color) {
	return vec4(color, dot(color, color));
}

vec4 sample_moments(vec2 uv) {
	return color_moments(textureLod(scene_color, uv, 0.0).rgb);
}

vec4 paint_quadrant(
	vec2 uv, vec2 step_x, vec2 step_y, vec4 shared_moments, vec3 source, float variance_scale
) {
	vec4 moments = shared_moments;
	for (int y = 1; y <= 2; y++) {
		for (int x = 1; x <= 2; x++) {
			moments += sample_moments(uv + step_x * float(x) + step_y * float(y));
		}
	}
	moments /= 9.0;
	float variance = max(moments.a - dot(moments.rgb, moments.rgb), 0.0);
	vec3 difference = moments.rgb - source;
	float contrast = (variance + 0.5 * dot(difference, difference)) * variance_scale;
	float weight = 1.0 / (1.0 + contrast * contrast);
	return vec4(moments.rgb * weight, weight);
}

float paint_luminance(vec3 color) {
	return 0.04 + dot(max(color, vec3(0.0)), LUMINANCE);
}

vec3 paint_color(vec2 uv, vec2 pixel_size, vec3 source) {
	vec2 step_x = BRUSH_AXIS * pixel_size * (brush_radius * 0.5);
	vec2 step_y = BRUSH_NORMAL * pixel_size * (brush_radius * 0.35);
	vec4 center = color_moments(source);
	vec4 right = sample_moments(uv + step_x) + sample_moments(uv + 2.0 * step_x);
	vec4 left = sample_moments(uv - step_x) + sample_moments(uv - 2.0 * step_x);
	vec4 down = sample_moments(uv + step_y) + sample_moments(uv + 2.0 * step_y);
	vec4 up = sample_moments(uv - step_y) + sample_moments(uv - 2.0 * step_y);

	// A soft Kuwahara filter favors flat color regions without hard quadrant switches.
	float luminance = paint_luminance(source);
	float variance_scale = 32.0 / (luminance * luminance);
	vec4 weighted = paint_quadrant(uv, step_x, step_y, center + right + down, source, variance_scale);
	weighted += paint_quadrant(uv, -step_x, step_y, center + left + down, source, variance_scale);
	weighted += paint_quadrant(uv, step_x, -step_y, center + right + up, source, variance_scale);
	weighted += paint_quadrant(uv, -step_x, -step_y, center + left + up, source, variance_scale);
	return weighted.rgb / max(weighted.a, 1e-20);
}

vec3 paint_tones(vec3 color) {
	// Shape the tonal transitions in perceptual space while keeping the original hue.
	float tone = sqrt(max(dot(color, LUMINANCE), 0.0)) * 16.0;
	float shaped = floor(tone) + smoothstep(0.15, 0.85, fract(tone));
	float ratio = (shaped + 0.001) / (tone + 0.001);
	return color * mix(1.0, ratio * ratio, 0.7);
}

float cell_noise(ivec2 cell) {
	uvec2 pixel = uvec2(cell);
	uint bits = (pixel.x * 1597334677u) ^ (pixel.y * 3812015801u);
	bits = (bits ^ (bits >> 16u)) * 2246822519u;
	return float(bits >> 24u) / 255.0;
}

float brush_noise(vec2 uv) {
	ivec2 cell = ivec2(floor(uv));
	vec2 blend = smoothstep(vec2(0.0), vec2(1.0), fract(uv));
	float top = mix(cell_noise(cell), cell_noise(cell + ivec2(1, 0)), blend.x);
	float bottom = mix(cell_noise(cell + ivec2(0, 1)), cell_noise(cell + ivec2(1, 1)), blend.x);
	return mix(top, bottom, blend.y);
}

float brush_strokes(vec2 pixel_position) {
	vec2 position = vec2(dot(pixel_position, BRUSH_AXIS), dot(pixel_position, BRUSH_NORMAL));
	vec2 uv = position / (brush_radius * vec2(2.2, 0.36));
	float stroke = brush_noise(uv);
	vec2 bristle_uv = uv * vec2(1.55, 2.7) + vec2(13.2, 7.8 + 0.55 * stroke);
	float bristles = brush_noise(bristle_uv);
	return (stroke - 0.5) * 0.30 + (bristles - 0.5) * 0.16;
}

float edge_mask(vec2 uv, vec2 pixel_size, vec3 source) {
	// Compare to the center so both sides of narrow lines can retain their detail.
	vec2 step_x = vec2(pixel_size.x, 0.0);
	vec2 step_y = vec2(0.0, pixel_size.y);
	vec3 left = textureLod(scene_color, uv - step_x, 0.0).rgb - source;
	vec3 right = textureLod(scene_color, uv + step_x, 0.0).rgb - source;
	vec3 up = textureLod(scene_color, uv - step_y, 0.0).rgb - source;
	vec3 down = textureLod(scene_color, uv + step_y, 0.0).rgb - source;
	float contrast = max(max(dot(left, left), dot(right, right)), max(dot(up, up), dot(down, down)));
	float luminance = paint_luminance(source);
	return smoothstep(0.008, 0.14, contrast / (luminance * luminance));
}

float dither_threshold(vec2 pixel_position) {
	ivec2 cell = (ivec2(pixel_position) / max(dither_pixel_size, 1)) % 4;
	return (BAYER[cell.x][cell.y] + 0.5) / 16.0 - 0.5;
}

void fragment() {
	vec4 scene = textureLod(scene_color, SCREEN_UV, 0.0);
	vec3 graded = scene.rgb;

	if (painterly_preview_enabled && painterly_strength > 0.0) {
		vec3 painted = paint_tones(paint_color(SCREEN_UV, SCREEN_PIXEL_SIZE, scene.rgb));
		if (brush_stroke_strength > 0.0) {
			painted *= 1.0 + brush_strokes(FRAGCOORD.xy) * brush_stroke_strength;
		}
		painted *= 1.0 + (cell_noise(ivec2(FRAGCOORD.xy)) - 0.5) * paper_grain_strength;
		float paint_mix = painterly_strength;
		if (edge_sharpness > 0.0) {
			paint_mix *= 1.0 - edge_mask(SCREEN_UV, SCREEN_PIXEL_SIZE, scene.rgb) * edge_sharpness;
		}
		graded = mix(graded, painted, paint_mix);
	}
	if (vignette_strength > 0.0) {
		float radius = length(SCREEN_UV * 2.0 - vec2(1.0));
		float edge = smoothstep(vignette_start, vignette_start + vignette_feather, radius);
		graded *= 1.0 - edge * vignette_strength;
	}
	if (dither_strength > 0.0) {
		graded = clamp(graded + dither_threshold(FRAGCOORD.xy) * dither_strength, 0.0, 1.0);
	}
	if (posterization_strength > 0.0) {
		float steps = float(max(posterization_levels - 1, 1));
		vec3 quantized = floor(clamp(graded, 0.0, 1.0) * steps + 0.5) / steps;
		graded = mix(graded, quantized, posterization_strength);
	}
	COLOR = vec4(graded, scene.a);
}
