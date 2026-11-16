group_uniforms Cloud_Field;
// Original repeating formation field. Red provides support and blue shifts condensation height.
uniform sampler3D cloud_formation : filter_linear, repeat_enable;
// Fine numerical detail for the moon and optional celestial layers.
uniform sampler3D cloud_noise : filter_linear_mipmap, repeat_enable;
// Independent linear erosion channels used by the volumetric field.
uniform sampler3D cloud_erosion_volume : filter_linear, repeat_enable;
// Repeatable map of cloud coverage, type, and high-layer wisps.
uniform sampler2D cloud_weather : filter_linear_mipmap, repeat_enable;
// Combined coverage of the lower cloud volume and upper wisps.
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.45;
// Horizontal wind displacement in kilometers. The field repeats every 128 units.
uniform vec2 cloud_offset = vec2(0.0);
// Lower cloud base and thickness in kilometers above the rig's sea-level origin.
uniform float cloud_base_km : hint_range(0.3, 5.0, 0.05) = 0.60;
uniform float cloud_thickness_km : hint_range(0.3, 6.0, 0.05) = 0.70;
// Scale for the cloud profile extinction. Larger values make the same field more opaque.
uniform float cloud_extinction : hint_range(0.3, 12.0, 0.05) = 10.0;
// Spatial frequency of the lower cloud volume.
uniform float low_cloud_scale : hint_range(0.5, 12.0, 0.1) = 2.4;
group_uniforms;

const float PLANET_RADIUS = 6371.0;
const float CLOUD_MAX_TRACE_DISTANCE_KM = 50.0;
const int MAX_RADIAL_CLOUD_CELLS = 8;

// Cells are in rig-relative world kilometers and sorted from low to high priority.
uniform int radial_cloud_cell_count = 0;
uniform vec4 radial_cloud_cells[8]; // Center XZ, outer radius, full-weight radius.
uniform vec4 radial_cloud_cell_values[8]; // Target coverage and physical storm alpha.

bool cloud_volume_may_exist() {
	if (cloud_coverage > 0.0) {
		return true;
	}
	int count = min(radial_cloud_cell_count, MAX_RADIAL_CLOUD_CELLS);
	for (int index = 0; index < count; index++) {
		if (radial_cloud_cells[index].z > 0.0 && all(greaterThan(radial_cloud_cell_values[index].xy, vec2(0.0)))) {
			return true;
		}
	}
	return false;
}

float cloud_coverage_for_position(vec2 position_km) {
	float coverage = cloud_coverage;
	int count = min(radial_cloud_cell_count, MAX_RADIAL_CLOUD_CELLS);
	for (int index = 0; index < count; index++) {
		vec4 cell = radial_cloud_cells[index];
		vec2 delta = position_km - cell.xy;
		float distance_squared = dot(delta, delta);
		if (cell.z <= 0.0 || distance_squared >= cell.z * cell.z) {
			continue;
		}
		float weight = 1.0;
		float core_radius = clamp(cell.w, 0.0, cell.z);
		if (distance_squared > core_radius * core_radius) {
			float edge = (cell.z - sqrt(distance_squared)) / max(cell.z - core_radius, 0.000001);
			weight = pow(clamp(edge, 0.0, 1.0), 1.4);
		}
		vec2 values = clamp(radial_cloud_cell_values[index].xy, vec2(0.0), vec2(1.0));
		coverage = mix(coverage, values.x, weight * values.y);
	}
	return coverage;
}

float altitude_at(vec3 point) {
	// Tangent-plane expansion in kilometers around the rig's sea-level origin.
	return point.y + dot(point.xz, point.xz) / (2.0 * PLANET_RADIUS);
}

vec2 cloud_shell_hits(vec3 origin, vec3 direction, float height) {
	float b = dot(origin, direction) + PLANET_RADIUS * direction.y;
	float c = dot(origin.xz, origin.xz) + (origin.y - height) * (2.0 * PLANET_RADIUS + origin.y + height);
	float discriminant = b * b - c;
	if (discriminant < 0.0) {
		return vec2(-1.0);
	}
	float root = sqrt(discriminant);
	// Solve the larger-magnitude root directly to preserve short, nearly vertical hits.
	float distant = -b - (b >= 0.0 ? root : -root);
	float close = abs(distant) > 0.000001 ? c / distant : -b;
	return vec2(min(distant, close), max(distant, close));
}

vec2 cloud_shell_interval(vec3 origin, vec3 direction, float max_distance) {
	vec2 outer = cloud_shell_hits(origin, direction, cloud_base_km + cloud_thickness_km);
	vec2 inner = cloud_shell_hits(origin, direction, cloud_base_km);
	float start = max(outer.x, 0.0);
	float end = min(outer.y, max_distance);
	if (inner.y > start && inner.x < end) {
		if (inner.x > start) {
			end = inner.x;
		} else {
			start = inner.y;
		}
	}
	vec2 ground = cloud_shell_hits(origin, direction, 0.0);
	if (ground.x >= 0.0 && ground.x < ground.y) {
		end = min(end, ground.x);
	}
	return vec2(start, end);
}

vec3 cloud_coordinates(vec3 point) {
	vec3 coordinates = point * vec3(0.102, 0.132, 0.102) * low_cloud_scale;
	coordinates.xz += cloud_offset / 8.0;
	return coordinates + vec3(0.11, 0.41, 0.57);
}

vec2 cloud_coverage_at(vec3 point) {
	vec2 weather_uv = point.xz / 51.0 + cloud_offset / 128.0 + vec2(0.38, 0.72);
	vec2 warp = textureLod(cloud_weather, weather_uv * 2.0 + vec2(0.47, 0.23), 0.0).gb - 0.5;
	return textureLod(cloud_weather, weather_uv + warp * 0.054, 0.0).rg;
}

// Original numeric altitude profile: R=taper, G=extinction, B=erosion amplitude.
group_uniforms Cloud_Profile;
uniform sampler2D cloud_profile : filter_linear, repeat_disable;
uniform float cloud_formation_texture_scale : hint_range(0.2, 4.0, 0.05) = 1.0;
uniform float cloud_formation_phase = 0.37;
uniform float cloud_formation_z_shift = 0.0;
uniform float cloud_erosion_scale : hint_range(0.1, 3.0, 0.05) = 0.9;
uniform float cloud_erosion_intensity : hint_range(0.0, 3.0, 0.05) = 1.2;
uniform float cloud_high_frequency_amount : hint_range(0.0, 1.0, 0.01) = 0.24;
uniform float cloud_macro_variation : hint_range(0.0, 0.5, 0.01) = 0.16;
uniform float cloud_macro_scale : hint_range(0.2, 4.0, 0.05) = 1.3;
group_uniforms;

vec4 cloud_source_field_at_coverage(vec3 point, float height, bool detail, float hf_octaves, float local_coverage) {
	float h = (height-cloud_base_km)/cloud_thickness_km;
	if(h <= 0.0 || h >= 1.0 || local_coverage <= 0.0) {
		return vec4(0.0);
	}
	float world_scale = 2.4 / max(low_cloud_scale,0.01);
	float d = local_coverage*3.0;
	float simplified = clamp((d-2.1)/0.2,0.0,1.0);
	float base_coverage = clamp((d-max(0.2-d,0.0))*1.15,-0.2,3.0);
	// Integer wind cycles keep all volume coordinates continuous across the 128 km wrap.
	vec2 formation_uv = point.xz/(12.0*cloud_formation_texture_scale*world_scale)+cloud_offset*(10.0/128.0)+vec2(0.48,0.62);
	vec3 formation = textureLod(cloud_formation,vec3(formation_uv,cloud_formation_phase-h*cloud_formation_z_shift),0.0).rgb;
	float macro_scale = cloud_macro_scale*1.35;
	float macro_amount = cloud_macro_variation*clamp(d/0.3,0.0,1.0)*(1.0-clamp((d-1.75)/0.2,0.0,1.0));
	vec2 macro_uv = point.xz/(12.0*cloud_formation_texture_scale*world_scale*macro_scale)+cloud_offset*(6.0/128.0)+vec2(0.48,0.62)/macro_scale;
	float f = base_coverage + sin(TAU*macro_uv.x)*sin(TAU*macro_uv.y)*macro_amount*(1.0-simplified);
	float altitude_variation_scale = mix(0.15,1.0,clamp((abs(sun_direction.y)-0.07)/0.13,0.0,1.0))*0.8;
	float floor_variation = mix(0.1,0.8,clamp(f-1.5,0.0,1.0))*altitude_variation_scale;
	float split_height = clamp(h-formation.b*formation.b*floor_variation*(1.0-h),0.0,1.0);
	vec2 profile_size = vec2(textureSize(cloud_profile,0));
	vec2 profile_uv = (clamp(vec2(f/3.0,1.0-split_height),vec2(0.0),vec2(1.0))*(profile_size-1.0)+0.5)/profile_size;
	vec3 profile = textureLod(cloud_profile,profile_uv,0.0).rgb;
	float threshold = pow(1.0-f/6.5,3.0)-0.25;
	float support = clamp(clamp(formation.r-threshold,0.0,1.0)/max(1.0-threshold,0.001)-(1.0-profile.r),0.0,1.0);
	if(support <= 0.0){return vec4(0.0,split_height,0.0,0.0);}
	vec3 noise_uvw = vec3(point.x,point.z,point.y)/vec3(1.3333333,1.3333333,0.7733333)/(cloud_erosion_scale*world_scale)+vec3(cloud_offset*(100.0/128.0),0.0);
	vec3 noise = textureLod(cloud_erosion_volume,noise_uvw,0.0).rgb;
	float shape = support-pow(mix(noise.r,0.5,simplified),3.0)*cloud_erosion_intensity*profile.b;
	if(detail && simplified < 1.0){
		vec3 hf_uvw = noise_uvw*3.5+noise*0.21;
		float octaves = min(hf_octaves,2.0);
		float hf = 0.5;
		float strength = 1.0;
		for(int octave=0;octave<2;octave++){
			if(octaves <= 0.3){break;}
			hf += (textureLod(cloud_erosion_volume,hf_uvw,0.0).r-0.55)*strength*clamp(octaves*4.0,0.0,1.0);
			strength *= 0.6;
			hf_uvw *= 2.0;
			octaves -= 1.0;
		}
		shape += (hf-0.55)*cloud_high_frequency_amount*noise.b*(1.0-simplified);
	}
#ifdef CLOUD_WORLD_SHADOW
	// Ground transmission does not change when the observer moves.
	float close_fade = 1.0;
#else
	float distance_to_camera = length(point-cloud_observer_position_km);
	float close_fade = clamp((distance_to_camera-0.05*world_scale)/world_scale,0.0,1.0);
#endif
	// The field returns extinction per meter; ray lengths in the sky are kilometers.
	float sigma_m = clamp(shape*cloud_extinction/world_scale*profile.g*profile.g*profile.g*close_fade,0.0,65000.0);
	return vec4(sigma_m,split_height,max(shape,0.0),f);
}

vec4 cloud_source_field(vec3 point, float height, bool detail, float hf_octaves) {
	return cloud_source_field_at_coverage(point, height, detail, hf_octaves, cloud_coverage_for_position(point.xz));
}

float cloud_density_with_detail(vec3 point,float height,vec2 weather,bool detail,float detail_weight){
	return cloud_source_field(point,height,detail,detail_weight*2.0).r*1000.0/max(cloud_extinction,0.0001);
}

float cloud_density_at(vec3 point,float height,vec2 weather,bool detail){
	return cloud_density_with_detail(point,height,weather,detail,1.0);
}
