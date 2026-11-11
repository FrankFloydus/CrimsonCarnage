shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform vec4 drop_color : source_color = vec4(1.0);
uniform float softness : hint_range(0.0, 2.0, 0.05) = 0.0;

varying float sprite_opacity;

void vertex() {
	sprite_opacity = COLOR.a;
}

void fragment() {
	float coverage = texture(TEXTURE, UV, softness).a;
	COLOR = vec4(drop_color.rgb, coverage * drop_color.a * sprite_opacity);
}
