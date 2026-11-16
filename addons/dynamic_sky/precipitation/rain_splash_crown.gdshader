shader_type spatial;
render_mode cull_disabled, depth_draw_never, specular_disabled, fog_disabled, skip_vertex_transform;

#include "res://addons/dynamic_sky/precipitation/rain/rain_splash_light.gdshaderinc"

uniform sampler2D splash_atlas : source_color, repeat_disable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.78, 0.82, 0.86, 0.38);
uniform float visible_fraction : hint_range(0.0, 1.0) = 0.36;

instance uniform float impact_lifetime = 0.34;
const float ATLAS_BASE_UV = 0.898;

varying float progress;
varying float opacity;

vec4 sample_frame(float frame, vec2 uv) {
	vec2 cell = vec2(mod(frame, 2.0), floor(frame * 0.5));
	// The authored atlas includes padding. Crop it without resampling or replacing the artwork.
	vec2 cropped_uv = mix(vec2(0.235, 0.310), vec2(0.765, 0.680), uv);
	vec4 splash = texture(splash_atlas, (cell + cropped_uv) * 0.5);
	return vec4(splash.rgb * splash.a, splash.a);
}

void vertex() {
	vec3 center = (VIEW_MATRIX * MODEL_MATRIX[3]).xyz;
	receiver_view = center;
	vec3 surface_up = normalize(mat3(VIEW_MATRIX) * MODEL_MATRIX[1].xyz);
	vec3 across = cross(surface_up, normalize(-center));
	if (length(across) < 0.005) {
		across = mat3(VIEW_MATRIX) * MODEL_MATRIX[0].xyz;
	}
	float variation = INSTANCE_CUSTOM.w;
	float size = mix(0.66, 1.22, variation);
	vec2 quad = VERTEX.xy;
	float height = (ATLAS_BASE_UV - UV.y) * abs(quad.y) * 2.0;
	VERTEX = center + normalize(across) * quad.x * size + surface_up * height * size;
	float crown_seconds = impact_lifetime * mix(0.10, 0.20, variation) / 0.34;
	progress = clamp(INSTANCE_CUSTOM.x / max(crown_seconds, 0.001), 0.0, 1.0);
	opacity = step(0.0, INSTANCE_CUSTOM.x) * (1.0 - step(visible_fraction, fract(variation * 13.47)));
	opacity *= smoothstep(0.0, 0.15, progress) * (1.0 - smoothstep(0.72, 1.0, progress));
	opacity *= 1.0 - smoothstep(7.0, 13.0, length(center));
}

void fragment() {
	float atlas_frame = progress * 3.0;
	float first_frame = floor(atlas_frame);
	vec4 first = sample_frame(first_frame, UV);
	vec4 second = sample_frame(min(first_frame + 1.0, 3.0), UV);
	vec4 splash = mix(first, second, fract(atlas_frame));
	ALBEDO = tint.rgb * splash.rgb / max(splash.a, 0.001);
	EMISSION = ALBEDO * splash_receiver_radiance(receiver_view, PROJECTION_MATRIX, INV_PROJECTION_MATRIX, VIEWPORT_SIZE);
	// Keep colored atlas pixels on or above the local contact plane.
	float contact_clip = smoothstep(-0.008, 0.016, ATLAS_BASE_UV - UV.y);
	ALPHA = tint.a * splash.a * opacity * contact_clip;
}

void light() {
	// Average the incident light over the unresolved droplets in a crown.
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * (1.0 / PI);
}
