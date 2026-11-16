@tool
extends RefCounted
## Supplies native first-person bone tracks for the tweaker.

const DATA_PATH := "res://addons/weapon_animation_tweaker/native_pose/vermintide_1h_sword_native_pose.json"
const CLIP_META := &"native_pose_clip"

var _definition: Dictionary = {}
var _attempted_load := false


func clip_name(animation: Animation, key: StringName) -> String:
	if animation == null or animation.has_meta(&"source_animation_name"):
		return ""
	if animation.has_meta(CLIP_META):
		var saved := String(animation.get_meta(CLIP_META))
		if _clip(saved).size() > 0:
			return saved
	if key == &"1h_sword/idle":
		return "sword_idle"
	if animation.resource_name.ends_with("/1h_sword/swing_left_diagonal.animation") \
			or String(key).begins_with("1h_sword_swing_L_diagonal"):
		return "swing_left_diagonal"
	return ""


func nodes(rig: Node3D) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if rig == null:
		return result
	result.resize(_rows().size())
	for node in rig.find_children("*", "Node3D", true, false):
		var index := int(node.get_meta(&"native_pose_index", -1))
		if index >= 0 and index < result.size():
			result[index] = node
	if result.has(null):
		result.clear()
	return result


func parents() -> PackedInt32Array:
	var result := PackedInt32Array()
	for row: Dictionary in _rows():
		result.append(int(row["parent"]))
	return result


func socket_index(left: bool) -> int:
	var definition := _load_definition()
	var rig: Dictionary = definition.get("rig", {})
	var sockets: Dictionary = rig.get("sockets", {})
	return int(sockets.get("left" if left else "right", -1))


func with_tracks(source: Animation, name: String, paths: Array[NodePath]) -> Animation:
	var ref_clip := _clip(name)
	var rows := _rows()
	if ref_clip.is_empty() or paths.size() != rows.size() or paths.is_empty():
		return source
	if source.has_meta(CLIP_META) and source.find_track(paths[0], Animation.TYPE_POSITION_3D) >= 0:
		return source
	var result := source.duplicate(true) as Animation
	result.set_meta(CLIP_META, name)
	var times: Array = ref_clip["times"]
	var poses: Array = ref_clip["poses"]
	var cameras: Array = ref_clip["camera_world"]
	var time_scale := source.length / float(ref_clip["duration"])
	for bone in paths.size():
		var path := paths[bone]
		var position_track := _add_track(result, path, Animation.TYPE_POSITION_3D)
		var rotation_track := _add_track(result, path, Animation.TYPE_ROTATION_3D)
		var scale_track := _add_track(result, path, Animation.TYPE_SCALE_3D)
		if position_track < 0 and rotation_track < 0 and scale_track < 0:
			continue
		var frame_count := times.size()
		if int(rows[bone]["parent"]) >= 0 and poses.all(func(frame: Array) -> bool: return frame[bone] == poses[0][bone]):
			frame_count = 1
		for frame in frame_count:
			var time := clampf(float(times[frame]) * time_scale, 0.0, source.length)
			var pose := _transform(poses[frame][bone])
			if int(rows[bone]["parent"]) < 0:
				pose = _transform(cameras[frame]).affine_inverse() * pose
			if position_track >= 0:
				result.position_track_insert_key(position_track, time, pose.origin)
			if rotation_track >= 0:
				result.rotation_track_insert_key(rotation_track, time, pose.basis.get_rotation_quaternion())
			if scale_track >= 0:
				result.scale_track_insert_key(scale_track, time, pose.basis.get_scale())
	return result


## The source camera in preview coordinates, measured from the clip's first pose.
func camera_motion(name: String, phase: float) -> Transform3D:
	var clip := _clip(name)
	if clip.is_empty() or clip["camera_world"].size() < 2:
		return Transform3D.IDENTITY
	var times: Array = clip["times"]
	var poses: Array = clip["camera_world"]
	var source_time := clampf(phase, 0.0, 1.0) * float(clip["duration"])
	var right := clampi(times.bsearch(source_time), 1, times.size() - 1)
	var previous := float(times[right - 1])
	var next := float(times[right])
	var weight := clampf(inverse_lerp(previous, next, source_time), 0.0, 1.0)
	var pose := _transform(poses[right - 1]).interpolate_with(_transform(poses[right]), weight)
	return (_transform(poses[0]).affine_inverse() * pose).orthonormalized()


func key_times(animation: Animation, path: NodePath) -> PackedFloat64Array:
	var result := PackedFloat64Array()
	for type in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D]:
		var track := animation.find_track(path, type)
		if track < 0:
			continue
		for i in animation.track_get_key_count(track):
			result.append(animation.track_get_key_time(track, i))
	return result


func _load_definition() -> Dictionary:
	if not _attempted_load:
		_attempted_load = true
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		if parsed is Dictionary and parsed.get("format") == "vermintide_native_first_person_pose":
			_definition = parsed
	return _definition


func _rows() -> Array:
	var rig: Dictionary = _load_definition().get("rig", {})
	return rig.get("nodes", [])


func _clip(name: String) -> Dictionary:
	var clips: Dictionary = _load_definition().get("clips", {})
	return clips.get(name, {})


static func _add_track(animation: Animation, path: NodePath, type: Animation.TrackType) -> int:
	if animation.find_track(path, type) >= 0:
		return -1
	var track := animation.add_track(type)
	animation.track_set_path(track, path)
	return track


static func _transform(values: Array) -> Transform3D:
	return Transform3D(
		Vector3(values[0], values[1], values[2]),
		Vector3(values[3], values[4], values[5]),
		Vector3(values[6], values[7], values[8]),
		Vector3(values[9], values[10], values[11])
	)

