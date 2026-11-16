shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#define dynamic_sky_weather weather_surface
#include "res://addons/dynamic_sky/surfaces/weather_layer.gdshaderinc"
#include "res://addons/dynamic_sky/surfaces/snow_tracks/snow_track_geometry.gdshaderinc"

#include "res://addons/dynamic_sky/demo/udw_comparison/materials/comparison_rain.gdshaderinc"

#include "res://addons/dynamic_sky/demo/udw_comparison/materials/comparison_wall_rain.gdshaderinc"

const float SNOWPACK_MEAN_LUMINANCE = 0.738;
const float COMPARISON_LANDSCAPE_QUADS = 189.0;
const float COMPARISON_LANDSCAPE_SPACING = 1.28;

group_uniforms Source_Snow;
uniform vec3 comparison_snow_reflectance = vec3(0.9);
uniform float comparison_snow_detail_strength : hint_range(0.0, 1.0) = 0.42;
uniform float comparison_snow_depth_fade = 60.0;
// Scales the close snowpack texture and normal detail on a track-enabled landscape.
uniform float comparison_powder_detail : hint_range(0.0, 2.0, 0.01) = 0.0;
// Half-width of the track trench in meters for local sky occlusion. Zero disables it.
uniform float comparison_track_cavity_half_width : hint_range(0.0, 0.4, 0.005) = 0.0;
group_uniforms;

group_uniforms Source_Dust;
// Use the comparison map's separate landscape and object coating models.
uniform bool comparison_source_dust = false;
group_uniforms;

group_uniforms Dry_Surface;
uniform bool use_surface_uv = false;
uniform float checker_cell_size : hint_range(0.01, 10.0, 0.01) = 1.0;
uniform float checker_cells_per_uv : hint_range(1.0, 64.0, 1.0) = 20.0;
uniform vec2 checker_reflectance = vec2(0.11, 0.09);
uniform vec2 checker_roughness = vec2(0.8, 0.8);
uniform sampler2D substrate_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float substrate_normal_strength : hint_range(0.0, 1.0, 0.01) = 0.24;
group_uniforms;

varying vec3 world_position;
varying vec3 world_normal;
varying vec3 track_world_normal;
varying vec3 track_camera_world;
varying vec3 substrate_world_position;
varying vec2 track_local_ground;
varying float track_snow_depth;


float comparison_value_noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 t = fract(point);
	t = t * t * (3.0 - 2.0 * t);
	float a = mix(snow_deposit_cell(cell), snow_deposit_cell(cell + vec2(1.0, 0.0)), t.x);
	float b = mix(snow_deposit_cell(cell + vec2(0.0, 1.0)), snow_deposit_cell(cell + 1.0), t.x);
	return mix(a, b, t.y);
}


// The source variation tile covers 500 m and contains structure at several scales.
float comparison_ground_variation(vec2 ground) {
	vec2 point = ground / 500.0;
	float broad = comparison_value_noise(point * 12.0 + vec2(4.3, 22.9));
	float banks = comparison_value_noise(point * 57.0 + vec2(2.3, 11.4));
	float mottling = comparison_value_noise(point * 144.0 + vec2(5.7, 18.2));
	return 0.316 + (broad - 0.5) * 0.084 + (banks - 0.5) * 0.057 + (mottling - 0.5) * 0.045;
}


float comparison_base_snow_mask(float coverage, float facing_up, float variation) {
	float slope = clamp((facing_up - 0.66) * (1.5 / (1.0 - 0.66)), 0.0, 1.0);
	return coverage * slope - variation;
}


float comparison_untracked_depth(vec3 substrate, vec3 camera_position, float facing_up) {
	float depth_fade = 1.0 - clamp((distance(substrate, camera_position)
		/ comparison_snow_depth_fade - 0.7) / 0.3, 0.0, 1.0);
	if (depth_fade <= 0.0) {
		return 0.0;
	}
	// The procedural threshold never exceeds .409, so this case saturates the lift.
	if (comparison_base_snow_mask(weather_surface.y, facing_up, 0.409) * 1.85 >= 1.0) {
		return snow_track_depth * depth_fade;
	}
	float base_mask = comparison_base_snow_mask(weather_surface.y, facing_up,
		comparison_ground_variation(substrate.xz));
	return snow_track_depth * depth_fade * clamp(base_mask * 1.85, 0.0, 1.0);
}


float comparison_ground_depth(vec3 substrate, vec3 camera_position, float facing_up,
		vec2 terrain_uv, mat4 world_from_local) {
	vec2 grid = terrain_uv * COMPARISON_LANDSCAPE_QUADS;
	vec2 nearest_line = round(grid);
	vec2 cell_position = fract(mix(nearest_line, grid, step(vec2(0.001), abs(grid - nearest_line))));
	if (max(cell_position.x, cell_position.y) == 0.0) {
		return comparison_untracked_depth(substrate, camera_position, facing_up);
	}
	// Dense orbit vertices and the original landscape must share the same straight coarse edges.
	vec3 step_x = world_from_local[0].xyz * COMPARISON_LANDSCAPE_SPACING;
	vec3 step_z = world_from_local[2].xyz * COMPARISON_LANDSCAPE_SPACING;
	vec3 corner = substrate - step_x * cell_position.x - step_z * cell_position.y;
	float lower = mix(comparison_untracked_depth(corner, camera_position, facing_up),
		comparison_untracked_depth(corner + step_x, camera_position, facing_up), cell_position.x);
	float upper = mix(comparison_untracked_depth(corner + step_z, camera_position, facing_up),
		comparison_untracked_depth(corner + step_x + step_z, camera_position, facing_up), cell_position.x);
	return mix(lower, upper, cell_position.y);
}


// Comparison terrain has a dense inset at the orbit and the same level outside the tracked field.
float comparison_track_delta(vec2 uv, float available_depth) {
	vec2 mark = textureLod(snow_track_field, uv, 0.0).rg;
	vec2 edge = min(uv, 1.0 - uv) * snow_track_rect.zw;
	float feather = smoothstep(0.0, 0.18, min(edge.x, edge.y));
	float depression = available_depth * clamp(mark.r * snow_track_compression, 0.0, 1.0);
	float piled_snow = snow_track_rim * mark.g * (1.0 - mark.r)
		* (available_depth / max(snow_track_depth, 0.001));
	return (piled_snow - depression) * feather;
}


vec3 comparison_track_surface(vec2 local_ground, float available_depth) {
	vec2 uv = (local_ground - snow_track_rect.xy) / snow_track_rect.zw;
	if (!snow_tracks_enabled || available_depth <= 0.0 || min(uv.x, uv.y) < 0.0 || max(uv.x, uv.y) > 1.0) {
		return vec3(0.0);
	}
	vec2 texel = 1.0 / snow_track_resolution;
	vec2 x = vec2(texel.x, 0.0);
	vec2 y = vec2(0.0, texel.y);
	vec2 rises = vec2(
		comparison_track_delta(uv + x, available_depth) - comparison_track_delta(uv - x, available_depth),
		comparison_track_delta(uv + y, available_depth) - comparison_track_delta(uv - y, available_depth)
	);
	return vec3(comparison_track_delta(uv, available_depth), rises / (2.0 * texel * snow_track_rect.zw));
}



void vertex() {
	track_local_ground = VERTEX.xz;
	substrate_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	track_world_normal = world_normal;
	track_camera_world = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;
	track_snow_depth = 0.0;
	if (!use_surface_uv && dynamic_sky_weather_enabled && weather_surface.y > 0.0) {
		float available_depth = comparison_ground_depth(substrate_world_position, MAIN_CAM_INV_VIEW_MATRIX[3].xyz,
			world_normal.y, UV, MODEL_MATRIX);
		track_snow_depth = available_depth;
		vec3 track = comparison_track_surface(VERTEX.xz, available_depth);
		VERTEX.y += max(available_depth + track.x, 0.0);
		NORMAL = normalize(NORMAL + vec3(-track.y, 0.0, -track.z));
		track_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	}
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


// Integral of a unit square wave that reverses sign at each checker edge.
vec2 checker_integral(vec2 position) {
	return 1.0 - abs(2.0 * fract(position * 0.5) - 1.0);
}


float filtered_checker(vec2 position) {
	vec2 width = max(fwidth(position), vec2(0.0001));
	vec2 half_width = width * 0.5;
	vec2 average = (checker_integral(position + half_width) - checker_integral(position - half_width)) / width;
	return clamp(0.5 + 0.5 * average.x * average.y, 0.0, 1.0);
}


// Independent coverage noise with centimetric structure. The original ORM remains a lighting input.
float comparison_snow_scatter(vec2 point) {
	float coarse = snow_deposit_noise(point * 84.0 + vec2(12.3, 31.7));
	float fine = snow_deposit_noise(point * 207.0 + vec2(46.2, 17.4));
	return mix(0.19, 0.71, coarse * 0.73 + fine * 0.27);
}


float comparison_ground_scatter(vec2 point) {
	vec2 drift = vec2(
		snow_deposit_noise(point * 17.0 + vec2(7.3, 19.7)),
		snow_deposit_noise(point * 23.0 + vec2(48.2, 4.7))
	) - 0.5;
	vec2 bank = point + drift * 0.046;
	float clusters = snow_deposit_noise(bank * 13.0 + vec2(37.3, 12.7));
	float grains = snow_deposit_noise(point * 37.0 + vec2(12.3, 31.7));
	float specks = snow_deposit_noise(point * 92.0 + vec2(46.2, 17.4));
	float powder = snow_deposit_noise(point * 180.0 + vec2(53.8, 29.2));
	return 0.06 + 0.78 * (clusters * 0.40 + grains * 0.31 + specks * 0.20 + powder * 0.09);
}


vec2 powder_marks() {
	vec2 uv = (track_local_ground - snow_track_rect.xy) / snow_track_rect.zw;
	vec2 edge = min(uv, 1.0 - uv) * snow_track_rect.zw;
	float coverage = smoothstep(0.0, 0.18, min(edge.x, edge.y));
	return texture(snow_track_field, clamp(uv, vec2(0.0), vec2(1.0))).rg * coverage;
}


void apply_comparison_snow(vec3 up, vec3 base_normal_view, mat3 view_from_world, float cover, inout vec3 color, inout vec3 normal_view,
	inout float roughness, inout float metallic, inout float specular, inout float occlusion) {
	cover = clamp(cover, 0.0, 1.0);
	if (!dynamic_sky_weather_enabled || cover <= 0.0) {
		return;
	}
	vec3 weights = pow(abs(up), vec3(4.0));
	weights /= max(weights.x + weights.y + weights.z, 0.001);
	vec3 signs = step(vec3(0.0), up) * 2.0 - 1.0;
	float scale = use_surface_uv ? 1.0 / 3.5 : 1.0 / 3.0;
	vec3 point = substrate_world_position * scale;
	// Keep the wall's source coverage scale, and sample its original powder detail at a finer scale.
	vec3 detail_point = use_surface_uv ? point * 2.25 : point;
	TerrainPBR detail = terrain_triplanar(dynamic_sky_snow_albedo, dynamic_sky_snow_normal, dynamic_sky_snow_orm,
		detail_point, dFdx(detail_point), dFdy(detail_point), weights, signs, 1.8, 1.0);
	float scatter = use_surface_uv ? dot(weights, vec3(
		comparison_snow_scatter(point.zy), comparison_snow_scatter(point.xz), comparison_snow_scatter(point.xy)
	)) : comparison_ground_scatter(point.xz);
	float coat;
	float snow_roughness;
	float detail_strength = comparison_snow_detail_strength;
	vec3 snow_color = comparison_snow_reflectance;
	if (use_surface_uv) {
		float powder_luminance = dot(detail.albedo, vec3(0.2126, 0.7152, 0.0722));
		float powder_scatter = clamp((powder_luminance - SNOWPACK_MEAN_LUMINANCE) * 2.20, -0.24, 0.26);
		scatter = clamp(0.4 + (scatter - 0.4) * 0.16 + powder_scatter, 0.08, 0.75);
		vec3 base_normal_world = transpose(view_from_world) * base_normal_view;
		float facing = clamp(base_normal_world.y + 0.15, 0.0, 1.0);
		float q = cover * facing;
		coat = clamp((q * (q + 1.5 * (scatter - 0.4)) - 0.2) * 2.5 + 0.2, 0.0, 1.0);
		float feather = smoothstep(0.05, 0.30, coat) * (1.0 - smoothstep(0.73, 0.98, coat));
		detail_strength *= mix(2.15, 2.795, feather);
		float powder_shading = clamp(powder_luminance / SNOWPACK_MEAN_LUMINANCE, 0.68, 1.13);
		snow_color *= mix(1.0, powder_shading, mix(0.27, 0.83, feather));
		snow_roughness = mix(0.8, detail.orm.g, 0.55);
	} else {
		float footprint = max(length(dFdx(substrate_world_position.xz)), length(dFdy(substrate_world_position.xz)));
		float variation = mix(comparison_ground_variation(substrate_world_position.xz), 0.316,
			smoothstep(1.0, 4.0, footprint));
		float base_mask = comparison_base_snow_mask(cover, up.y, variation);
		coat = clamp((base_mask - scatter * 0.2) * 8.0, 0.0, 1.0);
		snow_roughness = 0.7;
	}
	vec3 snow_up = normalize(track_world_normal);
	if (!use_surface_uv && snow_tracks_enabled && snow_track_normal_strength < 1.0) {
		vec3 track_slope = snow_up / max(dot(snow_up, up), 0.10) - up;
		float track_strength = track_normal_strength_for_view(world_position, up, track_camera_world);
		snow_up = normalize(up + track_slope * track_strength);
	}
	if (!use_surface_uv && snow_tracks_enabled && comparison_powder_detail > 0.0) {
		vec2 marks = powder_marks();
		float pressed = smoothstep(0.04, 0.50, marks.r);
		float piled = smoothstep(0.03, 0.36, marks.g) * (1.0 - pressed * 0.58);
		float disturbed = clamp(pressed * 0.51 + piled * 0.88, 0.0, 1.0);
		if (comparison_track_cavity_half_width > 0.0) {
			// Diffuse sky visibility at the bottom of a slot, from the same compression as the geometry.
			float depth = track_snow_depth * clamp(marks.r * snow_track_compression, 0.0, 1.0);
			float aspect = depth / comparison_track_cavity_half_width;
			occlusion *= mix(1.0, inversesqrt(1.0 + aspect * aspect), coat);
		}
		vec3 micro_position = substrate_world_position * 1.45;
		TerrainPBR micro = terrain_triplanar(dynamic_sky_snow_albedo, dynamic_sky_snow_normal, dynamic_sky_snow_orm,
			micro_position, dFdx(micro_position), dFdy(micro_position), weights, signs, 1.8, 1.0);
		float micro_luma = dot(micro.albedo, vec3(0.2126, 0.7152, 0.0722));
		float grain = clamp(micro_luma / 0.741 - 1.0, -0.22, 0.20);
		float micro_contrast = mix(0.12, 0.56, disturbed) * comparison_powder_detail;
		snow_color *= 1.0 + grain * micro_contrast;
		occlusion *= 1.0 - max(-grain, 0.0) * disturbed * comparison_powder_detail * 0.21 * coat;
		vec3 micro_slope = micro.deviation - snow_up * dot(micro.deviation, snow_up);
		snow_up = normalize(snow_up + micro_slope * mix(0.25, 1.05, disturbed) * comparison_powder_detail);
		snow_roughness = mix(snow_roughness - pressed * 0.018, micro.orm.g, piled * 0.56);
	}
	vec3 deviation = detail.deviation - snow_up * dot(detail.deviation, snow_up);
	vec3 snow_normal = view_from_world * normalize(snow_up + deviation * detail_strength);
	color = mix(color, snow_color, coat);
	normal_view = normalize(mix(normal_view, snow_normal, coat));
	roughness = mix(roughness, snow_roughness, coat);
	metallic = mix(metallic, 0.0, coat);
	specular = mix(specular, 0.5, coat);
}


float comparison_dust_cover(vec3 up, vec3 base_normal_view, mat3 view_from_world, float dusty, float choice) {
	if (use_surface_uv) {
		vec3 point = substrate_world_position / 3.5;
		vec3 weights = pow(abs(up), vec3(4.0));
		weights /= max(weights.x + weights.y + weights.z, 0.001);
		float scatter = dot(weights, vec3(comparison_snow_scatter(point.zy),
			comparison_snow_scatter(point.xz), comparison_snow_scatter(point.xy)));
		float facing = clamp((transpose(view_from_world) * base_normal_view).y + 0.15, 0.0, 1.0);
		float q = dusty * facing;
		return clamp((q * (q + 1.5 * (scatter - 0.4)) - 0.2) * mix(2.5, 1.0, choice) + 0.2, 0.0, 1.0);
	}
	vec2 point = substrate_world_position.xz;
	float footprint = max(length(dFdx(point)), length(dFdy(point)));
	float variation = mix(comparison_ground_variation(point), 0.316, smoothstep(1.0, 4.0, footprint));
	float base_mask = comparison_base_snow_mask(dusty, up.y, variation);
	return clamp((base_mask - 0.2 * comparison_ground_scatter(point / 3.0)) * mix(8.0, 3.6, choice), 0.0, 1.0);
}


void fragment() {
	vec4 coated_weather = dynamic_sky_radial_weather_at(substrate_world_position, weather_surface);
	vec2 position = use_surface_uv ? UV * checker_cells_per_uv : world_position.xz / checker_cell_size;
	float checker = filtered_checker(position);
	ALBEDO = vec3(mix(checker_reflectance.x, checker_reflectance.y, checker));
	ROUGHNESS = mix(checker_roughness.x, checker_roughness.y, checker);
	METALLIC = 0.0;
	SPECULAR = 0.5;

	vec2 normal_uv = use_surface_uv ? UV * 2.0 : world_position.xz * 0.2;
	vec2 deviation = (texture(substrate_normal, normal_uv).rg * 2.0 - 1.0) * substrate_normal_strength;
	vec3 geometric_normal = normalize(world_normal);
	if (use_surface_uv) {
		NORMAL = normalize(NORMAL + TANGENT * deviation.x + BINORMAL * deviation.y);
	} else {
		vec3 relief = vec3(deviation.x, 0.0, -deviation.y);
		if (comparison_rain_enabled && dynamic_sky_weather_enabled && coated_weather.x > 0.0) {
			vec2 joints = comparison_wet_tile_relief(substrate_world_position.xz, checker_cell_size);
			vec2 grain_uv = substrate_world_position.xz * 0.82 + vec2(0.31, 0.67);
			vec2 grain = texture(substrate_normal, grain_uv).rg * 2.0 - 1.0;
			vec3 wet_detail = vec3(joints.x + grain.x * 0.42, 0.0, joints.y - grain.y * 0.42);
			relief = relief * mix(1.0, 3.90, coated_weather.x) + wet_detail * coated_weather.x;
		}
		vec3 surface_normal = normalize(geometric_normal + relief);
		NORMAL = normalize(mat3(VIEW_MATRIX) * surface_normal);
	}
	vec3 base_normal_view = NORMAL;
	float generic_dust = comparison_source_dust ? 0.0 : coated_weather.z;
	if (!use_surface_uv && comparison_rain_enabled && dynamic_sky_weather_enabled) {
		vec4 dry_substrate_weather = vec4(0.0, 0.0, generic_dust, 0.0);
		APPLY_DYNAMIC_SKY_WEATHER_STATE(world_position, geometric_normal, dry_substrate_weather);
		apply_comparison_rain(substrate_world_position.xz, geometric_normal, mat3(VIEW_MATRIX), coated_weather,
			ALBEDO, NORMAL, ROUGHNESS, SPECULAR);
	} else if (use_surface_uv && comparison_wall_wet_enabled && dynamic_sky_weather_enabled) {
		vec4 dry_substrate_weather = vec4(0.0, 0.0, generic_dust, 0.0);
		APPLY_DYNAMIC_SKY_WEATHER_STATE(world_position, geometric_normal, dry_substrate_weather);
		if (coated_weather.x > 0.0) {
			vec2 joints = comparison_wall_tile_relief(UV * checker_cells_per_uv);
			vec2 micro = texture(substrate_normal, UV * 8.4 + vec2(0.24, 0.67)).rg * 2.0 - 1.0;
			vec2 tile_detail = joints + deviation * 2.40 + micro * 0.42;
			NORMAL = normalize(NORMAL + (TANGENT * tile_detail.x + BINORMAL * tile_detail.y) * coated_weather.x);
		}
		apply_comparison_wall_rain(substrate_world_position, geometric_normal, mat3(VIEW_MATRIX), coated_weather,
			ALBEDO, NORMAL, ROUGHNESS, SPECULAR);
	} else {
		vec4 substrate_weather = vec4(coated_weather.x, 0.0, generic_dust, coated_weather.w);
		APPLY_DYNAMIC_SKY_WEATHER_STATE(world_position, geometric_normal, substrate_weather);
	}
	if (comparison_source_dust && dynamic_sky_weather_enabled && coated_weather.z > 0.0) {
		// UDW applies Max Dust Coverage separately from the Dust or Snow selector.
		float dusty = clamp(coated_weather.z, 0.0, 1.0) * 0.5;
		float dust_choice = clamp(coated_weather.z * 6.0, 0.0, 1.0);
		float coat = comparison_dust_cover(geometric_normal, base_normal_view, mat3(VIEW_MATRIX), dusty, dust_choice);
		vec3 coat_color = mix(comparison_snow_reflectance, dynamic_sky_dust_color.rgb, dust_choice);
		ALBEDO = mix(ALBEDO, coat_color, coat);
		float coat_roughness = use_surface_uv ? mix(0.8, 0.4, coated_weather.x) : 0.7;
		ROUGHNESS = mix(ROUGHNESS, coat_roughness, coat);
	}
	apply_comparison_snow(geometric_normal, base_normal_view, mat3(VIEW_MATRIX), coated_weather.y, ALBEDO, NORMAL, ROUGHNESS, METALLIC, SPECULAR, AO);
}

