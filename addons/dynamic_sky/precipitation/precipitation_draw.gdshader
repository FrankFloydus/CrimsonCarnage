shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D snowflake_atlas : source_color, repeat_disable, filter_linear_mipmap;
uniform int particle_kind : hint_enum("Rain", "Snow", "Dust") = 0;
uniform vec4 tint : source_color = vec4(0.58, 0.65, 0.72, 0.30);
uniform float shutter_seconds : hint_range(0.01, 0.1) = 0.035;
uniform float surface_fade_distance : hint_range(0.01, 2.0) = 0.16;
uniform vec2 near_fade_range = vec2(0.45, 1.3);
uniform vec2 far_fade_range = vec2(14.0, 24.0);
uniform float billow_alpha : hint_range(0.0, 1.0) = 0.09;

varying float opacity;
varying float phase;
varying float billow;
varying float snow_streak;
varying float snow_tumble;

float dust_noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 blend = fract(point);
	blend = blend * blend * (3.0 - 2.0 * blend);
	vec4 keys = dot(cell, vec2(37.0, 113.0)) + vec4(0.0, 37.0, 113.0, 150.0);
	vec4 corners = fract(sin(keys) * 43758.55);
	return mix(mix(corners.x, corners.y, blend.x), mix(corners.z, corners.w, blend.x), blend.y);
}

vec4 sample_snowflake(vec2 point, vec2 cell, vec2 rotation, float width) {
	vec2 rotated = mat2(rotation, vec2(-rotation.y, rotation.x)) * point;
	rotated.x /= width;
	vec2 sprite_uv = clamp(rotated * 0.5 + 0.5, vec2(0.025), vec2(0.975));
	vec4 flake = texture(snowflake_atlas, (cell + sprite_uv) * 0.5);
	return vec4(flake.rgb * flake.a, flake.a);
}

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	float particle_scale = length(MODEL_MATRIX[0].xyz);
	vec2 offset = VERTEX.xy * particle_scale;
	float age = INSTANCE_CUSTOM.z;
	float exposure_alpha = 1.0;
	phase = fract(particle_scale * 17.3);
	billow = particle_kind == 2 && particle_scale > 4.0 ? 1.0 : 0.0;
	snow_streak = 0.0;
	snow_tumble = 0.0;
	if (particle_kind != 2) {
		vec3 velocity = vec3(INSTANCE_CUSTOM.x, -INSTANCE_CUSTOM.y, INSTANCE_CUSTOM.w);
		vec3 view_velocity = mat3(VIEW_MATRIX) * velocity;
		// Align to the perspective trajectory, including lateral movement from changing depth.
		vec2 projected_velocity = view_velocity.xy - center.xy * view_velocity.z / min(-0.2, center.z);
		float projected_length = length(projected_velocity);
		if (particle_kind == 0) {
			float streak_length = clamp(projected_length * shutter_seconds, 0.025, 0.34);
			offset.y *= streak_length;
			exposure_alpha = min(1.0, sqrt(0.16 / streak_length));
		} else {
			snow_streak = smoothstep(1.15, 8.7, projected_length);
			snow_tumble = TAU * (phase + age * mix(0.24, 0.91, phase));
			offset.y *= 1.0 + snow_streak * 1.7;
			exposure_alpha = mix(0.62, 1.0, fract(phase * 7.41)) * mix(1.0, 0.72, snow_streak);
		}
		if (projected_length > 0.001) {
			vec2 along = projected_velocity / projected_length;
			offset = vec2(-along.y, along.x) * offset.x + along * offset.y;
		}
	} else if (billow > 0.5) {
		offset *= vec2(1.8 + age, 0.65 + age * 0.3);
	}
	VERTEX = center + vec3(offset, 0.0);
	float distance_to_eye = length(center);
	opacity = smoothstep(0.015, mix(0.16, 0.45, billow), age) * (1.0 - smoothstep(0.70, 1.0, age));
	opacity *= exposure_alpha * smoothstep(near_fade_range.x, near_fade_range.y, -center.z);
	opacity *= 1.0 - smoothstep(far_fade_range.x, far_fade_range.y, distance_to_eye);
}

void fragment() {
	vec2 point = UV * 2.0 - 1.0;
	float radius = length(point);
	float profile = 1.0 - smoothstep(0.22, 1.0, radius);
	vec3 particle_color = tint.rgb;
	if (particle_kind == 0) {
		float cross_section = 1.0 - smoothstep(0.0, 1.0, abs(point.x));
		float taper = 1.0 - smoothstep(0.18, 1.0, abs(point.y));
		float glint = smoothstep(0.72, 1.0, phase) * exp(-abs(point.y + 0.10) * 12.0);
		profile = cross_section * (taper * 0.84 + glint * 0.20);
	} else if (particle_kind == 1) {
		float frame = floor(phase * 4.0);
		vec2 cell = vec2(mod(frame, 2.0), floor(frame * 0.5));
		vec2 rotation = vec2(cos(snow_tumble), sin(snow_tumble));
		float width = mix(0.52, 1.0, abs(cos(snow_tumble * 0.81 + phase * TAU)));
		vec4 flake = sample_snowflake(point, cell, rotation, width);
		if (snow_streak > 0.02) {
			vec2 smear = vec2(0.0, 0.25 * snow_streak);
			flake = flake * 0.50
				+ sample_snowflake(point - smear, cell, rotation, width) * 0.32
				+ sample_snowflake(point + smear, cell, rotation, width) * 0.18;
		}
		profile = flake.a;
		particle_color *= mix(vec3(1.0), flake.rgb / max(flake.a, 0.001), 0.63);
	} else if (billow > 0.5) {
		float cloud = dust_noise(point * 3.0 + phase * 34.0);
		float detail = dust_noise(point * 6.0 - phase * 21.0);
		profile *= billow_alpha * smoothstep(0.14, 0.88, cloud * 0.72 + detail * 0.28);
	}
	float depth = texture(scene_depth, SCREEN_UV).r;
	float surface_fade = 1.0;
	if (depth > 0.000001) {
		#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
			vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
		#else
			vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
		#endif
		vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		float separation = VERTEX.z - scene_view.z / scene_view.w;
		surface_fade = smoothstep(0.0, surface_fade_distance, separation);
	}
	ALBEDO = particle_color;
	ALPHA = tint.a * profile * opacity * surface_fade;
}
