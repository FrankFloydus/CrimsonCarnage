@tool
extends RefCounted
## Samples the selected combo join on the Tweaker's private preview rig.

const CONTEXT_SECONDS := 0.25
const SAMPLE_CLIP := &"pose"
const LOCAL_TRANSFORM_PROPERTIES: Array[StringName] = [
	&"transform", &"basis", &"position", &"quaternion", &"rotation", &"rotation_degrees", &"scale",
]

class Source:
	var sampler: AnimationPlayer
	var length: float
	var camera_fallback: Callable
	var index: int
	var lane: int


class Span:
	var outgoing: Source
	var incoming: Source
	var start: float
	var blend: float
	var end: float
	var outgoing_start: float
	var incoming_start: float


var length := 0.0
var time := 0.0
var blend_start := 0.0
var blend_end := 0.0
var effective_blend := 0.0

var _camera: Camera3D
var _stage: Node
var _bind_pose: Dictionary[Node3D, Transform3D] = {}
var _nodes: Array[Node3D] = []
var _sources: Array[Source] = []
var _spans: Array[Span] = []
var _outgoing_pose: Array[Transform3D] = []
var _looping := true


## Capture the authored bind pose before the normal preview changes the rig.
func configure(player: AnimationPlayer, camera: Camera3D) -> void:
	clear()
	_stage = player.get_parent()
	_camera = camera
	_bind_pose.clear()
	_bind_pose[camera] = camera.transform
	for child in camera.find_children("*", "Node3D", true, false):
		var node := child as Node3D
		_bind_pose[node] = node.transform


## Build the window around the join and show its first frame.
## The blend ends on the outgoing exit and starts on the incoming entry.
func setup(outgoing: Animation, incoming: Animation, join: Dictionary,
		outgoing_camera := Callable(), incoming_camera := Callable(), join_index := 0, incoming_index := 1) -> bool:
	clear()
	if not _valid_stage() or not _valid_source(outgoing) or not _valid_source(incoming):
		return false

	var exit_time := float(join.get("exit_time", outgoing.length))
	var entry_time := float(join.get("entry_time", 0.0))
	var requested_blend := float(join.get("blend_duration", 0.0))
	if not _valid_join(exit_time, entry_time, requested_blend, outgoing, incoming):
		return false
	var incoming_available := incoming.length - entry_time
	var overlap := minf(maxf(0.0, requested_blend), minf(exit_time, incoming_available))
	var lead_in := minf(CONTEXT_SECONDS, exit_time - overlap)
	var lead_out := minf(CONTEXT_SECONDS, incoming_available - overlap)
	if lead_in + overlap + lead_out <= 0.0:
		return false

	if not _load_sources([outgoing, incoming], [outgoing_camera, incoming_camera]):
		return false
	_sources[0].index = join_index
	_sources[1].index = incoming_index
	effective_blend = overlap
	blend_start = lead_in
	blend_end = lead_in + overlap
	_append_span(_sources[0], exit_time - overlap - lead_in, lead_in, overlap, _sources[1], entry_time)
	_append_span(_sources[1], entry_time + overlap, lead_out)
	seek(0.0)
	return true


## Play the sequence's trimmed ranges and adjoining blends in authored order.
func setup_sequence(clips: Array[Animation], joins: Array[Dictionary], loop: bool,
		camera_fallbacks: Array[Callable] = []) -> bool:
	clear()
	var count := clips.size()
	var join_count := count if loop else count - 1
	if not _valid_stage() or count < 2 or joins.size() != join_count:
		return false
	var starts := PackedFloat64Array()
	var ends := PackedFloat64Array()
	var overlaps := PackedFloat64Array()
	starts.resize(count)
	ends.resize(count)
	overlaps.resize(count)
	for index in count:
		if not _valid_source(clips[index]):
			return false
		ends[index] = clips[index].length
	for index in join_count:
		var next := (index + 1) % count
		var exit_time := float(joins[index].get("exit_time", ends[index]))
		var entry_time := float(joins[index].get("entry_time", 0.0))
		var requested_blend := float(joins[index].get("blend_duration", 0.0))
		if not _valid_join(exit_time, entry_time, requested_blend, clips[index], clips[next]):
			return false
		ends[index] = exit_time
		starts[next] = entry_time
		overlaps[index] = maxf(0.0, requested_blend)
	var total_duration := 0.0
	for index in count:
		var duration := ends[index] - starts[index]
		if duration < 0.0:
			return false
		total_duration += duration
	if total_duration <= 0.0 or not _load_sources(clips, camera_fallbacks):
		return false

	_fit_overlaps(starts, ends, overlaps)
	_looping = loop
	for index in count:
		var previous := (index + count - 1) % count
		var source_start := starts[index] + overlaps[previous]
		var solo_duration := maxf(0.0, ends[index] - source_start - overlaps[index])
		if index < join_count:
			var next := (index + 1) % count
			_append_span(_sources[index], source_start, solo_duration, overlaps[index], _sources[next], starts[next])
		else:
			_append_span(_sources[index], source_start, solo_duration)
	# Start at the pose reached by the closing transition so the replay seam is continuous.
	seek(0.0)
	return true


## Project the playback spans into clip bands and blend bands in preview seconds.
## The closing blend draws the returning clip opposite the outgoing clip.
func get_timeline_layout() -> Dictionary:
	var clips: Array[Dictionary] = []
	var blends: Array[Dictionary] = []
	for span in _spans:
		_append_timeline_clip(clips, span.outgoing.index, span.start, span.end, span.outgoing.lane)
		if span.incoming != null:
			blends.append({"index": span.outgoing.index, "start": span.blend, "end": span.end})
			_append_timeline_clip(clips, span.incoming.index, span.blend, span.end, 1 - span.outgoing.lane)
	return {"clips": clips, "blends": blends}


## Show one exact, marker-relative preview pose.
func seek(seconds: float) -> void:
	if length <= 0.0 or not _valid_stage() or not is_finite(seconds):
		return
	time = clampf(seconds, 0.0, length)
	var span: Span = _spans.back()
	for candidate in _spans:
		if time < candidate.end:
			span = candidate
			break
	_seek_span(span)


## Advance independently of each source clip's own loop mode.
func advance(delta: float) -> void:
	if length > 0.0:
		seek(fposmod(time + delta, length) if _looping else time + delta)


## Release the samplers and restore the bind pose before resuming the single clip.
func clear() -> void:
	for source in _sources:
		if is_instance_valid(source.sampler):
			source.sampler.stop(true)
			source.sampler.queue_free()
	_restore_bind_pose()
	_sources.clear()
	_spans.clear()
	_outgoing_pose.clear()
	_nodes.clear()
	_looping = true
	length = 0.0
	time = 0.0
	blend_start = 0.0
	blend_end = 0.0
	effective_blend = 0.0


func _valid_stage() -> bool:
	return is_instance_valid(_stage) and _stage.is_inside_tree() and is_instance_valid(_camera)


func _valid_source(animation: Animation) -> bool:
	return animation != null and is_finite(animation.length) and animation.length > 0.0


func _valid_join(exit_time: float, entry_time: float, duration: float, outgoing: Animation, incoming: Animation) -> bool:
	return is_finite(exit_time) and is_finite(entry_time) and is_finite(duration) \
			and exit_time >= 0.0 and exit_time <= outgoing.length and entry_time >= 0.0 and entry_time <= incoming.length


func _fit_overlaps(starts: PackedFloat64Array, ends: PackedFloat64Array, overlaps: PackedFloat64Array) -> void:
	var count := overlaps.size()
	var limits := PackedFloat64Array()
	limits.resize(count)
	for index in count:
		var next := (index + 1) % count
		overlaps[index] = minf(overlaps[index], minf(ends[index] - starts[index], ends[next] - starts[next]))
	for index in count:
		var previous := (index + count - 1) % count
		var total := overlaps[previous] + overlaps[index]
		limits[index] = minf(1.0, (ends[index] - starts[index]) / total) if total > 0.0 else 1.0
	# If two blends compete for the same trimmed clip, fit both within its range.
	for index in count:
		overlaps[index] *= minf(limits[index], limits[(index + 1) % count])


func _load_sources(clips: Array[Animation], camera_fallbacks: Array[Callable]) -> bool:
	for index in clips.size():
		var clip := _transform_clip(clips[index])
		if clip.get_track_count() == 0:
			clear()
			return false
		var source := Source.new()
		source.length = clip.length
		source.index = index
		source.lane = index % 2
		if index < camera_fallbacks.size() and not _has_camera_track(clip):
			source.camera_fallback = camera_fallbacks[index]
		# A value track in one clip can safely blend into a typed transform track
		# in another when each sampler only caches one clip's track set.
		source.sampler = _make_sampler(clip)
		_sources.append(source)
	if not _nodes.has(_camera):
		_nodes.append(_camera)
	_outgoing_pose.resize(_nodes.size())
	return true


func _append_span(outgoing: Source, outgoing_start: float, solo: float, overlap := 0.0,
		incoming: Source = null, incoming_start := 0.0) -> void:
	var span := Span.new()
	span.outgoing = outgoing
	span.incoming = incoming
	span.start = length
	span.blend = length + solo
	span.end = span.blend + overlap
	span.outgoing_start = outgoing_start
	span.incoming_start = incoming_start
	_spans.append(span)
	length = span.end


func _append_timeline_clip(clips: Array[Dictionary], index: int, start: float, end: float, lane: int) -> void:
	if end <= start:
		return
	if not clips.is_empty():
		var previous: Dictionary = clips.back()
		if previous.index == index and previous.end == start and previous.lane == lane:
			previous.end = end
			return
	clips.append({"index": index, "start": start, "end": end, "lane": lane})


func _seek_span(span: Span) -> void:
	if span.incoming == null or time < span.blend or (time == span.blend and span.end > span.blend):
		_sample(span.outgoing, span.outgoing_start + time - span.start)
		return
	var incoming_time := span.incoming_start + time - span.blend
	if time >= span.end:
		_sample(span.incoming, incoming_time)
		return
	_sample(span.outgoing, span.outgoing_start + time - span.start)
	for index in _nodes.size():
		_outgoing_pose[index] = _nodes[index].transform
	_sample(span.incoming, incoming_time)
	var weight := (time - span.blend) / (span.end - span.blend)
	for index in _nodes.size():
		var node := _nodes[index]
		node.transform = _outgoing_pose[index].interpolate_with(node.transform, weight)


func _transform_clip(source: Animation) -> Animation:
	var clip := source.duplicate() as Animation
	clip.loop_mode = Animation.LOOP_NONE
	for track in range(clip.get_track_count() - 1, -1, -1):
		var path := clip.track_get_path(track)
		var kind := clip.track_get_type(track)
		var transform_track := (
			path.get_subname_count() == 0 and kind in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D]
		) or (
			path.get_subname_count() == 1 and kind == Animation.TYPE_VALUE and path.get_subname(0) in LOCAL_TRANSFORM_PROPERTIES
		)
		if not transform_track or not clip.track_is_enabled(track) or clip.track_get_key_count(track) == 0:
			clip.remove_track(track)
			continue
		var node := _stage.get_node_or_null(NodePath(String(path.get_concatenated_names()))) as Node3D
		if node == null or not _bind_pose.has(node):
			clip.remove_track(track)
		elif not _nodes.has(node):
			_nodes.append(node)
	return clip


func _has_camera_track(clip: Animation) -> bool:
	var camera_path := _stage.get_path_to(_camera)
	for track in clip.get_track_count():
		if clip.track_get_path(track).get_concatenated_names() == camera_path.get_concatenated_names():
			return true
	return false


func _make_sampler(clip: Animation) -> AnimationPlayer:
	var sampler := AnimationPlayer.new()
	sampler.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	sampler.playback_auto_capture = false
	var library := AnimationLibrary.new()
	library.add_animation(SAMPLE_CLIP, clip)
	sampler.add_animation_library(&"", library)
	_stage.add_child(sampler)
	sampler.play(SAMPLE_CLIP, 0.0)
	return sampler


func _sample(source: Source, seconds: float) -> void:
	_restore_bind_pose()
	var clip_time := clampf(seconds, 0.0, source.length)
	source.sampler.seek(clip_time, true, true)
	if source.camera_fallback.is_valid():
		_camera.transform = source.camera_fallback.call(clip_time / source.length)


func _restore_bind_pose() -> void:
	for node in _nodes:
		if is_instance_valid(node) and node.transform != _bind_pose[node]:
			node.transform = _bind_pose[node]
