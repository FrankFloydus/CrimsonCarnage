shader_type spatial;
render_mode cull_disabled, depth_draw_never, specular_disabled, fog_disabled, skip_vertex_transform;

#include "res://addons/dynamic_sky/precipitation/rain/rain_splash_light.gdshaderinc"

uniform vec4 tint : source_color = vec4(0.70, 0.78, 0.85, 0.50);
uniform float visible_fraction : hint_range(0.0, 1.0) = 0.38;
uniform vec2 launch_speed_range = vec2(0.48, 0.99);
uniform vec2 outward_speed_range = vec2(0.14, 0.48);

instance uniform float impact_lifetime = 0.34;
const float GRAVITY = 8.40248;

varying float opacity;

void vertex() {
	receiver_view = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	float elapsed = INSTANCE_CUSTOM.x;
	float seed = INSTANCE_CUSTOM.w;
	float azimuth = TAU * fract(seed * 17.51);
	float up_speed = mix(launch_speed_range.x, launch_speed_range.y, fract(seed * 27.13));
	float outward_speed = mix(outward_speed_range.x, outward_speed_range.y, fract(seed * 41.17));
	vec3 surface_up = normalize(MODEL_MATRIX[1].xyz);
	vec3 outward = cos(azimuth) * MODEL_MATRIX[0].xyz + sin(azimuth) * MODEL_MATRIX[2].xyz;
	vec3 incoming = vec3(INSTANCE_CUSTOM.y, 0.0, INSTANCE_CUSTOM.z);
	vec3 inherited = (incoming - surface_up * dot(incoming, surface_up)) * 0.08;
	vec3 launch = surface_up * up_speed + outward * outward_speed + inherited;
	vec3 displacement = launch * elapsed - vec3(0.0, 0.5 * GRAVITY * elapsed * elapsed, 0.0);
	vec3 world_position = MODEL_MATRIX[3].xyz + displacement;
	vec3 center = (VIEW_MATRIX * vec4(world_position, 1.0)).xyz;
	float distance_to_eye = length(center);
	float height = dot(displacement, surface_up);
	float size = mix(0.55, 1.18, fract(seed * 57.41));
	vec3 view_velocity = mat3(VIEW_MATRIX) * (launch - vec3(0.0, GRAVITY * elapsed, 0.0));
	vec2 apparent = view_velocity.xy - center.xy * view_velocity.z / min(center.z, -0.10);
	vec2 direction = length(apparent) > 0.001 ? normalize(apparent) : vec2(0.0, 1.0);
	vec2 side = vec2(direction.y, -direction.x);
	VERTEX = center + vec3((side * VERTEX.x + direction * VERTEX.y) * size, 0.0);
	float life = impact_lifetime * mix(0.12, 0.16, fract(seed * 33.53)) / 0.34;
	opacity = step(0.0, INSTANCE_CUSTOM.x) * (1.0 - step(visible_fraction, fract(seed * 9.59))) * smoothstep(0.0, 0.004, height);
	opacity *= 1.0 - smoothstep(life * 0.78, life, elapsed);
	opacity *= smoothstep(0.25, 0.55, distance_to_eye);
	opacity *= 1.0 - smoothstep(4.0, 9.0, distance_to_eye);
}

void fragment() {
	float profile = 1.0 - smoothstep(0.15, 1.0, length(UV * 2.0 - 1.0));
	float depth = texture(scene_depth, SCREEN_UV).r;
	float surface_fade = 1.0;
	if (depth > 0.000001) {
		#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
			vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
		#else
			vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
		#endif
		vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		surface_fade = smoothstep(0.0, 0.008, VERTEX.z - scene_view.z / max(scene_view.w, 0.000001));
	}
	ALBEDO = tint.rgb;
	EMISSION = ALBEDO * splash_receiver_radiance(receiver_view, PROJECTION_MATRIX, INV_PROJECTION_MATRIX, VIEWPORT_SIZE);
	ALPHA = tint.a * profile * opacity * surface_fade;
}

void light() {
	// Average the incident light over the unresolved rebound droplet.
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (1.0 / PI);
}
