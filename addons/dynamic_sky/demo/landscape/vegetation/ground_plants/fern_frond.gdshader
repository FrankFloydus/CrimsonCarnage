shader_type spatial;
render_mode cull_disabled, alpha_to_coverage, depth_draw_opaque, diffuse_burley;

#include "res://addons/dynamic_sky/weather/wind/foliage_wind.gdshaderinc"

uniform sampler2D frond_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D second_frond_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float leaf_transmission = 0.24;
instance uniform vec4 weather_surface = vec4(0.0);
varying vec3 physical_normal;

// UV.x 0..1 selects the first frond, 3..4 selects the second. Local U above
// 2 identifies an opaque modeled basal stem. The tags survive OBJ import.
void vertex() {
	float snow_scale = 1.0 - smoothstep(.3,.95,weather_surface.y)*.26;
	VERTEX.y *= snow_scale;
	NORMAL = normalize(vec3(NORMAL.x,NORMAL.y/snow_scale,NORMAL.z));
	physical_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL) * sign(determinant(mat3(MODEL_MATRIX)));
	float u = UV.x - (UV.x >= 3.0 ? 3.0 : 0.0);
	VERTEX = dynamic_sky_bend_foliage(VERTEX, MODEL_MATRIX, TIME, u > 2.0 ? 0.15 : 1.0);
}

void fragment() {
	bool secondary = UV.x >= 3.0;
	float u = UV.x - (secondary ? 3.0 : 0.0);
	bool stem = u > 2.0;
	vec2 uv = stem ? vec2(.49,.92) : vec2(u,UV.y);
	vec3 color = secondary ? texture(second_frond_albedo,uv).rgb : texture(frond_albedo,uv).rgb;
	float signal = max(max(color.r,color.g),color.b);
	// The original ImageGen source is a black matte. Recover coverage while
	// preserving its premultiplied edge energy; no extra raster art is created.
	float coverage = stem ? 1.0 : clamp(signal / .06, 0.0, 1.0);
	ALPHA = coverage;
	ALPHA_SCISSOR_THRESHOLD = .35;
	ALPHA_ANTIALIASING_EDGE = .08;
	ALPHA_TEXTURE_COORDINATE = UV * vec2(textureSize(frond_albedo,0));
	color /= max(coverage,.35);
	vec3 surface_normal = normalize(physical_normal) * (FRONT_FACING ? 1.0 : -1.0);
	float snow = smoothstep(.3,.9,weather_surface.y) * smoothstep(.12,.8,surface_normal.y);
	float wet = weather_surface.x * (1.0-snow);
	vec3 base = color*COLOR.rgb*(1.0-wet*.19);
	base = mix(base,vec3(.18,.14,.085),weather_surface.z*(.18+max(surface_normal.y,0.0)*.24));
	ALBEDO = mix(base,vec3(.86,.90,.94),snow);
	ROUGHNESS = mix(.84,.62,wet);
	SPECULAR = .25;
	BACKLIGHT = vec3((stem ? .07 : leaf_transmission)*(1.0-snow));
}
