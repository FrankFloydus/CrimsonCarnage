shader_type canvas_item;
render_mode blend_mul, unshaded;

// Post-tone-map approximation of the source cosine-fourth lens transmission.
uniform float vignette_intensity : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float display_response : hint_range(1.0, 2.0, 0.01) = 1.35;

void fragment() {
	vec2 position = SCREEN_UV * 2.0 - 1.0;
	float aspect = SCREEN_PIXEL_SIZE.x / SCREEN_PIXEL_SIZE.y;
	vec2 radius = position * vec2(1.0, aspect);
	float radius_squared = 2.0 * dot(radius, radius) / (1.0 + aspect * aspect);
	float transmission = pow(1.0 + vignette_intensity * vignette_intensity * radius_squared, -2.0 * display_response);
	COLOR = vec4(vec3(transmission), 1.0);
}
