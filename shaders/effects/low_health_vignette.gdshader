shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform sampler2D mask_texture : hint_default_transparent, filter_linear, repeat_disable;
instance uniform vec4 pulse_color : source_color = vec4(1.0, 0.035, 0.085, 1.0);
instance uniform float brightness = 1.25;
instance uniform vec2 mask_size = vec2(2.1, 1.35);

void fragment() {
	vec2 viewport_size = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 mask_pixels = max(mask_size, vec2(0.01)) * (0.5 * length(viewport_size));
	vec2 mask_uv = vec2(0.5) + (UV - vec2(0.5)) * viewport_size / mask_pixels;
	float coverage = texture(mask_texture, mask_uv).a;
	COLOR = vec4(pulse_color.rgb * brightness, coverage * COLOR.a);
}
