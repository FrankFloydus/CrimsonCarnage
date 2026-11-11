shader_type canvas_item;
render_mode unshaded, blend_add;

// Peak linear light sent to the HDR viewport before bloom.
uniform float emission_energy : hint_range(0.0, 12.0, 0.05) = 4.0;

varying vec4 marker_tint;

void vertex() {
	marker_tint = COLOR;
}

void fragment() {
	float mask = texture(TEXTURE, UV).a;
	vec2 distance_to_edge = min(UV, vec2(1.0) - UV);
	vec2 edge_fade = smoothstep(vec2(0.0), fwidth(UV), distance_to_edge);
	float peak = max(marker_tint.r, max(marker_tint.g, marker_tint.b));
	vec3 tint = marker_tint.rgb / max(peak, 0.001);
	COLOR = vec4(tint * emission_energy, mask * edge_fade.x * edge_fade.y * marker_tint.a);
}
