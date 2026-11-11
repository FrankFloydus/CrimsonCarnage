shader_type spatial;

#include "res://addons/dynamic_sky/surfaces/snow_deposition.gdshaderinc"
#include "res://addons/dynamic_sky/surfaces/surface_shelter.gdshaderinc"
#include "res://addons/dynamic_sky/surfaces/material_sampling.gdshaderinc"

// Water, snow, dust, and current rain intensity. Each mesh has an independent state.
instance uniform vec4 weather_surface = vec4(0.0);

group_uniforms Base_Material;
uniform vec4 base_color : source_color = vec4(0.34, 0.29, 0.23, 1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roughness_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
// Packed base-material occlusion, roughness and metallic in R, G and B.
uniform sampler2D orm_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_orm_map = false;
uniform vec2 uv_scale = vec2(1.0);
uniform float roughness : hint_range(0.1, 1.0) = 0.88;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
// World-space projection for irregular rocks and other meshes without reliable authored UVs.
uniform bool use_world_triplanar = false;
uniform float world_texture_scale : hint_range(0.01, 5.0, 0.01) = 0.4545;
uniform bool use_macro_material = false;
uniform sampler2D macro_normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D macro_orm_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float macro_texture_scale : hint_range(0.01, 2.0, 0.01) = 0.2778;
uniform float macro_normal_strength : hint_range(0.0, 2.0, 0.01) = 0.70;

group_uniforms Weather_Response;
uniform vec4 snow_color : source_color = vec4(0.99, 0.995, 1.0, 1.0);
uniform vec4 dust_color : source_color = vec4(0.67, 0.49, 0.29, 1.0);
uniform float puddle_scale : hint_range(0.05, 10.0) = 1.2;
uniform float puddle_threshold : hint_range(0.0, 1.0) = 0.57;
// Roughness of the center of a fully wet puddle.
uniform float puddle_roughness : hint_range(0.02, 0.5, 0.005) = 0.065;
// Favors authored AO crevices and breaks up the puddle boundary with finer variation.
uniform float puddle_cavity_bias : hint_range(0.0, 0.5, 0.01) = 0.0;
uniform float ripple_scale : hint_range(1.0, 15.0) = 6.0;
uniform float coating_scale : hint_range(0.1, 12.0) = 2.5;
// X/Z center and local half extents of an optional shelter footprint in meters.
uniform vec4 shelter_bounds = vec4(0.0);
uniform float shelter_yaw_degrees = 0.0;

group_uniforms Snow_Material;
// Optional seamless snow material maps, projected in world space at a physical scale.
uniform bool use_snow_material = false;
uniform sampler2D snow_albedo_texture : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D snow_normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D snow_orm_texture : filter_linear_mipmap_anisotropic, repeat_enable;
// Snow texture repeats per meter and tangent-space normal amplitude.
uniform float snow_texture_scale : hint_range(0.1, 10.0, 0.025) = 0.625;
uniform float snow_normal_strength : hint_range(0.0, 2.0, 0.05) = 0.58;
uniform float snow_drift_scale : hint_range(0.1, 5.0, 0.01) = 1.20;
group_uniforms;

varying vec3 world_position;
varying vec3 world_normal;


vec2 hash_cell(vec2 cell) {
	vec3 p = fract(vec3(cell.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yzx + 33.33);
	return fract((p.xx + p.yz) * p.zy);
}


float noise_2d(vec2 point) {
	vec2 cell = floor(point);
	vec2 t = fract(point);
	t = t * t * (3.0 - 2.0 * t);
	float a = mix(hash_cell(cell).x, hash_cell(cell + vec2(1.0, 0.0)).x, t.x);
	float b = mix(hash_cell(cell + vec2(0.0, 1.0)).x, hash_cell(cell + vec2(1.0)).x, t.x);
	return mix(a, b, t.y);
}


float filtered_noise(vec2 point) {
	float footprint = max(length(dFdx(point)), length(dFdy(point)));
	return mix(noise_2d(point), 0.5, smoothstep(0.23, 0.88, footprint));
}


float snow_crystal_glint(vec2 ground) {
	vec2 cells = ground * 34.0;
	float footprint = max(length(dFdx(cells)), length(dFdy(cells)));
	vec2 random = hash_cell(floor(cells) + vec2(12.4, 25.1));
	vec2 point = fract(cells) - mix(vec2(0.23), vec2(0.77), random);
	float feather = clamp(footprint, 0.025, 0.18);
	float flake = 1.0 - smoothstep(0.09 - feather, 0.09 + feather, length(point));
	return flake * smoothstep(0.91, 0.993, random.y) * (1.0 - smoothstep(0.16, 0.61, footprint));
}


vec3 triplanar_sample(
	sampler2D map, vec3 point, vec3 point_dx, vec3 point_dy, vec3 signs, vec3 weights
) {
	vec2 x_orientation = vec2(-signs.x, 1.0);
	vec2 y_orientation = vec2(1.0, -signs.y);
	vec2 z_orientation = vec2(signs.z, 1.0);
	vec3 x_axis = textureGrad(map, point.zy * x_orientation, point_dx.zy * x_orientation, point_dy.zy * x_orientation).rgb;
	vec3 y_axis = textureGrad(map, point.xz * y_orientation, point_dx.xz * y_orientation, point_dy.xz * y_orientation).rgb;
	vec3 z_axis = textureGrad(map, point.xy * z_orientation, point_dx.xy * z_orientation, point_dy.xy * z_orientation).rgb;
	return x_axis * weights.x + y_axis * weights.y + z_axis * weights.z;
}


vec3 triplanar_snow_normal(
	vec3 point, vec3 point_dx, vec3 point_dy, vec3 signs, vec3 weights, vec3 geometry_normal
) {
	vec2 x_orientation = vec2(-signs.x, 1.0);
	vec2 y_orientation = vec2(1.0, -signs.y);
	vec2 z_orientation = vec2(signs.z, 1.0);
	vec2 x = textureGrad(snow_normal_texture, point.zy * x_orientation, point_dx.zy * x_orientation, point_dy.zy * x_orientation).rg * 2.0 - 1.0;
	vec2 y = textureGrad(snow_normal_texture, point.xz * y_orientation, point_dx.xz * y_orientation, point_dy.xz * y_orientation).rg * 2.0 - 1.0;
	vec2 z = textureGrad(snow_normal_texture, point.xy * z_orientation, point_dx.xy * z_orientation, point_dy.xy * z_orientation).rg * 2.0 - 1.0;
	vec3 deviation = vec3(0.0, x.y, -x.x * signs.x) * weights.x
		+ vec3(y.x, 0.0, -y.y * signs.y) * weights.y
		+ vec3(z.x * signs.z, z.y, 0.0) * weights.z;
	deviation -= geometry_normal * dot(deviation, geometry_normal);
	return normalize(geometry_normal + deviation * snow_normal_strength);
}


vec2 ripple_gradient(vec2 point, vec2 offset, float rain) {
	vec2 cell = floor(point + offset);
	vec2 random = hash_cell(cell + offset * 17.0);
	vec2 from_impact = fract(point + offset) - (0.22 + random * 0.56);
	float radius = length(from_impact);
	float age = fract(TIME * (1.8 + random.x) + random.y);
	float phase = radius - age * 0.31;
	float wave = sin(phase * 185.0) * (1.0 - smoothstep(0.0, 0.08, abs(phase)));
	float envelope = (1.0 - age) * (1.0 - smoothstep(0.24, 0.34, radius));
	float density = smoothstep(random.y - 0.2, random.y + 0.2, rain);
	return from_impact / max(radius, 0.01) * wave * envelope * density;
}


void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}


void fragment() {
	vec2 surface_uv = UV * uv_scale;
	vec3 base = texture(albedo_texture, surface_uv).rgb * base_color.rgb;
	vec3 base_orm = use_orm_map
		? texture(orm_texture, surface_uv).rgb
		: vec3(1.0, texture(roughness_texture, surface_uv).r, 0.0);
	vec3 base_normal = texture(normal_texture, surface_uv).rgb;
	vec3 up = normalize(world_normal);
	float base_normal_depth = normal_strength;
	if (use_world_triplanar) {
		vec3 weights = pow(abs(up), vec3(4.0));
		weights /= max(weights.x + weights.y + weights.z, 0.001);
		vec3 signs = step(vec3(0.0), up) * 2.0 - 1.0;
		vec3 point = world_position * world_texture_scale;
		TerrainPBR material = terrain_triplanar(
			albedo_texture, normal_texture, orm_texture, point, dFdx(point), dFdy(point),
			weights, signs, 1.8, 0.42
		);
		vec3 deviation = material.deviation * normal_strength;
		base = material.albedo * base_color.rgb;
		base_orm = material.orm;
		if (use_macro_material) {
			vec3 macro_point = world_position * macro_texture_scale;
			TerrainPBR macro_material = terrain_triplanar(
				albedo_texture, macro_normal_texture, macro_orm_texture,
				macro_point, dFdx(macro_point), dFdy(macro_point), weights, signs, 2.0, 0.30
			);
			deviation += macro_material.deviation * macro_normal_strength;
			base = mix(base, macro_material.albedo * base_color.rgb, 0.24);
			base_orm.r *= macro_material.orm.r;
			base_orm.g = mix(base_orm.g, macro_material.orm.g, 0.48);
		}
		deviation -= up * dot(deviation, up);
		vec3 view_normal = normalize(mat3(VIEW_MATRIX) * normalize(up + deviation));
		base_normal = vec3(
			dot(view_normal, TANGENT), dot(view_normal, BINORMAL), dot(view_normal, NORMAL)
		) * 0.5 + 0.5;
		base_normal_depth = 1.0;
	}
	float upward = smoothstep(0.38, 0.93, up.y);
	vec2 ground = world_position.xz;
	float exposure = surface_weather_exposure(ground, shelter_bounds, shelter_yaw_degrees);
	vec3 color = base;
	float final_ao = base_orm.r;
	float final_roughness = base_orm.g * roughness;
	float final_metallic = base_orm.b;
	float final_normal_strength = base_normal_depth;
	float wet = weather_surface.x * exposure * mix(0.37, 1.0, upward);
	float puddle = 0.0;
	float sparkle = 0.0;

	if (weather_surface.z > 0.0) {
		vec2 coating_uv = (ground + vec2(world_position.y * 0.31, 0.0)) * coating_scale;
		float patch = noise_2d(coating_uv) * 0.7 + noise_2d(coating_uv * 4.0) * 0.3;
		float dust = smoothstep(patch - 0.22, patch + 0.34, weather_surface.z * exposure)
			* mix(0.22, 0.92, upward);
		vec3 dusty_color = dust_color.rgb * mix(0.71, 0.96, patch);
		color = mix(color, dusty_color, dust);
		final_roughness = mix(final_roughness, 0.94, dust);
		final_metallic = mix(final_metallic, 0.0, dust);
	}

	if (weather_surface.y > 0.0) {
		float snow = snow_deposition(ground, up.y, weather_surface.y, exposure, snow_drift_scale);
		float drift = filtered_noise(ground * 0.39 + vec2(1.4, 6.2));
		vec3 snowy_color = snow_color.rgb * mix(0.96, 1.02, drift);
		vec3 snowy_orm = vec3(0.98, 0.82, 0.0);
		vec3 snowy_normal = vec3(0.5, 0.5, 1.0);
		sparkle = snow_crystal_glint(ground) * snow * snow;
		vec3 point = world_position * snow_texture_scale;
		vec3 point_dx = dFdx(point);
		vec3 point_dy = dFdy(point);
		if (use_snow_material && snow > 0.001) {
			vec3 weights = pow(abs(up), vec3(4.0));
			weights /= max(weights.x + weights.y + weights.z, 0.001);
			vec3 signs = step(vec3(0.0), up) * 2.0 - 1.0;
			snowy_color *= triplanar_sample(snow_albedo_texture, point, point_dx, point_dy, signs, weights);
			snowy_orm = triplanar_sample(snow_orm_texture, point, point_dx, point_dy, signs, weights);
			vec3 snow_world_normal = triplanar_snow_normal(point, point_dx, point_dy, signs, weights, up);
			vec3 snow_view_normal = normalize(mat3(VIEW_MATRIX) * snow_world_normal);
			vec3 snow_tangent_normal = vec3(
				dot(snow_view_normal, TANGENT),
				dot(snow_view_normal, BINORMAL),
				dot(snow_view_normal, NORMAL)
			);
			snowy_normal = snow_tangent_normal * 0.5 + 0.5;
		}
		color = mix(color, snowy_color, snow);
		final_ao = mix(final_ao, snowy_orm.r, snow);
		final_roughness = mix(final_roughness, snowy_orm.g * (1.0 - sparkle * 0.28), snow);
		final_metallic = mix(final_metallic, snowy_orm.b, snow);
		base_normal = mix(base_normal, snowy_normal, snow);
		final_normal_strength = mix(base_normal_depth, 1.0, snow);
		wet *= 1.0 - snow * 0.74;
	}

	if (wet > 0.0) {
		float low_spots = noise_2d(ground * puddle_scale) * 0.74
			+ noise_2d(ground * puddle_scale * 3.0) * 0.26;
		if (puddle_cavity_bias > 0.0) {
			float cavities = smoothstep(0.025, 0.16, 1.0 - base_orm.r);
			float edge = filtered_noise(ground * puddle_scale * 7.5 + vec2(2.9, 7.1)) - 0.5;
			low_spots += puddle_cavity_bias * (cavities * 0.33 + edge * 0.39);
		}
		puddle = smoothstep(puddle_threshold, puddle_threshold + 0.23, low_spots)
			* smoothstep(0.42, 0.96, wet) * upward;
		color *= mix(1.0, 0.53, wet) * mix(1.0, 0.68, puddle);
		final_roughness = mix(mix(final_roughness, 0.35, wet), puddle_roughness, puddle);
		final_metallic *= 1.0 - puddle;
		base_normal = mix(base_normal, vec3(0.5, 0.5, 1.0), puddle * 0.94);
	}

	ALBEDO = color;
	ROUGHNESS = final_roughness;
	AO = final_ao;
	METALLIC = final_metallic;
	SPECULAR = max(mix(0.35, 0.58, puddle), 0.35 + sparkle * 0.25);
	NORMAL_MAP = base_normal;
	NORMAL_MAP_DEPTH = final_normal_strength;
	if (puddle > 0.0 && weather_surface.w > 0.0) {
		vec2 ripple_uv = ground * ripple_scale;
		float detail = 1.0 - smoothstep(0.015, 0.10, max(length(dFdx(ripple_uv)), length(dFdy(ripple_uv))));
		vec2 ripple = ripple_gradient(ripple_uv, vec2(0.0), weather_surface.w)
			+ ripple_gradient(ripple_uv, vec2(0.51, 0.37), weather_surface.w);
		vec3 ripple_world = vec3(ripple.x, 0.0, ripple.y);
		vec3 ripple_view = mat3(VIEW_MATRIX) * ripple_world;
		NORMAL_MAP.xy += vec2(dot(ripple_view, TANGENT), dot(ripple_view, BINORMAL))
			* (0.13 * puddle * detail);
	}
}
