shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D scene_color : hint_screen_texture, filter_nearest, repeat_disable;

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

float dither_threshold(vec2 pixel_position) {
	ivec2 cell = (ivec2(pixel_position) / max(dither_pixel_size, 1)) % 4;
	return (BAYER[cell.x][cell.y] + 0.5) / 16.0 - 0.5;
}

void fragment() {
	vec4 scene = textureLod(scene_color, SCREEN_UV, 0.0);
	vec3 graded = scene.rgb;

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
