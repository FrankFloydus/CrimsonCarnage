shader_type canvas_item;
render_mode unshaded, blend_mul;

uniform sampler2D mask_texture : hint_default_transparent, filter_linear, repeat_disable;
uniform vec4 tint : source_color = vec4(0.48, 0.055, 0.075, 1.0);
// Width and height of the centered mask in units of half the viewport diagonal.
uniform vec2 mask_size = vec2(2.5, 1.5);

void fragment() {
	if (COLOR.a <= 0.0) {
		discard;
	}
	vec2 viewport_size = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 mask_pixels = max(mask_size, vec2(0.01)) * (0.5 * length(viewport_size));
	vec2 mask_uv = vec2(0.5) + (UV - vec2(0.5)) * viewport_size / mask_pixels;
	float coverage = texture(mask_texture, mask_uv).a;
	float strength = coverage * COLOR.a * tint.a;
	COLOR = vec4(mix(vec3(1.0), tint.rgb, strength), 1.0);
}
