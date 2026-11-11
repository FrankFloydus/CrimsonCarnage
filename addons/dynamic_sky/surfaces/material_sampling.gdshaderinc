struct TerrainPBR {
	vec3 albedo;
	vec3 deviation;
	vec3 orm;
};

struct TerrainPlane {
	vec3 albedo;
	vec2 gradient;
	vec3 orm;
};

vec3 terrain_hash(vec2 cell) {
	vec3 point = fract(vec3(cell.xyx) * vec3(0.1031, 0.1030, 0.0973));
	point += dot(point, point.yxz + 33.33);
	return fract((point.xxy + point.yzz) * point.zyx);
}

void terrain_triangle(vec2 uv, out vec2 a, out vec2 b, out vec2 c, out vec3 weights) {
	vec2 grid = vec2(uv.x - uv.y * 0.577350269, uv.y * 1.154700538);
	vec2 cell = floor(grid);
	vec2 fraction = fract(grid);
	if (fraction.x + fraction.y <= 1.0) {
		a = cell;
		b = cell + vec2(1.0, 0.0);
		c = cell + vec2(0.0, 1.0);
		weights = vec3(1.0 - fraction.x - fraction.y, fraction.x, fraction.y);
	} else {
		a = cell + vec2(1.0);
		b = cell + vec2(0.0, 1.0);
		c = cell + vec2(1.0, 0.0);
		weights = vec3(fraction.x + fraction.y - 1.0, 1.0 - fraction.x, 1.0 - fraction.y);
	}
	weights = pow(max(weights, vec3(0.0)), vec3(3.2));
	weights /= max(dot(weights, vec3(1.0)), 0.00001);
}

TerrainPlane terrain_cell(
	sampler2D albedo_map, sampler2D normal_map, sampler2D orm_map,
	vec2 uv, vec2 uv_dx, vec2 uv_dy, vec2 cell, float rotation_range
) {
	vec3 random = terrain_hash(cell);
	float angle = (random.z - 0.5) * rotation_range + step(0.5, random.x) * PI;
	float cosine = cos(angle);
	float sine = sin(angle);
	mat2 rotation = mat2(vec2(cosine, sine), vec2(-sine, cosine));
	vec2 point = rotation * uv + random.xy * 37.0;
	vec2 point_dx = rotation * uv_dx;
	vec2 point_dy = rotation * uv_dy;
	TerrainPlane result;
	result.albedo = textureGrad(albedo_map, point, point_dx, point_dy).rgb;
	result.orm = textureGrad(orm_map, point, point_dx, point_dy).rgb;
	vec2 tangent_xy = textureGrad(normal_map, point, point_dx, point_dy).rg * 2.0 - 1.0;
	float tangent_z = sqrt(max(1.0 - dot(tangent_xy, tangent_xy), 0.001));
	// Inverse-rotate the normal slope into the continuous projection's tangent basis.
	vec2 gradient = tangent_xy / max(tangent_z, 0.35);
	result.gradient = vec2(dot(rotation[0], gradient), dot(rotation[1], gradient));
	return result;
}

TerrainPlane terrain_plane(
	sampler2D albedo_map, sampler2D normal_map, sampler2D orm_map,
	vec2 uv, vec2 uv_dx, vec2 uv_dy, float patch_repeats, float rotation_range
) {
	vec2 a;
	vec2 b;
	vec2 c;
	vec3 weights;
	terrain_triangle(uv / patch_repeats, a, b, c, weights);
	TerrainPlane first = terrain_cell(albedo_map, normal_map, orm_map, uv, uv_dx, uv_dy, a, rotation_range);
	TerrainPlane second = terrain_cell(albedo_map, normal_map, orm_map, uv, uv_dx, uv_dy, b, rotation_range);
	TerrainPlane third = terrain_cell(albedo_map, normal_map, orm_map, uv, uv_dx, uv_dy, c, rotation_range);
	TerrainPlane result;
	result.albedo = first.albedo * weights.x + second.albedo * weights.y + third.albedo * weights.z;
	result.orm = first.orm * weights.x + second.orm * weights.y + third.orm * weights.z;
	result.gradient = first.gradient * weights.x + second.gradient * weights.y + third.gradient * weights.z;
	return result;
}

TerrainPBR terrain_triplanar(
	sampler2D albedo_map, sampler2D normal_map, sampler2D orm_map,
	vec3 point, vec3 point_dx, vec3 point_dy, vec3 blend, vec3 signs,
	float patch_repeats, float rotation_range
) {
	TerrainPBR result;
	result.albedo = vec3(0.0);
	result.orm = vec3(0.0);
	result.deviation = vec3(0.0);
	if (blend.x > 0.001) {
		vec2 orientation = vec2(-signs.x, 1.0);
		TerrainPlane sample_x = terrain_plane(albedo_map, normal_map, orm_map,
			point.zy * orientation, point_dx.zy * orientation, point_dy.zy * orientation,
			patch_repeats, rotation_range);
		result.albedo += sample_x.albedo * blend.x;
		result.orm += sample_x.orm * blend.x;
		result.deviation += vec3(0.0, sample_x.gradient.y, -sample_x.gradient.x * signs.x) * blend.x;
	}
	if (blend.y > 0.001) {
		vec2 orientation = vec2(1.0, -signs.y);
		TerrainPlane sample_y = terrain_plane(albedo_map, normal_map, orm_map,
			point.xz * orientation, point_dx.xz * orientation, point_dy.xz * orientation,
			patch_repeats, rotation_range);
		result.albedo += sample_y.albedo * blend.y;
		result.orm += sample_y.orm * blend.y;
		result.deviation += vec3(sample_y.gradient.x, 0.0, -sample_y.gradient.y * signs.y) * blend.y;
	}
	if (blend.z > 0.001) {
		vec2 orientation = vec2(signs.z, 1.0);
		TerrainPlane sample_z = terrain_plane(albedo_map, normal_map, orm_map,
			point.xy * orientation, point_dx.xy * orientation, point_dy.xy * orientation,
			patch_repeats, rotation_range);
		result.albedo += sample_z.albedo * blend.z;
		result.orm += sample_z.orm * blend.z;
		result.deviation += vec3(sample_z.gradient.x * signs.z, sample_z.gradient.y, 0.0) * blend.z;
	}
	return result;
}

TerrainPBR terrain_blend(TerrainPBR first, TerrainPBR second, float amount) {
	TerrainPBR result;
	result.albedo = mix(first.albedo, second.albedo, amount);
	result.orm = mix(first.orm, second.orm, amount);
	result.deviation = mix(first.deviation, second.deviation, amount);
	return result;
}
