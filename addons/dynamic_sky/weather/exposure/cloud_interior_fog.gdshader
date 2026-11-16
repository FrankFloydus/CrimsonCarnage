shader_type fog;

uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 cloud_rig_origin_m = vec3(0.0);
uniform float cloud_interior_strength = 0.06;

#define CLOUD_WORLD_SHADOW
#include "res://addons/dynamic_sky/rendering/cloud_density.gdshaderinc"

void fog() {
	vec3 position_km = (WORLD_POSITION - cloud_rig_origin_m) * 0.001;
	float height = altitude_at(position_km);
	float extinction_per_meter = cloud_source_field(position_km, height, false, 0.0).r;
	DENSITY = min(extinction_per_meter * cloud_interior_strength, 0.08);
	float daylight = smoothstep(-0.075, 0.15, sun_direction.y);
	ALBEDO = vec3(0.38, 0.41, 0.45);
	EMISSION = mix(vec3(0.0014, 0.0021, 0.0032), vec3(0.023, 0.031, 0.047), daylight);
}
