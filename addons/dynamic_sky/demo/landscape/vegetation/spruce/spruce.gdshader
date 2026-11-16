shader_type spatial;
render_mode cull_disabled, alpha_to_coverage, depth_draw_opaque, specular_schlick_ggx;

#include "res://addons/dynamic_sky/weather/wind/foliage_wind.gdshaderinc"

uniform sampler2D spruce_bough : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D bark_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bark_normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D bark_orm_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 needle_tint : source_color = vec3(0.84, 0.88, 0.85);
uniform float alpha_cutoff : hint_range(0.1, 0.8) = 0.35;
uniform float needle_backlight : hint_range(0.0, 0.5) = 0.18;
uniform float needle_normal_bend : hint_range(0.0, 1.0) = 0.68;

instance uniform vec4 weather_surface = vec4(0.0);

varying float model_height;
varying float crown_radius;
varying vec3 crown_position;
varying vec3 canopy_normal;
// Unbent geometric normal, independent of camera-facing and needle lighting.
varying vec3 deposition_world_normal;

void vertex() {
	model_height = VERTEX.y;
	deposition_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL) * sign(determinant(mat3(MODEL_MATRIX)));
	crown_radius = length(VERTEX.xz);
	crown_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	canopy_normal = normalize(mat3(MODEL_MATRIX) * normalize(vec3(VERTEX.x * 0.36, 0.67, VERTEX.z * 0.36)));
	float flexible = smoothstep(0.14, 1.6, length(VERTEX.xz)) * (1.0 - step(1.10, UV.x));
	VERTEX = dynamic_sky_bend_foliage(VERTEX, MODEL_MATRIX, TIME, flexible);
}

void fragment() {
	bool wood = UV.x > 1.10;
	bool physical_needle = UV.x < -1.10;
	vec2 branch_uv = physical_needle ? vec2(-UV.x - 1.2, UV.y) : UV;
	vec4 branch = texture(spruce_bough, branch_uv);
	ALPHA = wood || physical_needle ? 1.0 : branch.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;
	ALPHA_ANTIALIASING_EDGE = 0.08;
	ALPHA_TEXTURE_COORDINATE = branch_uv * vec2(textureSize(spruce_bough, 0));
	// Forward+ already faces cull_disabled normals toward the visible side.
	if (wood) {
		vec2 bark_uv = vec2((UV.x - 1.23) * 3.2, UV.y * 0.64);
		vec3 bark = texture(bark_texture, bark_uv).rgb;
		vec3 orm = texture(bark_orm_texture, bark_uv).rgb;
		ALBEDO = bark * COLOR.rgb * mix(vec3(0.62, 0.58, 0.49), vec3(0.88, 0.82, 0.72), smoothstep(0.0, 2.0, model_height));
		NORMAL_MAP = texture(bark_normal_texture, bark_uv).rgb;
		NORMAL_MAP_DEPTH = 0.55;
		AO = orm.r;
		ROUGHNESS = clamp(orm.g, 0.80, 1.0);
		SPECULAR = 0.18;
	} else {
		// A spray represents many cylindrical needles. Bend its lighting normal toward the
		// crown envelope so a flat sheet does not shade as one dark planar underside.
		if (!physical_needle) {
			NORMAL = normalize(mix(NORMAL, normalize(mat3(VIEW_MATRIX) * canopy_normal), needle_normal_bend));
		}
		ALBEDO = branch.rgb * needle_tint * COLOR.rgb;
		ROUGHNESS = mix(0.94, 0.76, clamp(dot(branch.rgb, vec3(0.2, 0.6, 0.2)) * 2.2, 0.0, 1.0));
		SPECULAR = 0.28;
		AO = mix(0.76, 1.0, smoothstep(0.4, 1.9, crown_radius));
		// Native lighting multiplies the complete diffuse response by ALBEDO once.
		// This is the transmitted fraction; tinting it again squares needle reflectance.
		BACKLIGHT = vec3(needle_backlight);
	}
	// A card has two physical sides. Only its upward visible side carries snow.
	vec3 deposition_normal = normalize(deposition_world_normal) * (FRONT_FACING ? 1.0 : -1.0);
	float snow_exposure = smoothstep(0.08, 0.77, deposition_normal.y);
	float exposed = smoothstep(0.08, 0.77, (mat3(INV_VIEW_MATRIX) * NORMAL).y);
	float drift = sin(dot(crown_position, vec3(1.67, 1.82, 1.35))) * 0.54
		+ cos(dot(crown_position, vec3(-3.12, 4.41, 2.67))) * 0.46;
	float snowline = weather_surface.y - (0.52 + drift * 0.22);
	float feather = clamp(fwidth(snowline) * 0.75, 0.027, 0.12);
	float snow = smoothstep(-feather, 0.14 + feather, snowline) * snow_exposure;
	snow *= 1.0 - clamp(length(dynamic_sky_wind_velocity) * 0.013, 0.0, 0.33);
	float wet = weather_surface.x * (1.0 - snow);
	float dust = weather_surface.z * (0.19 + exposed * 0.26) * (1.0 - snow);
	ALBEDO *= 1.0 - wet * 0.31;
	ALBEDO = mix(ALBEDO, vec3(0.176, 0.134, 0.093), dust);
	ALBEDO = mix(ALBEDO, vec3(0.66, 0.75, 0.84) * (0.94 + drift * 0.04), snow);
	ROUGHNESS = mix(mix(ROUGHNESS, 0.54, wet), 0.82, snow);
	BACKLIGHT *= 1.0 - snow * 0.85;
}
