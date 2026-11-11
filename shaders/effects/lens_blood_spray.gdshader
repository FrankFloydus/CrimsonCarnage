shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform float softness_mip_level : hint_range(0.0, 6.0, 0.1) = 4.4;
uniform float coverage_gain : hint_range(1.0, 12.0, 0.1) = 5.7;

varying vec4 sprite_tint;

void vertex() {
	sprite_tint = COLOR;
}

void fragment() {
	// Sample an averaged mask so enlarged flecks read as an out-of-focus stain.
	float intensity = textureLod(TEXTURE, UV, softness_mip_level).r;
	float fringe = smoothstep(0.008, 0.026, intensity);
	float coverage = fringe * (1.0 - exp(-intensity * coverage_gain));
	COLOR = vec4(sprite_tint.rgb, sprite_tint.a * coverage);
}
