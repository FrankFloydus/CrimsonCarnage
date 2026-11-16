@tool
extends RefCounted
## Converts a Viewer clip pack to editable camera-local Animation resources.

const FORMAT := "vermintide_tweaker_clips"
const VERSION := 1
const MIN_DURATION := 0.001
const TIME_TOLERANCE := 0.000001
const SOCKET_SIDES := ["right", "left"]


## Read the pack header and clip structure without changing an AnimationPlayer.
static func read_pack(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("Could not open the clip pack. %s" % error_string(FileAccess.get_open_error()))
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		return _failure("Invalid clip pack JSON at line %d. %s" % [
			parser.get_error_line(), parser.get_error_message(),
		])
	if parser.data is not Dictionary:
		return _failure("The clip pack must contain a JSON object.")
	var pack: Dictionary = parser.data
	if pack.get("format") != FORMAT or pack.get("version") != VERSION or pack.get("axes") != "godot":
		return _failure("Choose a version %d Viewer clip pack in Godot coordinates." % VERSION)
	var rig: Variant = pack.get("rig")
	if not rig is Dictionary or not rig.get("name") is String or not rig.get("nodes") is Array:
		return _failure("The clip pack has an invalid rig header.")
	var rig_error := _validate_rig(rig.nodes)
	if not rig_error.is_empty():
		return _failure(rig_error)
	var clips: Variant = pack.get("clips")
	if not clips is Array or clips.is_empty():
		return _failure("The clip pack contains no animations.")
	for index in clips.size():
		var clip: Variant = clips[index]
		if not clip is Dictionary:
			return _failure("Clip %d must contain an animation object." % (index + 1))
		var clip_error := _validate_clip(clip, rig.nodes.size())
		if not clip_error.is_empty():
			return _failure("%s: %s" % [clip.get("name", "Clip %d" % (index + 1)), clip_error])
	pack["error"] = ""
	return pack


## Build one clip for the provided target paths. Joint tracks require a compatible hierarchy.
## No supplied resources are mutated, and an invalid clip produces no Animation.
static func build_animation(pack: Dictionary, clip: Dictionary, socket_paths: Dictionary,
		camera_path: NodePath, native_paths: Dictionary = {}) -> Dictionary:
	var rig: Dictionary = pack.get("rig", {})
	var rows: Array = rig.get("nodes", [])
	var clip_error := _validate_clip(clip, rows.size())
	if not clip_error.is_empty():
		return _failure(clip_error)

	var animation := Animation.new()
	animation.resource_name = clip.name
	animation.length = float(clip.duration)
	animation.step = float(clip.step)
	animation.set_meta(&"native_animation_id", clip.id)
	animation.set_meta(&"source_animation_name", clip.name)
	animation.set_meta(&"weapon_set", clip.weapon_set)

	var times := _key_times(clip.times, animation.length)
	var sockets: Dictionary = clip.sockets
	for side in SOCKET_SIDES:
		if not sockets.has(side):
			continue
		var path: NodePath = socket_paths.get(side, NodePath())
		if path.is_empty():
			return _failure("The preview rig has no %s weapon socket." % side)
		if not _write_transform_tracks(animation, path, times, sockets[side]):
			return _failure("The %s weapon socket contains an invalid transform." % side)
		animation.set_meta(StringName("%s_socket_key_times" % side), times)

	var camera: Array = clip.get("camera", [])
	var camera_bound := not camera.is_empty() and not camera_path.is_empty()
	if camera_bound:
		var track := animation.add_track(Animation.TYPE_VALUE)
		animation.track_set_path(track, camera_path)
		animation.value_track_set_update_mode(track, Animation.UPDATE_CONTINUOUS)
		for index in times.size():
			var pose: Variant = _read_transform(camera[index])
			if pose == null:
				return _failure("The camera contains an invalid transform at %.6f s." % times[index])
			animation.track_insert_key(track, times[index], pose)

	var poses: Array = clip.get("poses", [])
	var pose_paths: Array[NodePath] = []
	if not poses.is_empty():
		pose_paths = _compatible_pose_paths(rows, native_paths)
	if not pose_paths.is_empty():
		for joint in rows.size():
			var path: NodePath = pose_paths[joint]
			if path.is_empty():
				continue
			var values: Array = []
			values.resize(times.size())
			for frame in times.size():
				values[frame] = poses[frame][joint]
			if not _write_transform_tracks(animation, path, times, values):
				return _failure("Joint %s contains an invalid transform." % rows[joint].name)
		animation.set_meta(&"viewer_pose_track", true)

	for marker: Dictionary in clip.get("markers", []):
		animation.add_marker(StringName(marker.name), float(marker.time))
	return {
		"animation": animation,
		"pose_bound": not pose_paths.is_empty(),
		"camera_bound": camera_bound,
		"error": "",
	}


static func _failure(message: String) -> Dictionary:
	return {"error": message}


static func _validate_rig(rows: Array) -> String:
	var names := {}
	for index in rows.size():
		var row: Variant = rows[index]
		if not row is Dictionary or not _nonempty_text(row.get("name")) or not _finite_number(row.get("parent")):
			return "Rig joint %d has an invalid name or parent." % (index + 1)
		var parent := int(row.parent)
		if float(parent) != float(row.parent) or parent < -1 or parent >= rows.size() or parent == index:
			return "Rig joint %s has an invalid parent index." % row.name
		if names.has(row.name):
			return "The clip pack has more than one rig joint named %s." % row.name
		names[row.name] = true
	for index in rows.size():
		var current := index
		var traversed := 0
		while current >= 0 and traversed < rows.size():
			current = int(rows[current].parent)
			traversed += 1
		if current >= 0:
			return "The clip pack contains a cycle in the rig hierarchy."
	return ""


static func _validate_clip(clip: Dictionary, joint_count: int) -> String:
	if not _nonempty_text(clip.get("id")) or not _nonempty_text(clip.get("name")) 			or not clip.get("weapon_set") is String:
		return "The source clip ID, name, or weapon set is missing."
	if not _finite_number(clip.get("duration")) or float(clip.duration) < MIN_DURATION 			or not _finite_number(clip.get("step")) or float(clip.step) < 0.0:
		return "The clip duration or sample step is invalid."
	var duration := float(clip.duration)
	var times: Variant = clip.get("times")
	if not times is Array or times.is_empty():
		return "The clip has no sample times."
	var previous := -INF
	for index in times.size():
		var time: Variant = times[index]
		if not _finite_number(time):
			return "The clip contains an invalid sample time."
		var seconds := float(time)
		if index == 0 and absf(seconds) <= TIME_TOLERANCE:
			seconds = 0.0
		elif index == times.size() - 1 and absf(seconds - duration) <= TIME_TOLERANCE:
			seconds = duration
		if seconds <= previous or seconds < 0.0 or seconds > duration:
			return "Sample times must increase from zero to the clip duration."
		previous = seconds
	if absf(times[0]) > TIME_TOLERANCE or absf(times[-1] - duration) > TIME_TOLERANCE:
		return "The clip is missing its first or last sample."

	var sockets: Variant = clip.get("sockets")
	if not sockets is Dictionary or sockets.is_empty():
		return "The clip has no weapon socket samples."
	for side in sockets:
		if side not in SOCKET_SIDES or not _sample_count_matches(sockets[side], times.size()):
			return "The %s socket sample count does not match the clip." % side

	var camera: Variant = clip.get("camera", [])
	if not camera is Array or (not camera.is_empty() and camera.size() != times.size()):
		return "The camera sample count does not match the clip."

	var poses: Variant = clip.get("poses", [])
	if not poses is Array or (not poses.is_empty() and (poses.size() != times.size() or joint_count == 0)):
		return "The rig pose sample count does not match the clip."
	for frame: Variant in poses:
		if not _sample_count_matches(frame, joint_count):
			return "A rig pose has the wrong number of joints."

	var markers: Variant = clip.get("markers", [])
	if not markers is Array:
		return "The clip markers must be an array."
	var marker_names := {}
	for marker: Variant in markers:
		if not marker is Dictionary or not _nonempty_text(marker.get("name")) 				or not _finite_number(marker.get("time")) or marker.time < 0.0 or marker.time > duration:
			return "A clip marker has an invalid name or time."
		if marker_names.has(marker.name):
			return "More than one clip marker is named %s." % marker.name
		marker_names[marker.name] = true
	return ""


static func _compatible_pose_paths(rows: Array, native_paths: Dictionary) -> Array[NodePath]:
	var result: Array[NodePath] = []
	if native_paths.is_empty():
		return result
	var joint_indices := {}
	for index in rows.size():
		joint_indices[String(rows[index].name)] = index
	var target_paths := {}
	for target_name in native_paths:
		var target_path: NodePath = native_paths[target_name]
		if target_path.is_empty() or target_paths.has(target_path):
			return []
		target_paths[target_path] = true

	# Accept source rigs with additional joints only when every target joint has
	# the same immediate parent. Their local tracks can then be used directly.
	result.resize(rows.size())
	for target_name in native_paths:
		var index: int = joint_indices.get(String(target_name), -1)
		if index < 0:
			return []
		var target_path: NodePath = native_paths[target_name]
		var target_parent := NodePath(String(target_path).get_base_dir())
		var parent := int(rows[index].parent)
		if parent < 0:
			if target_paths.has(target_parent):
				return []
		else:
			var expected: NodePath = native_paths.get(String(rows[parent].name), NodePath())
			if expected.is_empty() or target_parent != expected:
				return []
		result[index] = target_path
	return result


static func _key_times(samples: Array, duration: float) -> PackedFloat64Array:
	var times := PackedFloat64Array(samples)
	times[0] = 0.0
	if times.size() > 1:
		times[-1] = duration
	return times


static func _write_transform_tracks(animation: Animation, path: NodePath, times: PackedFloat64Array,
		values: Array) -> bool:
	var position_track := animation.add_track(Animation.TYPE_POSITION_3D)
	var rotation_track := animation.add_track(Animation.TYPE_ROTATION_3D)
	var scale_track := animation.add_track(Animation.TYPE_SCALE_3D)
	for track in [position_track, rotation_track, scale_track]:
		animation.track_set_path(track, path)

	var previous_rotation := Quaternion.IDENTITY
	for index in times.size():
		var decoded: Variant = _read_transform(values[index])
		if decoded == null:
			return false
		var pose: Transform3D = decoded
		var scale := pose.basis.get_scale()
		var rotation := pose.basis.get_rotation_quaternion()
		if not scale.is_finite() or not rotation.is_finite() or not rotation.is_normalized():
			return false
		if index > 0 and previous_rotation.dot(rotation) < 0.0:
			rotation = -rotation
		previous_rotation = rotation
		animation.position_track_insert_key(position_track, times[index], pose.origin)
		animation.rotation_track_insert_key(rotation_track, times[index], rotation)
		animation.scale_track_insert_key(scale_track, times[index], scale)
	return true


static func _read_transform(values: Variant) -> Variant:
	if not values is Array or values.size() != 12:
		return null
	for component: Variant in values:
		if not _finite_number(component):
			return null
	var pose := Transform3D(
		Vector3(values[0], values[1], values[2]),
		Vector3(values[3], values[4], values[5]),
		Vector3(values[6], values[7], values[8]),
		Vector3(values[9], values[10], values[11])
	)
	var determinant := pose.basis.determinant()
	if not pose.is_finite() or not is_finite(determinant) or determinant <= 0.0:
		return null
	return pose


static func _nonempty_text(value: Variant) -> bool:
	return value is String and not value.strip_edges().is_empty()


static func _finite_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


static func _sample_count_matches(samples: Variant, expected: int) -> bool:
	return samples is Array and samples.size() == expected
