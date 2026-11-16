@tool
class_name WeaponAnimationClip
extends RefCounted
## Runtime snapshot of a saved Weapon Animation Tweaker clip.

const ClipTracks := preload("clip_tracks.gd")
const RichCurve := preload("rich_float_curve.gd")

## Interpolation modes reported by get_curve_keys().
const CurveMode := RichCurve.Mode
## Saved kind for a MeleeTrace notify state.
const MELEE_TRACE := ClipTracks.MELEE_TRACE

## Event types in their dispatch order at a shared timestamp.
enum EventType {
	## End a notify state.
	STATE_ENDED,
	## Begin a notify state.
	STATE_STARTED,
	## Cross a one-shot notify.
	NOTIFY,
	## Cross a named marker.
	MARKER,
}

var _duration := 0.0
var _curves: Dictionary[StringName, RichCurve] = {}
var _curve_info: Dictionary[StringName, Dictionary] = {}
var _markers: Dictionary[StringName, Dictionary] = {}
var _marker_rows: Array[Dictionary] = []
var _notify_track_names := PackedStringArray()
var _notifies: Array[Dictionary] = []
var _states: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _event_times := PackedFloat64Array()


func _init(animation: Animation = null) -> void:
	if animation == null:
		return
	var duration := animation.length
	var tracks := ClipTracks.read_from(animation).copy()
	if not tracks.is_valid(duration):
		return
	_duration = duration
	for index in tracks.curve_tracks.size():
		var lane := tracks.curve_tracks[index]
		var curve := tracks.curve_at(index)
		var name := StringName(lane.name)
		_curves[name] = curve
		var info := {"name": name, "key_count": curve.point_count}
		if lane.has("color"):
			info.color = lane.color
		_curve_info[name] = info
	for index in tracks.markers.size():
		var marker := tracks.markers[index].duplicate()
		marker.name = StringName(marker.name)
		marker.time = minf(marker.time, duration)
		_markers[marker.name] = marker
		_marker_rows.append(marker)
		var event := marker.duplicate()
		event.type = EventType.MARKER
		_append_event(event)
	for track_index in tracks.notify_tracks.size():
		var lane := tracks.notify_tracks[track_index]
		_notify_track_names.append(lane.name)
		var entries: Array = lane.notifies
		for entry_index in entries.size():
			_index_notify(entries[entry_index], lane.name, track_index, entry_index)
	_events.sort_custom(_event_less)
	for event in _events:
		event.erase("_order")
		_event_times.append(event.time)


## Read an independent snapshot of an Animation. Invalid data returns null.
static func from_animation(animation: Animation) -> WeaponAnimationClip:
	var script := load("res://addons/weapon_animation_tweaker/weapon_animation_clip.gd") as GDScript
	var clip := script.new(animation) as WeaponAnimationClip
	return clip if clip.get_duration() > 0.0 else null


## Read a clip by the same key accepted by AnimationPlayer.play().
static func from_player(player: AnimationPlayer, key: StringName) -> WeaponAnimationClip:
	if player == null or not player.has_animation(key):
		return null
	return from_animation(player.get_animation(key))


## Clip length in seconds.
func get_duration() -> float:
	return _duration


## Curve names in authoring order.
func get_curve_names() -> PackedStringArray:
	var names := PackedStringArray()
	for name in _curves:
		names.append(String(name))
	return names


## Return the curve's name, key count, and optional authored color, or an empty Dictionary.
func get_curve_info(name: StringName) -> Dictionary:
	return _curve_info.get(name, {}).duplicate()


## Return copied keys, including seconds, normalized phase, mode, and tangent attributes.
func get_curve_keys(name: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var curve: RichCurve = _curves.get(name)
	if curve != null:
		for index in curve.point_count:
			var key := curve.key_info(index)
			key.time = key.phase * _duration
			result.append(key)
	return result


## Evaluate a named curve at a clip time in seconds.
func sample_curve(name: StringName, seconds: float, fallback: float = 0.0) -> float:
	if _duration <= 0.0:
		return fallback
	return sample_curve_normalized(name, seconds / _duration, fallback)


## Evaluate at normalized clip phase. Empty curves and nonfinite input return the fallback.
func sample_curve_normalized(name: StringName, phase: float, fallback: float = 0.0) -> float:
	var curve: RichCurve = _curves.get(name)
	if curve == null or curve.point_count == 0 or not is_finite(phase):
		return fallback
	return curve.sample(clampf(phase, 0.0, 1.0))


## Copy the Tweaker markers in authoring order.
func get_markers() -> Array[Dictionary]:
	return _marker_rows.duplicate(true)


## Find a named Tweaker marker, or return an empty Dictionary.
func get_marker(name: StringName) -> Dictionary:
	return _markers.get(name, {}).duplicate()


## Find the marker's time in seconds. The default missing value is -1.
func get_marker_time(name: StringName, fallback: float = -1.0) -> float:
	var marker: Dictionary = _markers.get(name, {})
	return marker.get("time", fallback)


## Notify lane names in authoring order.
func get_notify_track_names() -> PackedStringArray:
	return _notify_track_names.duplicate()


## Copy one-shot notifies, optionally filtered by exact name.
func get_notifies(name: StringName = &"") -> Array[Dictionary]:
	return _select_records(_notifies, name)


## Copy notify states, optionally filtered by exact name.
func get_notify_states(name: StringName = &"") -> Array[Dictionary]:
	return _select_records(_states, name)


## Copy states active at the given time. A state is active from its start up to its end.
func get_active_notify_states(seconds: float, kind: StringName = &"") -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for state in _states:
		if seconds >= state.time and seconds < state.end_time and (kind.is_empty() or state.kind == kind):
			result.append(state.duplicate())
	return result


## Read events in (from_seconds, to_seconds]. Set include_start to include the left boundary.
## Times outside the clip are clipped to it. Backward or nonfinite input returns an empty array.
func get_events_crossed(from_seconds: float, to_seconds: float,
		include_start: bool = false) -> Array[Dictionary]:
	if not is_finite(from_seconds) or not is_finite(to_seconds) or from_seconds > to_seconds:
		return []
	if from_seconds > _duration or to_seconds < 0.0:
		return []
	return _events_in_range(maxf(0.0, from_seconds), minf(_duration, to_seconds),
			include_start or from_seconds < 0.0)


## Read events when playback crossed the end of exactly one loop interval.
## Returns the tail (from, loop_end] followed by the head [loop_start, to].
## Use -1 for the full clip's loop end, or pass the authored loop bounds in seconds.
func get_loop_events_crossed(from_seconds: float, to_seconds: float,
		loop_start: float = 0.0, loop_end: float = -1.0) -> Array[Dictionary]:
	var end := _duration if loop_end == -1.0 else loop_end
	if not (loop_start >= 0.0 and end <= _duration and loop_start < end
			and from_seconds >= loop_start and from_seconds <= end
			and to_seconds >= loop_start and to_seconds <= end):
		return []
	var result := _events_in_range(from_seconds, end, false)
	result.append_array(_events_in_range(loop_start, to_seconds, true))
	return result


func _index_notify(entry: Dictionary, track_name: String, track_index: int, entry_index: int) -> void:
	var notify := {
		"name": StringName(entry.name), "time": minf(entry.time, _duration),
		"kind": StringName(entry.get("kind", ClipTracks.GENERIC_NOTIFY)),
		"track_name": StringName(track_name), "track_index": track_index, "entry_index": entry_index,
	}
	if entry.has("color"):
		notify.color = entry.color
	if entry.end_time == ClipTracks.ONE_SHOT:
		_notifies.append(notify)
		var event := notify.duplicate()
		event.type = EventType.NOTIFY
		_append_event(event)
		return
	notify.end_time = minf(entry.end_time, _duration)
	_states.append(notify)
	var start_event := notify.duplicate()
	start_event.type = EventType.STATE_STARTED
	start_event.start_time = notify.time
	_append_event(start_event)
	var end_event := start_event.duplicate()
	end_event.type = EventType.STATE_ENDED
	end_event.time = notify.end_time
	_append_event(end_event)


func _append_event(event: Dictionary) -> void:
	event._order = _events.size()
	_events.append(event)


static func _event_less(left: Dictionary, right: Dictionary) -> bool:
	if left.time != right.time:
		return left.time < right.time
	if left.type != right.type:
		return left.type < right.type
	return left._order < right._order


static func _select_records(records: Array[Dictionary], name: StringName) -> Array[Dictionary]:
	if name.is_empty():
		return records.duplicate(true)
	var result: Array[Dictionary] = []
	for record in records:
		if record.name == name:
			result.append(record.duplicate())
	return result


func _events_in_range(from_seconds: float, to_seconds: float, include_start: bool) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var first := _event_times.bsearch(from_seconds, include_start)
	var stop := _event_times.bsearch(to_seconds, false)
	for index in range(first, stop):
		result.append(_events[index].duplicate())
	return result
