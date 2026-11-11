shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 tint : source_color = vec4(0.63, 0.68, 0.71, 0.48);
uniform vec4 contact_tint : source_color = vec4(0.15, 0.18, 0.20, 0.15);

varying float age;
varying float phase;

void vertex() {
	age = clamp(INSTANCE_CUSTOM.z, 0.0, 1.0);
	phase = INSTANCE_CUSTOM.w;
	VERTEX.xz *= mix(0.55, 1.25, phase);
}

void fragment() {
	vec2 point = UV * 2.0 - 1.0;
	float angle = atan(point.y, point.x + 0.00001);
	float radius = length(point);
	float edge = 1.0 + 0.06 * sin(angle * 3.0 + phase * TAU) + 0.04 * cos(angle * 7.0);
	float ring_radius = mix(0.13, 0.84, sqrt(age)) * edge;
	float ring = 1.0 - smoothstep(0.025, 0.12, abs(radius - ring_radius));
	float breakup = cos(angle * 6.0 + phase * TAU) * 0.68 + sin(angle * 9.0) * 0.32;
	float beads = 0.2 + 0.8 * smoothstep(-0.4, 0.9, breakup);
	float ring_alpha = tint.a * ring * beads * (1.0 - age) * (1.0 - age);
	float contact_alpha = contact_tint.a * (1.0 - smoothstep(0.10, 0.25 * edge, radius))
		* (1.0 - smoothstep(0.27, 0.94, age));
	ALPHA = ring_alpha + contact_alpha * (1.0 - ring_alpha);
	ALBEDO = mix(contact_tint.rgb, tint.rgb, ring_alpha / max(ALPHA, 0.001));
}
