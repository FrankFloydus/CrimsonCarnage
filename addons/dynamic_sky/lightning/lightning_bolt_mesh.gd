extends RefCounted
## Builds a short-lived ribbon mesh with irregular leaders and tapered forks.


static func build(
	cloud_origin: Vector3,
	radius: float,
	fork_count: int,
	view_position: Vector3,
	random: RandomNumberGenerator,
	cloud_arc: float,
) -> ArrayMesh:
	var span := cloud_origin.length()
	var in_clouds := cloud_arc > 0.0
	var channel := PackedVector3Array([cloud_origin])
	if in_clouds:
		# Separate leader segments dip in and out of the storm deck at irregular depths.
		var progress_steps := Vector4(0.22, 0.42, 0.56, 0.73)
		var dip_weights := Vector4(0.46, 1.02, 0.57, 0.83)
		for index in 4:
			var progress := progress_steps[index] + random.randf_range(-0.045, 0.045)
			var point := cloud_origin.lerp(Vector3.ZERO, progress)
			point.y -= cloud_arc * dip_weights[index] * random.randf_range(0.88, 1.12)
			channel.append(point + _horizontal(random) * span * random.randf_range(0.02, 0.07))
	channel.append(Vector3.ZERO)
	var leader := _refine_path(channel, 5 if in_clouds else 7, span * 0.074, random, in_clouds)

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var next_vertex := _append_ribbon(
		surface, 0, leader, view_position, radius, 1.0, 0.0, 1.0, false
	)
	for fork in fork_count:
		var slot := (float(fork) + random.randf_range(0.15, 0.85)) / float(fork_count)
		var fork_index := roundi(lerpf(0.12, 0.76, slot) * float(leader.size() - 1))
		var fork_origin := leader[fork_index]
		var drop := span * random.randf_range(0.12, 0.24)
		if not in_clouds:
			drop = minf(drop, fork_origin.y * 0.68)
		var fork_direction := _horizontal(random)
		var fork_tip := (
			fork_origin + fork_direction * drop * random.randf_range(0.44, 0.91)
			+ Vector3.DOWN * drop
		)
		var fork_path := _refine_path(
			PackedVector3Array([fork_origin, fork_tip]), 4, drop * 0.11, random, in_clouds
		)
		var from_progress := float(fork_index) / float(leader.size() - 1)
		var to_progress := minf(from_progress + drop / span, 0.98)
		next_vertex = _append_ribbon(
			surface, next_vertex, fork_path, view_position, radius * 0.52,
			random.randf_range(0.39, 0.56), from_progress, to_progress, true
		)
		if fork == 0:
			var spur_index := random.randi_range(3, 7)
			var spur_origin := fork_path[spur_index]
			var spur_drop := drop * random.randf_range(0.22, 0.47)
			if not in_clouds:
				spur_drop = minf(spur_drop, spur_origin.y * 0.66)
			var spur_direction := fork_direction.rotated(Vector3.UP, random.randf_range(0.65, 1.4))
			var spur_tip := spur_origin + (spur_direction + Vector3.DOWN) * spur_drop
			var spur := _refine_path(
				PackedVector3Array([spur_origin, spur_tip]), 3, spur_drop * 0.13, random, in_clouds
			)
			var spur_start := lerpf(
				from_progress, to_progress, float(spur_index) / float(fork_path.size() - 1)
			)
			next_vertex = _append_ribbon(
				surface, next_vertex, spur, view_position, radius * 0.30,
				0.24, spur_start, minf(spur_start + spur_drop / span, 0.99), true
			)
	return surface.commit()


static func _refine_path(
	path: PackedVector3Array,
	depth: int,
	displacement: float,
	random: RandomNumberGenerator,
	vertical_roughness: bool,
) -> PackedVector3Array:
	var end := path[-1]
	for _level in depth:
		var refined := PackedVector3Array()
		for index in range(path.size() - 1):
			var midpoint := path[index].lerp(path[index + 1], 0.5)
			var direction := _horizontal(random)
			if vertical_roughness:
				direction.y = random.randf_range(-0.65, 0.65)
			midpoint += direction * random.randf_range(0.28, 1.0) * displacement
			refined.append(path[index])
			refined.append(midpoint)
		refined.append(end)
		path = refined
		displacement *= 0.52
	return path


static func _append_ribbon(
	surface: SurfaceTool,
	first_vertex: int,
	path: PackedVector3Array,
	view_position: Vector3,
	radius: float,
	strength: float,
	start_progress: float,
	end_progress: float,
	is_fork: bool,
) -> int:
	var last_point := path.size() - 1
	var previous_side := Vector3.ZERO
	for index in path.size():
		var point := path[index]
		var tangent := path[mini(index + 1, last_point)] - path[maxi(index - 1, 0)]
		var side := tangent.cross(view_position - point).normalized()
		if side.is_zero_approx():
			side = tangent.cross(Vector3.RIGHT).normalized()
		if side.is_zero_approx():
			side = Vector3.BACK
		if side.dot(previous_side) < 0.0:
			side = -side
		previous_side = side
		var progress := float(index) / float(last_point)
		var taper := lerpf(1.0, 0.08, progress) if is_fork else lerpf(0.68, 1.0, progress)
		var opacity := strength * taper if is_fork else strength
		var reveal := lerpf(start_progress, end_progress, progress)
		var offset := side * radius * taper
		surface.set_color(Color(opacity, 0.0, 0.0))
		surface.set_uv(Vector2(0.0, reveal))
		surface.add_vertex(point - offset)
		surface.set_uv(Vector2(1.0, reveal))
		surface.add_vertex(point + offset)
		if index > 0:
			var vertex := first_vertex + index * 2
			surface.add_index(vertex - 2)
			surface.add_index(vertex)
			surface.add_index(vertex - 1)
			surface.add_index(vertex - 1)
			surface.add_index(vertex)
			surface.add_index(vertex + 1)
	return first_vertex + path.size() * 2


static func _horizontal(random: RandomNumberGenerator) -> Vector3:
	var yaw := random.randf_range(0.0, TAU)
	return Vector3(cos(yaw), 0.0, sin(yaw))
