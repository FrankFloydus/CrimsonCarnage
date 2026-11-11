shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled, skip_vertex_transform, vertex_lighting;

// Linear packed G = sharp snow, B = defocused snow. Each cell is selected independently.
uniform sampler2D snow_sheet : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D scene_color : hint_screen_texture, repeat_disable, filter_linear;
uniform vec3 snow_color = vec3(1.0);
uniform float snow_sprite_alpha = 1.0;
uniform vec3 ambient_fog_color = vec3(0.0);
uniform float snow_ambient_intensity = 0.0;

// Source circle-DOF parameters. Defaults represent the reference editor's disabled camera DOF.
uniform vec3 circle_dof_parameters = vec3(0.0);
uniform float focus_distance_meters = 10.0;
uniform float weather_dof_scale = 1.0;
uniform float scale_blur_size = 1.0;

varying vec2 atlas_uv;
varying float sprite_alpha;
varying float particle_radius;

float opaque_view_depth(vec2 screen_uv, mat4 inverse_projection) {
	float depth = textureLod(scene_depth, screen_uv, 0.0).r;
	vec4 view = inverse_projection * vec4(screen_uv * 2.0 - 1.0, depth, 1.0);
	return -view.z / max(view.w, 0.000001);
}

float circle_of_confusion(float view_depth) {
	float z = max(view_depth, 0.000001);
	float lens_coc = ((z - focus_distance_meters) / z) * circle_dof_parameters.x;
	float depth_blur = (1.0 - exp2(-z * circle_dof_parameters.y)) * circle_dof_parameters.z;
	return 2.0 * max(abs(lens_coc), depth_blur) * weather_dof_scale;
}

vec2 dof_mask_and_opacity(float view_depth, float radius, float focal_pixels) {
	float radius_pixels = max(radius * focal_pixels / max(view_depth, 0.000001), 0.000001);
	float blur = circle_of_confusion(view_depth);
	float mask_blend = clamp(blur / (4.0 * radius_pixels), 0.0, 1.0);
	float opacity_scale = pow(1.0 / (1.0 + blur / radius_pixels), 1.5);
	return vec2(mask_blend, opacity_scale);
}

void vertex() {
	vec2 sprite_size = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	particle_radius = 0.5 * min(sprite_size.x, sprite_size.y);
	sprite_alpha = INSTANCE_CUSTOM.w;
	atlas_uv = UV * 0.5 + COLOR.ba;

	if (particle_radius <= 0.0) {
		// Inactive GPU slots have a zero transform and a non-finite world translation.
		VERTEX = vec3(0.0, 0.0, 1.0);
		NORMAL = vec3(0.0, 0.0, 1.0);
		sprite_alpha = 0.0;
	} else {
		vec3 main_position = MODEL_MATRIX[3].xyz;
		vec3 camera_vector = INV_VIEW_MATRIX[3].xyz - main_position;
		vec3 facing = camera_vector / max(length(camera_vector), 0.000001);
		vec3 sprite_velocity = INSTANCE_CUSTOM.xyz;
		float speed = length(sprite_velocity);
		vec3 direction = speed > 0.000001 ? sprite_velocity / speed : vec3(0.0, 1.0, 0.0);
		// UE-to-Godot changes handedness. This is the converted velocity-aligned sprite basis.
		vec3 side = cross(direction, facing);
		vec3 right = side / max(length(side), 0.000001);
		vec3 up = -direction;
		vec2 pivot = vec2(0.5, -0.5);
		vec2 corner = sprite_size * (UV - pivot);
		vec3 world_vertex = main_position + right * corner.x + up * corner.y;
		vec2 center_offset = sprite_size * (vec2(0.5) - pivot);
		vec3 material_center = main_position + right * center_offset.x + up * center_offset.y;
		vec3 view_vertex = (VIEW_MATRIX * vec4(world_vertex, 1.0)).xyz;
		float view_depth = -view_vertex.z;
		float focal_pixels = 0.5 * VIEWPORT_SIZE.x * abs(PROJECTION_MATRIX[0][0]);
		float blur = circle_of_confusion(view_depth);
		vec2 blur_pixels = blur * (UV - vec2(0.5)) * vec2(-2.0, 2.0);
		vec3 view_blur = vec3(blur_pixels * view_depth / max(focal_pixels, 0.000001), 0.0);
		vec3 desired_offset = mat3(INV_VIEW_MATRIX) * view_blur * scale_blur_size;
		desired_offset = min(desired_offset, vec3(0.2));
		float mask_blend = dof_mask_and_opacity(view_depth, particle_radius, focal_pixels).x;
		vec3 world_offset = mix(vec3(0.0), desired_offset - (world_vertex - material_center), mask_blend);

		vec4 clip = PROJECTION_MATRIX * vec4(view_vertex, 1.0);
		vec2 screen_uv = clip.xy / max(clip.w, 0.000001) * 0.5 + 0.5;
		float opaque_depth = opaque_view_depth(clamp(screen_uv, vec2(0.0), vec2(1.0)), inverse(PROJECTION_MATRIX));
		if (view_depth - opaque_depth > 0.02) {
			world_offset = material_center - world_vertex;
		}

		VERTEX = (VIEW_MATRIX * vec4(world_vertex + world_offset, 1.0)).xyz;
		vec2 normal_tilt = COLOR.rg * 2.0 - 1.0;
		vec3 world_normal = normalize(vec3(normal_tilt.y, 1.0, -normal_tilt.x));
		NORMAL = normalize(mat3(VIEW_MATRIX) * world_normal);
	}
}

void fragment() {
	vec4 sheet = texture(snow_sheet, atlas_uv);
	float focal_pixels = 0.5 * VIEWPORT_SIZE.x * abs(PROJECTION_MATRIX[0][0]);
	vec2 dof = dof_mask_and_opacity(-VERTEX.z, particle_radius, focal_pixels);
	float mask = mix(sheet.g, sheet.b, dof.x);
	float depth_fade = clamp((opaque_view_depth(SCREEN_UV, INV_PROJECTION_MATRIX) + VERTEX.z) / 0.001, 0.0, 1.0);
	vec3 background = textureLod(scene_color, SCREEN_UV, 0.0).rgb;
	ALBEDO = snow_color;
	METALLIC = 0.0;
	ROUGHNESS = 0.5;
	SPECULAR = 0.5;
	EMISSION = (ambient_fog_color * snow_ambient_intensity + background * 0.55) * snow_color;
	ALPHA = depth_fade * mask * sprite_alpha * snow_sprite_alpha * dof.y;
}
