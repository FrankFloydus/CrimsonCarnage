@tool
class_name WeaponAnimationClipTracks
extends Resource
## Stores named markers, notify lanes and float curves with their owning animation.

const METADATA_KEY := &"weapon_tweaker_tracks"
const SCHEMA_VERSION := 1
const ONE_SHOT := -1.0
const GENERIC_NOTIFY := &""
const MELEE_TRACE := &"MeleeTrace"
const RichCurve := preload("rich_float_curve.gd")

## Version of the stored clip track data.
@export_storage var version := SCHEMA_VERSION
## Named timeline points in authoring order. Times are seconds and colors are optional.
@export_storage var markers: Array[Dictionary] = []
## Named notify lanes hold ordered entries with optional display colors and specialized kinds.
@export_storage var notify_tracks: Array[Dictionary] = []
## Named float curves store a rich curve on the normalized clip domain and an optional display color.
@export_storage var curve_tracks: Array[Dictionary] = []


## Read the saved tracks. Use copy() before editing a clip's data.
static func read_from(animation: Animation) -> WeaponAnimationClipTracks:
	if animation != null and animation.has_meta(METADATA_KEY):
		var stored := animation.get_meta(METADATA_KEY) as Resource
		if stored is WeaponAnimationClipTracks:
			return stored
		if stored != null and stored.get_class() == &"CrimsonWeaponAnimationTracks":
			return _from_native(stored)
	return WeaponAnimationClipTracks.new()


static func _from_native(stored: Resource) -> WeaponAnimationClipTracks:
	var converted := WeaponAnimationClipTracks.new()
	converted.version = stored.get(&"version")
	converted.markers.assign(stored.get(&"markers"))
	converted.notify_tracks.assign(stored.get(&"notify_tracks"))
	for marker in converted.markers:
		marker.name = String(marker.name)
	for notify_lane in converted.notify_tracks:
		notify_lane.name = String(notify_lane.name)
		for entry: Dictionary in notify_lane.notifies:
			entry.name = String(entry.name)
	for lane: Dictionary in stored.get(&"curve_tracks"):
		var curve: Variant = lane.get("curve")
		var converted_lane := lane.duplicate()
		converted_lane.name = String(lane.name)
		if curve is Array:
			var rich := RichCurve.new()
			rich.keys.assign(curve)
			converted_lane.curve = rich
		else:
			converted_lane.curve = _as_rich(curve)
		converted.curve_tracks.append(converted_lane)
	return converted


## Return an independent copy, including each embedded curve's keys and tangents.
func copy() -> WeaponAnimationClipTracks:
	return duplicate_deep(Resource.DEEP_DUPLICATE_ALL) as WeaponAnimationClipTracks


## Attach an independent copy to an animation. Empty data needs no metadata.
func write_to(animation: Animation) -> void:
	if is_empty():
		animation.remove_meta(METADATA_KEY)
	else:
		animation.set_meta(METADATA_KEY, copy())


## Return whether this clip has any Tweaker authoring data.
func is_empty() -> bool:
	return markers.is_empty() and notify_tracks.is_empty() and curve_tracks.is_empty()


## Find an authored marker by its exact name. Returns -1 when absent.
func marker_index(marker_name: StringName) -> int:
	for index in markers.size():
		if markers[index].name == marker_name:
			return index
	return -1


## Compare authored content independently of resource identity.
func same_content(other: WeaponAnimationClipTracks) -> bool:
	if other == null or version != other.version or markers != other.markers \
			or notify_tracks != other.notify_tracks \
			or curve_tracks.size() != other.curve_tracks.size():
		return false
	for index in curve_tracks.size():
		var lane := curve_tracks[index]
		var other_lane := other.curve_tracks[index]
		if lane.name != other_lane.name or lane.get("color") != other_lane.get("color") \
				or not _curves_equal(lane.curve, other_lane.curve):
			return false
	return true


## Validate names, timeline bounds and ordered curve keys before saving the candidate.
func is_valid(duration: float) -> bool:
	if version != SCHEMA_VERSION or not is_finite(duration) or duration <= 0.0:
		return false
	var marker_names := {}
	for marker in markers:
		var name: Variant = marker.get("name")
		if not _has_name(name) or name.strip_edges() != name or marker_names.has(name) \
				or not _valid_marker_time(marker.get("time"), duration) or not _valid_optional_color(marker):
			return false
		marker_names[name] = true
	for lane in notify_tracks:
		var entries: Variant = lane.get("notifies")
		if not _has_name(lane.get("name")) or not entries is Array:
			return false
		for entry: Variant in entries:
			if not entry is Dictionary or not _has_name(entry.get("name")) \
					or not _valid_notify_times(entry.get("time"), entry.get("end_time"), duration) \
					or not _valid_notify_kind(entry.get("kind", GENERIC_NOTIFY), entry.end_time) \
					or not _valid_optional_color(entry):
				return false
	var curve_names := {}
	for lane in curve_tracks:
		var name: Variant = lane.get("name")
		if not _has_name(name) or curve_names.has(name) or not _valid_curve(lane.get("curve")) \
				or not _valid_optional_color(lane):
			return false
		curve_names[name] = true
	return true


## Scale marker and notify times. Curves keep their normalized time coordinates.
func retime(time_scale: float) -> bool:
	if not is_finite(time_scale) or time_scale <= 0.0:
		return false
	var scaled_markers := markers.duplicate(true)
	for marker in scaled_markers:
		var original: Variant = marker.get("time")
		if not _valid_number(original):
			return false
		var time: float = original * time_scale
		if not _valid_marker_time(time, INF):
			return false
		marker.time = time
	var scaled_tracks := notify_tracks.duplicate(true)
	for lane: Dictionary in scaled_tracks:
		for entry: Dictionary in lane.notifies:
			var time: float = entry.time * time_scale
			var end_time: float = ONE_SHOT if entry.end_time == ONE_SHOT else entry.end_time * time_scale
			if not _valid_notify_times(time, end_time, INF):
				return false
			entry.time = time
			entry.end_time = end_time
	markers = scaled_markers
	notify_tracks = scaled_tracks
	return true


## Apply a timeline edit. Return the affected index, or -1 for a rejected or unchanged edit.
func apply_edit(operation: StringName, args: Dictionary, duration: float) -> int:
	if version != SCHEMA_VERSION:
		return -1
	var track: int = args.get("track", -1)
	var entry: int = args.get("entry", -1)
	var key: int = args.get("key", -1)
	var name: String = str(args.get("name", "")).strip_edges()
	match operation:
		&"add_marker", &"set_marker":
			return _store_marker(entry, args, duration, operation == &"add_marker")
		&"remove_marker":
			if not _has_index(markers, entry):
				return -1
			markers.remove_at(entry)
			return 0
		&"add_notify_track":
			return _add_track(false, name)
		&"add_curve_track":
			return _add_track(true, name)
		&"add_curve_preset":
			return _add_curve_preset(args.get("row", args))
		&"rename_track":
			return _rename_track(args.get("is_curve", false), track, name)
		&"remove_track":
			return _remove_track(args.get("is_curve", false), track)
		&"add_notify", &"set_notify":
			return _store_notify(track, entry, args, duration, operation == &"add_notify")
		&"remove_notify":
			return _remove_notify(track, entry)
		&"add_curve_key", &"set_curve_key":
			return _store_curve_key(track, key, args, operation == &"add_curve_key")
		&"remove_curve_key", &"remove_curve_keys", &"set_curve_key_smooth", \
				&"set_curve_key_mode", &"set_curve_key_weighted", &"set_curve_key_tangent", \
				&"move_curve_keys", &"blend_curve_neighbor":
			return _edit_curve_keys(operation, track, key, args)
		&"set_curve_color":
			return _set_curve_color(track, args.get("color"))
	return -1


func _store_marker(entry: int, args: Dictionary, duration: float, is_new: bool) -> int:
	if not is_finite(duration) or duration <= 0.0 or (not is_new and not _has_index(markers, entry)):
		return -1
	var previous: Dictionary = {} if is_new else markers[entry]
	var raw_name: Variant = args.get("name", previous.get("name"))
	if not (raw_name is String or raw_name is StringName):
		return -1
	var name := String(raw_name).strip_edges()
	var time: Variant = args.get("time", previous.get("time"))
	if name.is_empty() or not _valid_marker_time(time, duration) or not _valid_optional_color(args):
		return -1
	var existing := marker_index(StringName(name))
	if existing >= 0 and (is_new or existing != entry):
		return -1
	var marker := previous.duplicate()
	marker.name = name
	marker.time = minf(float(time), duration)
	if args.has("color"):
		marker.color = args.color
	if is_new:
		markers.append(marker)
		return markers.size() - 1
	if marker == previous:
		return -1
	markers[entry] = marker
	return entry


func _add_track(is_curve: bool, name: String) -> int:
	var tracks := curve_tracks if is_curve else notify_tracks
	if name.is_empty() or (is_curve and _curve_name_is_used(name)):
		return -1
	if is_curve:
		tracks.append({"name": name, "curve": RichCurve.new()})
	else:
		tracks.append({"name": name, "notifies": []})
	return tracks.size() - 1


func _add_curve_preset(row: Variant) -> int:
	if not row is Dictionary:
		return -1
	var name: Variant = row.get("name")
	var curve: Variant = row.get("curve")
	if not _has_name(name) or _curve_name_is_used(name) or not _valid_curve(curve) \
			or not _valid_optional_color(row):
		return -1
	var copied: Dictionary = {"name": name, "curve": _as_rich(curve).duplicate_deep()}
	if row.has("color"):
		copied.color = row.color
	curve_tracks.append(copied)
	return curve_tracks.size() - 1


func _rename_track(is_curve: bool, track: int, name: String) -> int:
	var tracks := curve_tracks if is_curve else notify_tracks
	if not _has_index(tracks, track) or name.is_empty() or tracks[track].name == name \
			or (is_curve and _curve_name_is_used(name)):
		return -1
	tracks[track].name = name
	return track


func _remove_track(is_curve: bool, track: int) -> int:
	var tracks := curve_tracks if is_curve else notify_tracks
	if not _has_index(tracks, track):
		return -1
	tracks.remove_at(track)
	return 0


func _store_notify(track: int, entry: int, args: Dictionary, duration: float, is_new: bool) -> int:
	if not _has_index(notify_tracks, track) or not is_finite(duration) or duration <= 0.0:
		return -1
	var entries: Array = notify_tracks[track].notifies
	if not is_new and not _has_index(entries, entry):
		return -1
	var previous: Dictionary = {} if is_new else entries[entry]
	var name := str(args.get("name", previous.get("name", ""))).strip_edges()
	var time: Variant = args.get("time", previous.get("time"))
	var end_time: Variant = args.get("end_time", previous.get("end_time", ONE_SHOT))
	var kind: Variant = previous.get("kind", GENERIC_NOTIFY)
	if is_new:
		kind = args.get("kind", GENERIC_NOTIFY)
	elif args.has("kind") and args.kind != kind:
		return -1
	if name.is_empty() or not _valid_notify_times(time, end_time, duration) \
			or not _valid_notify_kind(kind, end_time) or not _valid_optional_color(args):
		return -1
	var value := previous.duplicate()
	value.name = name
	value.time = float(time)
	value.end_time = float(end_time)
	if is_new and kind != GENERIC_NOTIFY:
		value.kind = StringName(kind)
	if args.has("color"):
		value.color = args.color
	if is_new:
		entries.append(value)
		return entries.size() - 1
	if previous == value:
		return -1
	entries[entry] = value
	return entry


func _remove_notify(track: int, entry: int) -> int:
	if not _has_index(notify_tracks, track):
		return -1
	var entries: Array = notify_tracks[track].notifies
	if not _has_index(entries, entry):
		return -1
	entries.remove_at(entry)
	return 0


func _set_curve_color(track: int, color: Variant) -> int:
	if not _has_index(curve_tracks, track) or not _valid_color(color) \
			or curve_tracks[track].get("color") == color:
		return -1
	curve_tracks[track].color = color
	return track


func _store_curve_key(track: int, key: int, args: Dictionary, is_new: bool) -> int:
	var curve := curve_at(track)
	var phase: Variant = args.get("phase")
	var value: Variant = args.get("value")
	if curve == null or not _valid_number(phase) or not _valid_number(value):
		return -1
	var moved := true
	var updated: int
	if is_new:
		updated = curve.add_key(phase, value)
	else:
		if key < 0 or key >= curve.point_count:
			return -1
		var info := curve.key_info(key)
		moved = info.phase != phase or info.value != value
		updated = curve.set_key_position(key, phase, value)
	if updated < 0:
		return -1
	if args.has("smooth"):
		moved = curve.set_keys_mode([updated], _smooth_mode(args.smooth)) or moved
	if moved:
		curve_tracks[track].curve = curve
	return updated if moved else -1


func _edit_curve_keys(operation: StringName, track: int, key: int, args: Dictionary) -> int:
	var curve := curve_at(track)
	if curve == null:
		return -1
	var selection: Variant = args.get("keys", [key])
	var index := -1
	match operation:
		&"remove_curve_key", &"remove_curve_keys":
			if curve.remove_keys(selection):
				index = 0
		&"set_curve_key_smooth":
			if curve.set_keys_mode([key], _smooth_mode(args.get("smooth", false))):
				index = key
		&"set_curve_key_mode":
			if curve.set_keys_mode(selection, args.get("mode", -1)):
				index = selection[0]
		&"set_curve_key_weighted":
			if curve.set_keys_weighted(selection, args.get("weighted", false), args.get("incoming")):
				index = selection[0]
		&"set_curve_key_tangent":
			if curve.set_key_tangent(key, args.get("incoming", false), args.get("offset", Vector2.ZERO)):
				index = key
		&"move_curve_keys":
			var moved := curve.move_keys(selection, args.get("delta", Vector2.ZERO))
			if not moved.is_empty():
				index = moved[0]
		&"blend_curve_neighbor":
			var amount: Variant = args.get("amount")
			if _valid_number(amount) and curve.blend_neighbor(selection, amount):
				index = selection[0]
	if index >= 0:
		curve_tracks[track].curve = curve
	return index


## Return a read model for a track, upgrading its legacy native curve transiently.
func curve_at(track: int) -> RichCurve:
	return _as_rich(curve_tracks[track].get("curve")) if _has_index(curve_tracks, track) else null


static func _as_rich(curve: Variant) -> RichCurve:
	if curve is RichCurve:
		return curve
	if not curve is Curve:
		return null
	var converted := RichCurve.new()
	return converted if converted.load_native(curve) else null


static func _smooth_mode(smooth: bool) -> int:
	return RichCurve.Mode.AUTO if smooth else RichCurve.Mode.LINEAR


func _curve_name_is_used(name: String) -> bool:
	for track in curve_tracks:
		if track.name == name:
			return true
	return false


static func _has_name(value: Variant) -> bool:
	return value is String and not value.strip_edges().is_empty()


static func _has_index(items: Array, index: int) -> bool:
	return index >= 0 and index < items.size()


static func _valid_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


static func _valid_notify_kind(kind: Variant, end_time: Variant) -> bool:
	return (kind is StringName or kind is String) and (kind == GENERIC_NOTIFY \
			or (kind == MELEE_TRACE and end_time != ONE_SHOT))


static func _valid_optional_color(entry: Dictionary) -> bool:
	return not entry.has("color") or _valid_color(entry.color)


static func _valid_color(value: Variant) -> bool:
	return value is Color and is_finite(value.r) and is_finite(value.g) \
			and is_finite(value.b) and is_finite(value.a)


static func _valid_marker_time(time: Variant, duration: float) -> bool:
	return _valid_number(time) and time >= 0.0 and (time <= duration or is_equal_approx(time, duration))


static func _valid_notify_times(time: Variant, end_time: Variant, duration: float) -> bool:
	if not _valid_number(time) or not _valid_number(end_time) or time < 0.0 \
			or (time > duration and not is_equal_approx(time, duration)):
		return false
	return end_time == ONE_SHOT or (end_time > time \
			and (end_time <= duration or is_equal_approx(end_time, duration)))


static func _valid_curve(curve: Variant) -> bool:
	var converted := _as_rich(curve)
	return converted != null and converted.is_valid()


static func _curves_equal(first: Variant, second: Variant) -> bool:
	if first == second:
		return true
	var left := _as_rich(first)
	var right := _as_rich(second)
	return left != null and right != null and left.same_keys(right)
