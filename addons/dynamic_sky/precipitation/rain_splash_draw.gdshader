shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

#include "res://addons/dynamic_sky/precipitation/rain/rain_contact_water.gdshaderinc"

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D scene_color : hint_screen_texture, repeat_disable, filter_linear;
instance uniform float impact_lifetime = 0.34;

uniform vec4 tint : source_color = vec4(0.63, 0.68, 0.71, 0.48);
uniform vec4 contact_tint : source_color = vec4(0.15, 0.18, 0.20, 0.15);

varying float age;
varying float phase;
varying float footprint_scale;
varying float visibility;

void vertex() {
	phase = INSTANCE_CUSTOM.w;
	float ripple_seconds = impact_lifetime * mix(0.15, 0.25, phase) / 0.34;
	age = INSTANCE_CUSTOM.x / max(ripple_seconds, 0.001);
	float view_distance = length((VIEW_MATRIX * MODEL_MATRIX[3]).xyz);
	// Source wet impacts cluster near a sampled hit, with a wider footprint farther away.
	footprint_scale = mix(3.6, 5.0, smoothstep(3.0, 10.0, view_distance));
	VERTEX.xz *= mix(0.54, 1.00, phase) * footprint_scale;
	visibility = step(0.0, INSTANCE_CUSTOM.x) * smoothstep(0.34, 0.52, view_distance) * (1.0 - smoothstep(7.0, 10.0, view_distance));
}

vec3 receiver_position(vec2 uv, mat4 inverse_projection) {
	float depth = texture(scene_depth, uv).r;
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		vec3 ndc = vec3(uv, depth) * 2.0 - 1.0;
	#else
		vec3 ndc = vec3(uv * 2.0 - 1.0, depth);
	#endif
	vec4 view_point = inverse_projection * vec4(ndc, 1.0);
	return view_point.xyz / max(view_point.w, 0.000001);
}

float impact_cluster(vec2 p, float seed, float elapsed) {
	float result = 0.0;
	for (int fleck = 0; fleck < 5; ++fleck) {
		float key = float(fleck) + 1.0;
		float azimuth = key * 2.399963 + seed * TAU;
		float radial = mix(0.05, 0.36, fract(key * 0.419 + seed * 3.73));
		radial *= mix(0.65, 1.55, sqrt(clamp(elapsed, 0.0, 1.0)));
		vec2 center = radial * vec2(cos(azimuth), sin(azimuth));
		float size = mix(0.080, 0.235, fract(key * 0.317 + seed * 9.31));
		vec2 offset = (p - center) / size;
		float influence = 1.0 - smoothstep(0.0, 1.0, dot(offset, offset));
		result = max(result, influence * mix(0.30, 0.92, fract(key * 0.719 + seed * 7.13)));
	}
	return result * smoothstep(0.0, 0.055, elapsed) * (1.0 - smoothstep(0.26, 0.92, elapsed));
}

void fragment() {
	vec2 point = (UV * 2.0 - 1.0) * footprint_scale;
	float progress = clamp(age, 0.0, 1.0);
	float angle = atan(point.y, point.x + 0.00001);
	float radius = length(point);
	float edge = 1.0 + 0.06 * sin(angle * 3.0 + phase * TAU) + 0.04 * cos(angle * 7.0);
	float ring_radius = mix(0.13, 0.84, sqrt(progress)) * edge;
	float signed_ring = radius - ring_radius;
	float footprint = min(fwidth(signed_ring), 0.10);
	float ring = 1.0 - smoothstep(0.018, 0.065 + footprint, abs(signed_ring));
	float breakup = cos(angle * 6.0 + phase * TAU) * 0.68 + sin(angle * 9.0) * 0.32;
	float beads = 0.55 + 0.45 * smoothstep(-0.4, 0.9, breakup);
	float ring_alpha = tint.a * ring * beads * (1.0 - progress) * (1.0 - progress);
	float contact_alpha = contact_tint.a * (1.0 - smoothstep(0.10, 0.25 * edge, radius))
		* (1.0 - smoothstep(0.27, 0.94, age));
	float scattered = impact_cluster(point, phase, age);
	for (int nearby = 0; nearby < 3; ++nearby) {
		float key = float(nearby) + 1.0;
		float seed = fract(phase * 19.19 + key * 0.7127);
		float a = TAU * fract(phase * 5.18 + key * 0.38197);
		float distance = mix(0.75, footprint_scale - 0.72, fract(phase * 21.17 + key * 0.53));
		vec2 center = vec2(cos(a), sin(a)) * distance;
		float time_offset = mix(0.02, 0.28, fract(seed * 9.97));
		float density = impact_cluster(point - center, seed, age - time_offset);
		scattered = max(scattered, density * mix(0.46, 0.81, seed));
	}
	float fleck_alpha = tint.a * scattered;
	float mark_alpha = ring_alpha + contact_alpha * (1.0 - ring_alpha);
	ALPHA = (fleck_alpha + mark_alpha * (1.0 - fleck_alpha)) * visibility;
	vec2 screen_slope = vec2(dFdx(radius), dFdy(radius));
	if (ALPHA < 0.002) { discard; }
	vec3 receiver = receiver_position(SCREEN_UV, INV_PROJECTION_MATRIX);
	vec3 world_receiver = (INV_VIEW_MATRIX * vec4(receiver, 1.0)).xyz;
	if (rain_contact_below_water(world_receiver)) { discard; }
	// The impact plane may extend across a stair, curb or roof edge. Only the same
	// physical receiver can display the secondary spots.
	float plane_error = abs(dot(receiver - VERTEX, normalize(NORMAL)));
	float plane_coverage = 1.0 - smoothstep(0.014, 0.035, plane_error);
	if (plane_coverage <= 0.0) { discard; }

	// Approximate the source normal decal with small changes in reflected screen radiance.
	screen_slope /= max(length(screen_slope), 0.0001);
	vec2 texel = 1.0 / VIEWPORT_SIZE;
	vec2 sample_uv = clamp(SCREEN_UV + screen_slope * sign(signed_ring) * 0.8 * texel, 0.5 * texel, 1.0 - 0.5 * texel);
	vec3 shifted_receiver = receiver_position(sample_uv, INV_PROJECTION_MATRIX);
	if (abs(dot(shifted_receiver - receiver, normalize(NORMAL))) > 0.035) { sample_uv = SCREEN_UV; }
	vec3 backdrop = texture(scene_color, SCREEN_UV).rgb;
	vec3 displaced = texture(scene_color, sample_uv).rgb;
	float luminance = dot(backdrop, vec3(0.2126, 0.7152, 0.0722));
	vec3 film = displaced + tint.rgb * (0.014 + luminance * 0.06) * (0.6 + 0.4 * beads);
	vec3 wet_mark = mix(backdrop, contact_tint.rgb, 0.45);
	vec3 flash = backdrop + tint.rgb * min(5.0 * luminance, 1.8);
	vec3 mark_radiance = film * ring_alpha + wet_mark * contact_alpha * (1.0 - ring_alpha);
	ALBEDO = (flash * fleck_alpha + mark_radiance * (1.0 - fleck_alpha)) /
		max(fleck_alpha + mark_alpha * (1.0 - fleck_alpha), 0.001);
	ALPHA *= plane_coverage;
}
