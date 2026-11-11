shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 core_color : source_color = vec4(0.88, 0.94, 1.0, 1.0);
uniform vec4 halo_color : source_color = vec4(0.42, 0.52, 1.0, 1.0);
uniform float leader_progress : hint_range(0.0, 1.06) = 0.0;
uniform float brightness : hint_range(0.0, 5.0) = 0.0;
uniform float cloud_base_local = 0.0;
uniform float cloud_veil_depth = 190.0;

varying float height_in_cloud;

void vertex() {
	height_in_cloud = VERTEX.y - cloud_base_local;
}

void fragment() {
	// MSAA can interpolate UV outside the ribbon when only an edge sample is covered.
	float distance_from_core = clamp(abs(UV.x * 2.0 - 1.0), 0.0, 1.0);
	float leader_mask = 1.0 - smoothstep(
		leader_progress - 0.055, leader_progress + 0.015, UV.y
	);
	float pixel_width = min(fwidth(UV.x) * 2.0, 0.38);
	float filament = 1.0 - smoothstep(0.045, 0.13 + 0.45 * pixel_width, distance_from_core);
	float edge_fade = 1.0 - distance_from_core;
	float aureole = exp(-6.5 * distance_from_core) * edge_fade * edge_fade;
	float cloud_transmission = mix(
		1.0,
		0.018,
		smoothstep(-18.0, max(cloud_veil_depth, 25.0) * 0.82, height_in_cloud)
	);
	float haze_transmission = exp(-length(VERTEX) * 0.00014);
	float exposure = leader_mask * clamp(COLOR.r, 0.0, 1.0) * max(brightness, 0.0)
		* cloud_transmission * haze_transmission;

	// The shader owns the small optical halo. Keep the HDR filament below wide bloom levels.
	vec3 radiance = max(core_color.rgb, vec3(0.0)) * filament * 1.64
		+ max(halo_color.rgb, vec3(0.0)) * aureole * 0.27;
	ALBEDO = clamp(radiance, vec3(0.0), vec3(1.75));
	ALPHA = clamp(exposure, 0.0, 1.0);
}
