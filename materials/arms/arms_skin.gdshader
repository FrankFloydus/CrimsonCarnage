shader_type spatial;

uniform sampler2D skin_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D skin_base_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D arm_side_mask : filter_nearest, repeat_disable;
uniform float skin_roughness : hint_range(0.0, 1.0) = 0.88;
uniform float skin_normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float skin_roughness_strength : hint_range(0.0, 2.0) = 1.0;
uniform float blood_roughness_strength : hint_range(0.0, 2.0) = 1.0;

uniform int right_tattoo_type = 0;
uniform float right_tattoo_ink_strength = 1.0;
uniform vec4 right_tattoo_ink_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform sampler2D right_tattoo_ink : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D right_tattoo_mask : hint_default_black, filter_linear_mipmap_anisotropic, repeat_disable;
uniform int left_tattoo_type = 0;
uniform float left_tattoo_ink_strength = 1.0;
uniform vec4 left_tattoo_ink_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform sampler2D left_tattoo_ink : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D left_tattoo_mask : hint_default_black, filter_linear_mipmap_anisotropic, repeat_disable;

uniform int right_scar_type = 0;
uniform float right_scar_pigment_strength = 1.0;
uniform float right_scar_relief_strength = 1.0;
uniform vec4 right_scar_dark_pigment : source_color;
uniform sampler2D right_scar_mask : hint_default_black, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D right_scar_normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec3 right_scar_finish;
uniform int left_scar_type = 0;
uniform float left_scar_pigment_strength = 1.0;
uniform float left_scar_relief_strength = 1.0;
uniform vec4 left_scar_dark_pigment : source_color;
uniform sampler2D left_scar_mask : hint_default_black, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D left_scar_normal_map : hint_normal, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec3 left_scar_finish;
uniform vec4 scar_light_pigment : source_color;

uniform int right_grime_level = 0;
uniform vec4 right_grime_tint : source_color = vec4(1.0);
uniform sampler2D right_grime_color : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D right_grime_finish : filter_linear_mipmap_anisotropic, repeat_disable;
uniform int left_grime_level = 0;
uniform vec4 left_grime_tint : source_color = vec4(1.0);
uniform sampler2D left_grime_color : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D left_grime_finish : filter_linear_mipmap_anisotropic, repeat_disable;
uniform int right_blood_level = 0;
uniform sampler2D right_blood_data : filter_linear_mipmap_anisotropic, repeat_disable;
uniform int left_blood_level = 0;
uniform sampler2D left_blood_data : filter_linear_mipmap_anisotropic, repeat_disable;

vec2 normal_slope(vec2 normal_rg) {
	vec2 xy = normal_rg * 2.0 - 1.0;
	float z = sqrt(max(1.0 - dot(xy, xy), 0.001));
	return xy / z;
}

void fragment() {
	vec3 skin = texture(skin_albedo, UV).rgb;
	vec2 skin_slope = normal_slope(texture(skin_base_normal, UV).rg);
	// UVs keep arm identity through every skinned pose.
	bool is_left = texture(arm_side_mask, UV).r > 0.5;
	vec3 scar_finish = is_left ? left_scar_finish : right_scar_finish;
	vec4 scar_dark_pigment = is_left ? left_scar_dark_pigment : right_scar_dark_pigment;
	float scar_pigment_strength = is_left ? left_scar_pigment_strength : right_scar_pigment_strength;
	float scar_relief_strength = is_left ? left_scar_relief_strength : right_scar_relief_strength;
	// R is coverage, G is dark-to-light pigment, and B is the roughness weight.
	vec3 mask = vec3(0.0);
	vec2 scar_normal = vec2(0.5);
	if (is_left && left_scar_type != 0) {
		mask = texture(left_scar_mask, UV).rgb;
		scar_normal = texture(left_scar_normal_map, UV).rg;
	} else if (!is_left && right_scar_type != 0) {
		mask = texture(right_scar_mask, UV).rgb;
		scar_normal = texture(right_scar_normal_map, UV).rg;
	}

	vec3 scar_pigment = mix(scar_dark_pigment.rgb, scar_light_pigment.rgb, mask.g);
	float pigment_strength = clamp(scar_pigment_strength, 0.0, 2.0);
	float base_pigment = scar_finish.x * min(pigment_strength, 1.0);
	float pigment_amount = mix(base_pigment, 1.0, max(pigment_strength - 1.0, 0.0));

	vec3 surface = mix(skin, scar_pigment, mask.r * pigment_amount);

	if (is_left ? left_tattoo_type != 0 : right_tattoo_type != 0) {
		vec3 ink;
		float ink_density;
		if (is_left) {
			ink = texture(left_tattoo_ink, UV).rgb;
			ink_density = texture(left_tattoo_mask, UV).r;
		} else {
			ink = texture(right_tattoo_ink, UV).rgb;
			ink_density = texture(right_tattoo_mask, UV).r;
		}
		float tattoo_ink_strength = is_left ? left_tattoo_ink_strength : right_tattoo_ink_strength;
		vec4 tattoo_ink_color = is_left ? left_tattoo_ink_color : right_tattoo_ink_color;
		// Ink stays visible through scars, with reduced strength where scar coverage is high.
		float ink_strength = tattoo_ink_strength * mix(1.0, 0.65, mask.r);
		// Skin relief breaks up the pigment at pore and crease scale.
		ink_density *= 1.0 - 0.20 * smoothstep(0.012, 0.065, length(skin_slope));
		vec3 transmission = mix(vec3(1.0), ink, ink_density);
		vec3 neutral_ink = surface * pow(max(transmission, vec3(0.001)), vec3(ink_strength));
		float color_coverage = 1.0 - pow(max(1.0 - ink_density, 0.001), ink_strength);
		vec3 bright_pigment = min(vec3(1.0), 0.16 + surface * 1.05);
		surface = mix(neutral_ink, bright_pigment, tattoo_ink_color.rgb * color_coverage);
	}

	// Add tangent-space slopes so relief changes keep the base skin detail.
	float scar_relief = mask.r * scar_finish.y * scar_relief_strength;
	vec2 combined_slope = skin_slope * clamp(skin_normal_strength, 0.0, 2.0)
		+ normal_slope(scar_normal) * scar_relief;
	float skin_finish = clamp(skin_roughness_strength, 0.0, 2.0);
	float base_roughness = mix(skin_roughness * min(skin_finish, 1.0), 1.0, max(skin_finish - 1.0, 0.0));
	float roughness = mix(base_roughness, scar_finish.z, mask.r * mask.b);

	// Soil carries premultiplied pigment plus separate relief and dry roughness.
	if (is_left ? left_grime_level != 0 : right_grime_level != 0) {
		vec4 soil = is_left ? texture(left_grime_color, UV) : texture(right_grime_color, UV);
		vec3 finish = is_left ? texture(left_grime_finish, UV).rgb : texture(right_grime_finish, UV).rgb;
		vec3 tint = is_left ? left_grime_tint.rgb : right_grime_tint.rgb;
		surface = surface * (1.0 - soil.a) + soil.rgb * tint;
		combined_slope += (finish.rg * 255.0 - 128.0) * (0.25 / 127.0);
		roughness = min(roughness + finish.b * 0.12, 1.0);
	}

	int blood_level = is_left ? left_blood_level : right_blood_level;
	if (blood_level != 0) {
		// Thickness filters the underlying color. Wetness and dense deposits vary independently.
		vec3 blood = is_left ? texture(left_blood_data, UV).rgb : texture(right_blood_data, UV).rgb;
		vec3 transmission = exp(-blood.r * vec3(0.34, 3.25, 3.84));
		vec3 film_color = vec3(0.3467041, 0.0069954, 0.0091341) * 0.37;
		vec3 pool_color = vec3(0.1559265, 0.0024282, 0.0056054);
		surface = mix(surface * transmission + film_color * (1.0 - transmission), pool_color, blood.b);
		float wetness = clamp(blood.g * clamp(blood_roughness_strength, 0.0, 2.0), 0.0, 1.0);
		roughness = mix(roughness, 0.19, wetness);
	}

	ALBEDO = surface;
	ROUGHNESS = roughness;
	NORMAL_MAP = normalize(vec3(combined_slope, 1.0)) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
}
