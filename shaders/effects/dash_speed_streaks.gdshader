shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D scene_color : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D flow_map : hint_default_transparent, filter_linear, repeat_disable;
// Displacement scale in fractions of the shorter viewport side.
uniform float distortion_strength : hint_range(0.0, 0.06, 0.001) = 0.020;
// Length of the scene-color trails in fractions of the shorter viewport side.
uniform float radial_streak_length : hint_range(0.0, 0.12, 0.001) = 0.065;
// Seconds for the initial shockwave to expand and disappear.
uniform float burst_duration : hint_range(0.01, 0.5, 0.01) = 0.12;
uniform float burst_strength : hint_range(0.0, 1.0, 0.01) = 0.65;
uniform vec4 streak_tint : source_color = vec4(0.81, 0.91, 1.0, 0.0);
instance uniform float dash_age = 0.0;

const int TRAIL_SAMPLES = 8;

vec3 read_layer(vec2 offset) {
	vec4 field = texture(flow_map, vec2(0.5) + offset);
	return vec3(field.rg * 2.0 - 1.0, field.b) * field.a;
}

void fragment() {
	vec2 viewport_size = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 centered = (SCREEN_UV - vec2(0.5)) * viewport_size / length(viewport_size);
	float burst_progress = clamp(dash_age / max(burst_duration, 0.001), 0.0, 1.0);
	vec3 sustained = read_layer(centered * (0.96 - 0.10 * sin(dash_age * 4.0)));
	vec3 burst = read_layer(centered * mix(1.30, 0.82, burst_progress));
	vec3 layer = sustained + burst * (1.0 - burst_progress) * burst_strength;

	vec2 border_pixels = min(SCREEN_UV, vec2(1.0) - SCREEN_UV) * viewport_size;
	float border_fade = smoothstep(0.0, 14.0, min(border_pixels.x, border_pixels.y));
	float strength = distortion_strength * COLOR.a * border_fade;
	float reference_size = min(viewport_size.x, viewport_size.y);
	vec2 offset = layer.xy * strength * reference_size * SCREEN_PIXEL_SIZE;
	vec2 scene_uv = SCREEN_UV + offset;
	vec4 scene = texture(scene_color, scene_uv);

	float spoke = clamp(layer.z, 0.0, 1.0);
	float trail_weight = smoothstep(0.015, 0.45, spoke) * COLOR.a * border_fade;
	if (radial_streak_length > 0.0 && trail_weight > 0.002) {
		// Pull samples from farther inward on this ray so details trail outward.
		vec2 ray = centered / max(length(centered), 0.001);
		vec2 step_uv = ray * (radial_streak_length * reference_size * COLOR.a / float(TRAIL_SAMPLES)) * SCREEN_PIXEL_SIZE;
		vec3 trail = vec3(0.0);
		float total_weight = 0.0;
		for (int tap = 1; tap <= TRAIL_SAMPLES; tap++) {
			float sample_weight = float(TRAIL_SAMPLES + 1 - tap);
			trail += textureLod(scene_color, scene_uv - step_uv * float(tap), 0.0).rgb * sample_weight;
			total_weight += sample_weight;
		}
		scene.rgb = mix(scene.rgb, trail / total_weight, trail_weight);
	}

	COLOR = vec4(mix(scene.rgb, streak_tint.rgb, spoke * COLOR.a * streak_tint.a), scene.a);
}
