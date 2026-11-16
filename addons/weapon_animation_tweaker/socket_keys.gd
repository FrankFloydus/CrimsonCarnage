@tool
extends RefCounted
## Edits the selected socket's position and rotation on a private motion draft.

const POSITION_PROPERTIES: Array[StringName] = [&"position", &"global_position"]
const ROTATION_PROPERTIES: Array[StringName] = [&"quaternion", &"rotation", &"rotation_degrees", &"global_rotation", &"global_rotation_degrees"]
const TRANSFORM_PROPERTIES: Array[StringName] = [&"transform", &"global_transform", &"basis", &"global_basis", &"rotation_order"]


## Key the socket's local position and rotation at the requested clip time.
## Returns false if the draft does not have a single editable writer per channel.
static func set_pose(animation: Animation, path: NodePath, seconds: float, pose: Transform3D) -> bool:
	if not _valid_sample(animation, path, seconds) or not pose.is_finite() or is_zero_approx(pose.basis.determinant()):
		return false
	var channels := _find_channels(animation, path)
	if channels.x < 0 or channels.y < 0:
		return false
	var rotation := pose.basis.get_rotation_quaternion()
	if not rotation.is_finite() or not rotation.is_normalized():
		return false
	var rotation_value: Variant = rotation
	if animation.track_get_type(channels.y) == Animation.TYPE_VALUE:
		match animation.track_get_path(channels.y).get_subname(0):
			&"rotation":
				rotation_value = rotation.get_euler()
			&"rotation_degrees":
				rotation_value = rotation.get_euler() * (180.0 / PI)

	var position_time := _write_key(animation, channels.x, seconds, pose.origin)
	var rotation_time := _write_key(animation, channels.y, seconds, rotation_value)
	_add_authored_time(animation, path, position_time)
	if rotation_time != position_time:
		_add_authored_time(animation, path, rotation_time)
	return true


## Sample the editable channels using Godot's interpolation for the draft.
## The caller supplies local scale because the helper edits position and rotation only.
static func sample_pose(animation: Animation, path: NodePath, seconds: float, scale: Vector3 = Vector3.ONE) -> Variant:
	if not _valid_sample(animation, path, seconds) or not scale.is_finite():
		return null
	var channels := _find_channels(animation, path)
	if channels.x < 0 or channels.y < 0:
		return null
	var origin: Variant
	if animation.track_get_type(channels.x) == Animation.TYPE_POSITION_3D:
		origin = animation.position_track_interpolate(channels.x, seconds)
	else:
		origin = animation.value_track_interpolate(channels.x, seconds)
	if origin is not Vector3 or not origin.is_finite():
		return null
	var rotation: Variant
	if animation.track_get_type(channels.y) == Animation.TYPE_ROTATION_3D:
		rotation = animation.rotation_track_interpolate(channels.y, seconds)
	else:
		rotation = animation.value_track_interpolate(channels.y, seconds)
		var property := animation.track_get_path(channels.y).get_subname(0)
		if property != &"quaternion":
			if rotation is not Vector3 or not rotation.is_finite():
				return null
			var euler: Vector3 = rotation
			if property == &"rotation_degrees":
				euler *= PI / 180.0
			rotation = Quaternion.from_euler(euler)
	if rotation is not Quaternion or not rotation.is_finite() or not rotation.is_normalized():
		return null
	return Transform3D(Basis(rotation).scaled_local(scale), origin)


static func _valid_sample(animation: Animation, path: NodePath, seconds: float) -> bool:
	return animation != null and not path.is_empty() and path.get_name_count() > 0 and path.get_subname_count() == 0 \
			and is_finite(animation.length) and is_finite(seconds) and seconds >= 0.0 and seconds <= animation.length


static func _find_channels(animation: Animation, path: NodePath) -> Vector2i:
	var tracks := Vector2i(-1, -1)
	for track in animation.get_track_count():
		if not animation.track_is_enabled(track):
			continue
		var track_path := animation.track_get_path(track)
		if track_path.is_empty() or track_path.is_absolute() != path.is_absolute() \
				or track_path.get_concatenated_names() != path.get_concatenated_names():
			continue
		var channel := -1
		var type := animation.track_get_type(track)
		if track_path == path:
			if type == Animation.TYPE_POSITION_3D:
				channel = 0
			elif type == Animation.TYPE_ROTATION_3D:
				channel = 1
		elif track_path.get_subname_count() > 0 and type in [Animation.TYPE_VALUE, Animation.TYPE_BEZIER]:
			var property := track_path.get_subname(0)
			if property in TRANSFORM_PROPERTIES:
				return Vector2i(-1, -1)
			if property not in POSITION_PROPERTIES and property not in ROTATION_PROPERTIES:
				continue
			if track_path.get_subname_count() != 1 or type != Animation.TYPE_VALUE \
					or animation.value_track_get_update_mode(track) != Animation.UPDATE_CONTINUOUS:
				return Vector2i(-1, -1)
			match property:
				&"position":
					channel = 0
				&"quaternion", &"rotation", &"rotation_degrees":
					channel = 1
				_:
					return Vector2i(-1, -1)
		if channel < 0:
			continue
		# Typed and indexed-property caches may both write to the same Node3D.
		if tracks[channel] >= 0 or animation.track_is_compressed(track) or animation.track_get_key_count(track) == 0:
			return Vector2i(-1, -1)
		tracks[channel] = track
	return tracks


static func _write_key(animation: Animation, track: int, seconds: float, value: Variant) -> float:
	var key := _nearby_key(animation, track, seconds)
	if key >= 0:
		animation.track_set_key_value(track, key, value)
		return animation.track_get_key_time(track, key)
	animation.track_insert_key(track, seconds, value)
	return seconds


static func _nearby_key(animation: Animation, track: int, seconds: float) -> int:
	var count := animation.track_get_key_count(track)
	var lower := 0
	var upper := count
	# Godot replaces approximately equal times on insertion. Find the nearest
	# existing key first so close native samples keep their times and transitions.
	while lower < upper:
		var middle := lower + ((upper - lower) >> 1)
		if animation.track_get_key_time(track, middle) < seconds:
			lower = middle + 1
		else:
			upper = middle
	var before := animation.track_get_key_time(track, lower - 1) if lower > 0 else -INF
	var after := animation.track_get_key_time(track, lower) if lower < count else INF
	var has_after := lower < count and is_equal_approx(after, seconds)
	var has_before := lower > 0 and is_equal_approx(before, seconds)
	if has_after and (not has_before or after - seconds <= seconds - before):
		return lower
	if has_before:
		return lower - 1
	return -1


static func _add_authored_time(animation: Animation, path: NodePath, seconds: float) -> void:
	var field: StringName
	match path.get_name(path.get_name_count() - 1):
		&"WeaponControl":
			field = &"right_socket_key_times"
		&"LeftWeaponControl":
			field = &"left_socket_key_times"
		_:
			return
	if not animation.has_meta(field):
		return
	var times: Variant = animation.get_meta(field)
	if times is not PackedFloat32Array and times is not PackedFloat64Array:
		return
	times = times.duplicate()
	for time: float in times:
		if is_equal_approx(time, seconds):
			return
	times.append(seconds)
	times.sort()
	animation.set_meta(field, times)
