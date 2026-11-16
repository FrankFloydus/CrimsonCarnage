@tool
extends PanelContainer
## Edits an ordered clip sequence and previews its transitions in the Tweaker.

signal combo_changed(data: Dictionary)
signal join_selected(index: int)
signal sequence_view_requested
signal play_join_requested(index: int)
signal play_combo_requested
signal stop_requested
signal seek_requested(seconds: float)
signal save_requested(path: String)
signal load_requested(path: String)

const DEFAULT_BLEND := 0.10
const DEFAULT_MARKER := 0
const CUSTOM_TIME := 1
const PreviewTimeline := preload("timeline.gd")
const ComboTracks := preload("combo_timeline_tracks.gd")

var _data: Dictionary = {"clips": [], "joins": [], "loop": true}
var _clip_context: Dictionary[StringName, Dictionary] = {}
var _path := ""
var _clip_index := -1
var _join_index := -1
var _preview_action := &""
var _playing := false
var _setting_transport := false
var _clip_ranges: Array[Dictionary] = []
var _blend_ranges: Array[Dictionary] = []
var _sequence_view := true

@onready var _clip_picker: OptionButton = %ClipPicker
@onready var _loop: CheckButton = %LoopCombo
@onready var _outgoing_label: Label = %OutgoingClip
@onready var _incoming_label: Label = %IncomingClip
@onready var _exit_picker: OptionButton = %ExitMarker
@onready var _entry_picker: OptionButton = %EntryMarker
@onready var _exit_time: SpinBox = %ExitTime
@onready var _entry_time: SpinBox = %EntryTime
@onready var _blend_duration: SpinBox = %BlendDuration
@onready var _play_join: Button = %PlayJoin
@onready var _play_combo: Button = %PlayCombo
@onready var _feedback: Label = %ComboFeedback
@onready var _file_dialog: FileDialog = %ComboFileDialog
@onready var _transport: PreviewTimeline = %ComboTime
@onready var _tracks: ComboTracks = %ComboTracks


func _ready() -> void:
	%AddClip.pressed.connect(_add_clip)
	%RemoveClip.pressed.connect(_remove_clip)
	%MoveClipUp.pressed.connect(_move_clip.bind(-1))
	%MoveClipDown.pressed.connect(_move_clip.bind(1))
	%SaveCombo.pressed.connect(_show_file_dialog.bind(true))
	%OpenCombo.pressed.connect(_show_file_dialog.bind(false))
	_file_dialog.file_selected.connect(_file_selected)
	_loop.toggled.connect(_set_loop)
	%ShowSequence.pressed.connect(sequence_view_requested.emit)
	_exit_picker.item_selected.connect(_set_endpoint.bind(true))
	_entry_picker.item_selected.connect(_set_endpoint.bind(false))
	_exit_time.value_changed.connect(_set_endpoint_time.bind(true))
	_entry_time.value_changed.connect(_set_endpoint_time.bind(false))
	_blend_duration.value_changed.connect(_set_blend)
	_play_join.pressed.connect(_request_preview.bind(&"join"))
	_play_combo.pressed.connect(_request_preview.bind(&"combo"))
	_transport.value_changed.connect(_seek)
	%ComboZoomIn.pressed.connect(_transport.zoom_in)
	%ComboZoomOut.pressed.connect(_transport.zoom_out)
	%ComboFit.pressed.connect(_transport.fit)
	_tracks.bind_ruler(_transport)
	_tracks.clip_selected.connect(_select_clip)
	_tracks.join_selected.connect(select_join)
	_tracks.scrub_requested.connect(_seek)
	_tracks.reorder_requested.connect(_reorder_clip)
	_rebuild_clip_picker()
	set_feedback("")
	_refresh()
	set_transport(0.0, 0.0, 0.0, 0.0, false)


## Update the clip choices and their marker definitions for the active preview rig.
func set_context(entries: Array[Dictionary]) -> void:
	_clip_context.clear()
	for entry in entries:
		_clip_context[StringName(entry.key)] = entry.duplicate(true)
	if is_node_ready():
		_rebuild_clip_picker()
		_refresh()


## Load an editable combo and its source resource path into the panel.
func set_combo(data: Dictionary, path := "") -> void:
	_data = data.duplicate(true)
	_data.clips = data.get("clips", []).duplicate()
	_data.joins = data.get("joins", []).duplicate(true)
	_data.loop = data.get("loop", true)
	var joins: Array = _data.joins
	for index in _data.clips.size() - joins.size():
		joins.append(_default_join())
	_path = path
	_clip_index = -1
	_join_index = -1
	if is_node_ready():
		set_feedback("")
		_refresh()


## Display the result of opening, saving, or resolving the current combo.
func set_feedback(message: String) -> void:
	_feedback.text = message
	_feedback.tooltip_text = message
	_feedback.visible = not message.is_empty()


## Update the resource identity after saving without disturbing the current edit or preview.
func set_saved_path(path: String, display_name: String) -> void:
	_path = path
	_data.display_name = display_name
	_refresh_title()
	set_feedback("")


## Synchronize the shared ruler with the active preview, using preview-relative seconds.
func set_transport(time: float, length: float, blend_start: float, blend_end: float,
		playing: bool) -> void:
	_setting_transport = true
	if not is_equal_approx(_transport.max_value, length):
		_transport.max_value = length
	if not is_equal_approx(_transport.value, time):
		_transport.value = time
	if _transport.editable != (length > 0.0):
		_transport.editable = length > 0.0
	_transport.set_loop_region(blend_start, blend_end)
	_setting_transport = false
	if _playing != playing:
		_playing = playing
		_refresh_playback()


## Display the intervals from the active playback schedule.
func set_timeline_layout(layout: Dictionary, sequence_view: bool) -> void:
	var changed_view := _sequence_view != sequence_view
	_sequence_view = sequence_view
	%ShowSequence.visible = not sequence_view
	_clip_ranges.assign(layout.get("clips", []))
	_blend_ranges.assign(layout.get("blends", []))
	for clip in _clip_ranges:
		clip.label = _clip_name(_data.clips[clip.index])
		clip.tooltip = String(_data.clips[clip.index])
	_refresh_tracks()
	if changed_view:
		_transport.fit()


## Select the outgoing step whose transition should be edited or previewed.
func select_join(index: int) -> void:
	if index < 0 or index >= _join_count():
		return
	_join_index = index
	_clip_index = index
	_update_order_actions()
	_refresh_transition()
	_refresh_tracks()
	join_selected.emit(index)


func get_selected_join() -> int:
	return _join_index


func is_modal_active() -> bool:
	return _file_dialog.visible


## Toggle the last preview mode, starting with the selected join.
func toggle_playback() -> void:
	if _playing:
		stop_requested.emit()
	elif _join_index >= 0:
		_request_preview(&"combo" if _sequence_view else &"join")


func _rebuild_clip_picker() -> void:
	var selected := StringName(_clip_picker.get_selected_metadata()) if _clip_picker.selected >= 0 else &""
	_clip_picker.clear()
	for key in _clip_context:
		var index := _clip_picker.item_count
		_clip_picker.add_item(String(key))
		_clip_picker.set_item_metadata(index, key)
		if key == selected:
			_clip_picker.select(index)
	if _clip_picker.item_count == 0:
		_clip_picker.add_item("No preview clips")
		_clip_picker.set_item_metadata(0, &"")
		_clip_picker.select(0)
	_clip_picker.disabled = _clip_context.is_empty()
	%AddClip.disabled = _clip_context.is_empty()


func _refresh() -> void:
	_refresh_title()
	var clips: Array = _data.clips
	_clip_index = clampi(_clip_index, 0, clips.size() - 1) if not clips.is_empty() else -1
	_update_order_actions()
	_loop.set_pressed_no_signal(_data.loop)
	_loop.disabled = clips.size() < 2
	%SaveCombo.disabled = clips.size() < 2
	_join_index = clampi(_join_index, 0, _join_count() - 1) if _join_count() > 0 else -1
	_refresh_transition()


func _refresh_tracks() -> void:
	var clips := _clip_ranges
	var has_timing := not clips.is_empty()
	_transport.visible = has_timing
	%TimeReadout.visible = has_timing
	for button: Button in [%ComboZoomIn, %ComboZoomOut, %ComboFit]:
		button.disabled = not has_timing
	if not has_timing and not _data.clips.is_empty():
		clips = []
		for index in _data.clips.size():
			var key: StringName = _data.clips[index]
			clips.append({"index": index, "label": _clip_name(key), "tooltip": String(key),
				"start": float(index), "end": index + 0.96, "lane": 0})
		_setting_transport = true
		_transport.max_value = float(clips.size())
		_transport.fit()
		_setting_transport = false
	_tracks.set_layout(clips, _blend_ranges, _clip_index, _join_index)
	_tracks.set_reorder_enabled(_sequence_view or not has_timing)


func _refresh_title() -> void:
	var title := String(_data.get("display_name", "")).strip_edges()
	%Title.text = "Combo" if title.is_empty() else title
	%Title.tooltip_text = title


func _refresh_transition() -> void:
	var has_join := _join_index >= 0
	%TransitionInspector.visible = has_join
	_refresh_playback()
	if not has_join:
		return
	var clips: Array = _data.clips
	var outgoing := StringName(clips[_join_index])
	var incoming := StringName(clips[(_join_index + 1) % clips.size()])
	var join: Dictionary = _data.joins[_join_index]
	_outgoing_label.text = "Exit · %s" % _clip_name(outgoing)
	_incoming_label.text = "Entry · %s" % _clip_name(incoming)
	_outgoing_label.tooltip_text = String(outgoing)
	_incoming_label.tooltip_text = String(incoming)
	_refresh_endpoint(_exit_picker, _exit_time, outgoing, join, true)
	_refresh_endpoint(_entry_picker, _entry_time, incoming, join, false)
	_blend_duration.set_value_no_signal(float(join.get("blend_duration", DEFAULT_BLEND)))


func _refresh_endpoint(picker: OptionButton, time: SpinBox, key: StringName, join: Dictionary,
		is_exit: bool) -> void:
	var marker_key := "exit_marker" if is_exit else "entry_marker"
	var time_key := "exit_time" if is_exit else "entry_time"
	var name := StringName(join.get(marker_key, &""))
	var seconds := float(join.get(time_key, -1.0))
	var context: Dictionary = _clip_context.get(key, {})
	var duration := float(context.get("duration", 0.0))
	var endpoint_time := duration if is_exit else 0.0
	picker.clear()
	picker.add_item("Clip End" if is_exit else "Clip Start")
	picker.add_item("Custom Time")
	var picked := DEFAULT_MARKER if seconds < 0.0 else CUSTOM_TIME
	for marker: Dictionary in context.get("markers", []):
		var marker_name := StringName(marker.name)
		var index := picker.item_count
		picker.add_item(String(marker_name))
		picker.set_item_metadata(index, marker_name)
		if marker_name == name:
			picked = index
			seconds = float(marker.time)
	if not name.is_empty() and picked <= CUSTOM_TIME:
		picked = picker.item_count
		picker.add_item("%s (missing)" % name)
		picker.set_item_metadata(picked, name)
	picker.select(picked)
	time.set_block_signals(true)
	time.max_value = duration
	time.set_value_no_signal(endpoint_time if seconds < 0.0 else seconds)
	time.set_block_signals(false)
	time.editable = picked == CUSTOM_TIME


func _refresh_playback() -> void:
	_play_join.text = "Stop Join" if _playing and _preview_action == &"join" else "Loop Join"
	_play_combo.text = "Stop Combo" if _playing and _preview_action == &"combo" else "Play Combo"
	_play_join.disabled = _join_index < 0
	_play_combo.disabled = _data.clips.size() < 2


func _select_clip(index: int) -> void:
	if _sequence_view and index < _join_count():
		select_join(index)
		return
	_clip_index = index
	_update_order_actions()
	_refresh_tracks()
	if _sequence_view:
		for clip in _clip_ranges:
			if clip.index == index:
				seek_requested.emit(float(clip.start))
				break


func _update_order_actions() -> void:
	%MoveClipUp.disabled = _clip_index <= 0
	%MoveClipDown.disabled = _clip_index < 0 or _clip_index + 1 >= _data.clips.size()
	%RemoveClip.disabled = _clip_index < 0


func _add_clip() -> void:
	if _clip_context.is_empty():
		return
	var positions := range(_data.clips.size())
	positions.append(-1)
	_apply_order(positions, _data.clips.size(), StringName(_clip_picker.get_selected_metadata()))


func _remove_clip() -> void:
	if _clip_index < 0:
		return
	var positions := range(_data.clips.size())
	positions.remove_at(_clip_index)
	_apply_order(positions, mini(_clip_index, positions.size() - 1))


func _move_clip(direction: int) -> void:
	_reorder_clip(_clip_index, _clip_index + direction)


func _reorder_clip(from_index: int, to_index: int) -> void:
	if from_index < 0 or from_index >= _data.clips.size() or to_index < 0 or to_index >= _data.clips.size():
		return
	if from_index == to_index:
		return
	var positions := range(_data.clips.size())
	positions.remove_at(from_index)
	positions.insert(to_index, from_index)
	_apply_order(positions, to_index)


func _apply_order(positions: Array, selected: int, added_key := &"") -> void:
	var previous_clips: Array = _data.clips
	var previous_joins: Array = _data.joins
	var clips: Array[StringName] = []
	var joins: Array[Dictionary] = []
	for index in positions.size():
		var old_position := int(positions[index])
		var next_old_position := int(positions[(index + 1) % positions.size()])
		clips.append(added_key if old_position < 0 else StringName(previous_clips[old_position]))
		var keep_join := old_position >= 0 and previous_clips.size() > 1 \
			and (old_position + 1) % previous_clips.size() == next_old_position
		joins.append(previous_joins[old_position] if keep_join else _default_join())
	_data.clips = clips
	_data.joins = joins
	_clip_index = selected
	_join_index = selected
	_publish_change()


func _set_loop(enabled: bool) -> void:
	_data.loop = enabled
	_publish_change()


func _set_endpoint(index: int, is_exit: bool) -> void:
	if _join_index < 0:
		return
	var picker := _exit_picker if is_exit else _entry_picker
	var time := _exit_time if is_exit else _entry_time
	var join: Dictionary = _data.joins[_join_index]
	var marker_key := "exit_marker" if is_exit else "entry_marker"
	var time_key := "exit_time" if is_exit else "entry_time"
	join[marker_key] = StringName(picker.get_item_metadata(index)) if index > CUSTOM_TIME else &""
	join[time_key] = time.value if index == CUSTOM_TIME else -1.0
	_refresh_transition()
	_publish_change(false)


func _set_endpoint_time(seconds: float, is_exit: bool) -> void:
	if _join_index < 0:
		return
	var join: Dictionary = _data.joins[_join_index]
	var time_key := "exit_time" if is_exit else "entry_time"
	join[time_key] = seconds
	_publish_change(false)


func _set_blend(seconds: float) -> void:
	if _join_index < 0:
		return
	_data.joins[_join_index].blend_duration = seconds
	_publish_change(false)


func _publish_change(refresh := true) -> void:
	if refresh:
		_refresh()
	combo_changed.emit(_data.duplicate(true))


func _join_count() -> int:
	var clips: Array = _data.clips
	if clips.size() < 2:
		return 0
	return clips.size() if _data.loop else clips.size() - 1


func _default_join() -> Dictionary:
	return {
		"exit_marker": &"", "entry_marker": &"", "exit_time": -1.0, "entry_time": -1.0,
		"blend_duration": DEFAULT_BLEND,
	}


func _clip_name(key: StringName) -> String:
	var context: Dictionary = _clip_context.get(key, {})
	return String(context.get("label", String(key).get_file().replace("_", " ").capitalize()))


func _request_preview(action: StringName) -> void:
	if _playing and _preview_action == action:
		stop_requested.emit()
		return
	_preview_action = action
	if action == &"join":
		play_join_requested.emit(_join_index)
	else:
		play_combo_requested.emit()
	_refresh_playback()


func _seek(seconds: float) -> void:
	if not _setting_transport:
		seek_requested.emit(seconds)


func _show_file_dialog(saving: bool) -> void:
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE if saving else FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.title = "Save Combo" if saving else "Open Combo"
	if not _path.is_empty():
		_file_dialog.current_dir = _path.get_base_dir()
		_file_dialog.current_file = _path.get_file() if saving else ""
	else:
		if DirAccess.dir_exists_absolute("res://data/animation_combos"):
			_file_dialog.current_dir = "res://data/animation_combos"
		_file_dialog.current_file = "combo.tres" if saving else ""
	_file_dialog.popup_centered()


func _file_selected(path: String) -> void:
	if _file_dialog.file_mode == FileDialog.FILE_MODE_SAVE_FILE:
		save_requested.emit(path)
	else:
		load_requested.emit(path)

