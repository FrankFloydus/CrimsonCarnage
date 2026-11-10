shader_type spatial;

uniform sampler2D splatter_compact : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D splatter_fan : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D splatter_compact_orm : filter_linear_mipmap, repeat_disable;
uniform sampler2D splatter_fan_orm : filter_linear_mipmap, repeat_disable;
uniform bool use_compact_orm = false;
uniform bool use_fan_orm = false;
uniform float wet_roughness : hint_range(0.0, 1.0) = 0.48;

// Five vectors per stain. Keep the capacity in sync with BloodComponent.
uniform vec4 blood_stains[60];
uniform int blood_stain_count = 0;

varying vec3 bind_position;
varying vec3 bind_normal;

void vertex() {
	bind_position = CUSTOM0.xyz;
	bind_normal = CUSTOM1.xyz;
}

void fragment() {
	vec3 surface_normal = normalize(bind_normal);
	vec3 position_dx = dFdx(bind_position);
	vec3 position_dy = dFdy(bind_position);
	vec3 albedo = COLOR.rgb;
	float roughness = 0.83;
	int count = clamp(blood_stain_count, 0, blood_stains.length() / 5);
	for (int stain = 0; stain < count; stain++) {
		int index = stain * 5;
		vec4 center = blood_stains[index];
		vec4 plane = blood_stains[index + 1];
		vec3 offset = bind_position - center.xyz;
		float depth = abs(dot(offset, plane.xyz));
		float facing = smoothstep(0.16, 0.65, dot(surface_normal, plane.xyz));
		if (depth >= plane.w || facing <= 0.0) {
			continue;
		}

		vec4 tangent = blood_stains[index + 2];
		vec4 bitangent = blood_stains[index + 3];
		vec3 u_axis = bitangent.xyz / bitangent.w;
		vec3 v_axis = tangent.xyz / tangent.w;
		vec2 stain_uv = vec2(dot(offset, u_axis), dot(offset, v_axis)) + vec2(0.5);
		if (any(lessThan(stain_uv, vec2(0.0))) || any(greaterThan(stain_uv, vec2(1.0)))) {
			continue;
		}
		vec2 uv_dx = vec2(dot(position_dx, u_axis), dot(position_dx, v_axis));
		vec2 uv_dy = vec2(dot(position_dy, u_axis), dot(position_dy, v_axis));
		float within_depth = 1.0 - smoothstep(0.5 * plane.w, plane.w, depth);
		vec4 tint = blood_stains[index + 4];
		vec4 deposit;
		float deposit_roughness = wet_roughness;
		if (tint.w < 0.5) {
			deposit = textureGrad(splatter_compact, stain_uv, uv_dx, uv_dy);
			if (use_compact_orm) {
				deposit_roughness = textureGrad(splatter_compact_orm, stain_uv, uv_dx, uv_dy).g;
			}
		} else {
			deposit = textureGrad(splatter_fan, stain_uv, uv_dx, uv_dy);
			if (use_fan_orm) {
				deposit_roughness = textureGrad(splatter_fan_orm, stain_uv, uv_dx, uv_dy).g;
			}
		}
		float coverage = deposit.a * within_depth * facing * center.w;
		albedo = mix(albedo, deposit.rgb * tint.rgb, coverage);
		roughness = mix(roughness, deposit_roughness, coverage);
	}

	ALBEDO = albedo;
	ROUGHNESS = roughness;
}
