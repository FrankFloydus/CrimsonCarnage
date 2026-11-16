@tool
extends RefCounted
## Copies an animation and adjusts the position paths and time scale for preview or export.

const MIN_DURATION := 0.001  # Godot's minimum Animation length in seconds.
const SOCKET_TIME_METADATA: Array[StringName] = [&"right_socket_key_times", &"left_socket_key_times"]


## Scale each targeted path about its position keys' bounds center, then offset it in Y and Z.
## The duration is in seconds. Returns null when the tweak cannot preserve every key.
static func apply(source: Animation, targets: Array[NodePath], vertical_offset: float,
		width: float, height: float, depth: float, camera_offset: float, duration: float) -> Animation:
	var scale := Vector3(width, height, depth)
	var offset := Vector3(0.0, vertical_offset, camera_offset)
	if source == null or not is_finite(source.length) or source.length < MIN_DURATION \
			or not is_finite(duration) or duration < MIN_DURATION \
			or not scale.is_finite() or not offset.is_finite() or minf(width, minf(height, depth)) < 0.0:
		return null
	var time_scale := duration / source.length
	if not is_finite(time_scale) or time_scale <= 0.0:
		return null
	var retime := duration != source.length
	var move_positions := scale != Vector3.ONE or offset != Vector3.ZERO
	var result := source.duplicate(true) as Animation
	for track in result.get_track_count():
		var tweak_positions := move_positions and _is_target_position(result, track, targets)
		if (retime or tweak_positions) and result.track_is_compressed(track):
			return null
		if tweak_positions and not _tweak_positions(result, track, scale, offset):
			return null
		if retime and not _retime_track(result, track, time_scale):
			return null
	if retime:
		if not _retime_markers(result, time_scale) or not _retime_socket_metadata(result, time_scale):
			return null
		result.length = duration
		result.step = source.step * time_scale
		if not is_finite(result.step):
			return null
	return result


static func _is_target_position(animation: Animation, track: int, targets: Array[NodePath]) -> bool:
	var path := animation.track_get_path(track)
	if animation.track_get_type(track) == Animation.TYPE_POSITION_3D:
		return path in targets
	if animation.track_get_type(track) == Animation.TYPE_VALUE and path.get_subname_count() == 1 \
			and path.get_subname(0) == &"position":
		return NodePath(String(path).trim_suffix(":position")) in targets
	return false


static func _tweak_positions(animation: Animation, track: int, scale: Vector3, offset: Vector3) -> bool:
	var bounds := AABB()
	var positions: Array[int] = []
	for index in animation.track_get_key_count(track):
		var value: Variant = animation.track_get_key_value(track, index)
		if not value is Vector3 and not value is Vector3i:
			continue
		var position := Vector3(value)
		if not position.is_finite():
			return false
		bounds = AABB(position, Vector3.ZERO) if positions.is_empty() else bounds.expand(position)
		positions.append(index)
	var center := bounds.get_center()
	for index in positions:
		var position := Vector3(animation.track_get_key_value(track, index))
		var adjusted := center + (position - center) * scale + offset
		if not adjusted.is_finite():
			return false
		animation.track_set_key_value(track, index, adjusted)
	return true


static func _retime_track(animation: Animation, track: int, time_scale: float) -> bool:
	var key_count := animation.track_get_key_count(track)
	var times := PackedFloat64Array()
	var move_order: Array[int] = []
	for index in key_count:
		var time := animation.track_get_key_time(track, index)
		if not is_finite(time * time_scale):
			return false
		times.append(time)
		if time * time_scale != time:
			move_order.append(index)

	# Expanding moves the outermost keys first. Shrinking moves the closest
	# keys first. Each key stays in order as Godot removes and reinserts it.
	var expanding := time_scale > 1.0
	move_order.sort_custom(func(a: int, b: int) -> bool:
		return absf(times[a]) > absf(times[b]) if expanding else absf(times[a]) < absf(times[b])
	)
	for index in move_order:
		animation.track_set_key_time(track, index, times[index] * time_scale)
		if animation.track_get_key_count(track) != key_count:
			return false
	if animation.track_get_type(track) == Animation.TYPE_BEZIER:
		# The horizontal handles are relative time offsets. Keep the curve shape
		# and its handle mode by updating the key value without reinserting it.
		for index in key_count:
			var point: Array = animation.track_get_key_value(track, index)
			point[1] *= time_scale
			point[3] *= time_scale
			if not is_finite(point[1]) or not is_finite(point[3]):
				return false
			animation.track_set_key_value(track, index, point)
	return true


static func _retime_markers(animation: Animation, time_scale: float) -> bool:
	var names := animation.get_marker_names()
	var times := PackedFloat64Array()
	var colors := PackedColorArray()
	for marker in names:
		var time := animation.get_marker_time(marker) * time_scale
		if not is_finite(time):
			return false
		times.append(time)
		colors.append(animation.get_marker_color(marker))
		animation.remove_marker(marker)
	for index in names.size():
		animation.add_marker(names[index], times[index])
		animation.set_marker_color(names[index], colors[index])
	return animation.get_marker_names().size() == names.size()


static func _retime_socket_metadata(animation: Animation, time_scale: float) -> bool:
	for field in SOCKET_TIME_METADATA:
		if not animation.has_meta(field):
			continue
		var times: Variant = animation.get_meta(field)
		if not times is PackedFloat32Array and not times is PackedFloat64Array:
			continue
		for index in times.size():
			times[index] *= time_scale
			if not is_finite(times[index]):
				return false
		animation.set_meta(field, times)
	return true
