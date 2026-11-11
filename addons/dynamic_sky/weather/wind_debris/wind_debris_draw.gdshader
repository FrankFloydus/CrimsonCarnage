shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx;

uniform vec3 dry_color : source_color = vec3(0.31, 0.22, 0.11);
uniform vec3 pale_color : source_color = vec3(0.57, 0.44, 0.24);
uniform float vein_contrast : hint_range(0.0, 1.0) = 0.32;
uniform float openness : hint_range(0.0, 1.0) = 1.0;

varying vec3 world_position;
varying vec4 fragment_state;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	fragment_state = INSTANCE_CUSTOM;
}

void fragment() {
	float distance_to_camera = distance(CAMERA_POSITION_WORLD, world_position);
	float view_fade = smoothstep(0.36, 1.0, distance_to_camera) * (1.0 - smoothstep(13.0, 22.0, distance_to_camera));
	float sheltered = mix(smoothstep(1.2, 5.0, distance_to_camera), 1.0, openness);
	float life = smoothstep(0.0, 0.12, fragment_state.y) * (1.0 - smoothstep(0.78, 1.0, fragment_state.y));
	float contact = 1.0 - smoothstep(0.015, 0.34, fragment_state.w);
	float rib = exp(-abs(UV.y - 0.5) * 28.0);
	float grain = sin(UV.x * 63.0 + UV.y * 11.0 + fragment_state.x * 13.0) * 0.065;
	float tint = clamp(fragment_state.x * 0.78 + rib * vein_contrast + grain, 0.0, 1.0);
	ALBEDO = mix(dry_color, pale_color, tint);
	ROUGHNESS = 0.86;
	SPECULAR = 0.24;
	ALPHA = life * view_fade * sheltered * contact;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
