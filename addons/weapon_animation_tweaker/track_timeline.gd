@tool
extends VBoxContainer
## Manages track editing controls and forwards committed authoring actions to the Tweaker.

signal edit_requested(operation: StringName, args: Dictionary)
signal seek_requested(time: float)
signal status_requested(message: String)

const ClipTracks := preload("clip_tracks.gd")
const RichCurve := preload("rich_float_curve.gd")
const CurvePresets := preload("curve_presets.gd")
const Timeline := preload("timeline.gd")
const TrackCanvas := preload("track_timeline_canvas.gd")
const KEY_MODE_MENU_START := 40
const PRESET_MENU_START := 200
const MODE_MIXED := 5
const MODE_LABELS := ["Constant", "Linear", "Auto", "Broken Tangents"]

## IDs shared by the add-track and timeline context menus.
enum {
	## Adds an empty notify lane to the current clip.
	ADD_NOTIFY_TRACK,
	## Adds an empty float curve to the current clip.
	ADD_CURVE_TRACK,
	## Adds a one-shot notify at the menu time.
	ADD_NOTIFY,
	## Adds a notify state near the menu time.
	ADD_STATE,
	## Inserts a curve key at the menu coordinates.
	ADD_CURVE_KEY,
	## Removes the selected track.
	REMOVE_TRACK = 6,
	## Focuses the selected track's name field.
	RENAME_TRACK,
	## Adds a typed MeleeTrace state near the menu time.
	ADD_MELEE_TRACE,
	## Fits a float curve in the graph.
	FRAME_CURVE,
	## Saves the curve's name, color, keys and tangents for reuse.
	SAVE_CURVE_PRESET,
	## Expands or collapses the curve in the timeline.
	TOGGLE_CURVE_VIEW,
	## Toggles weighted tangents for the chosen keys.
	TOGGLE_WEIGHTED,
	## Adds a named clip marker at the menu time.
	ADD_CLIP_MARKER,
	## Focuses the selected marker's name field.
	RENAME_CLIP_MARKER,
	## Removes the selected clip marker.
	REMOVE_CLIP_MARKER,
}

var _ruler: Timeline
var _tracks: ClipTracks
var _duration := 0.0
var _playhead := 0.0
var _is_curve := false
var _track := -1
var _entry := -1
var _marker_selected := false
var _marker_entry := -1
var _menu_time := 0.0
var _menu_value := 0.0
var _filling_details := false
var _color_editing := false
var _color_origin := Color.WHITE
var _presets: CurvePresets
var _blend_source: RichCurve
var _blend_track := -1
var _blend_keys := PackedInt32Array()

@onready var _toolbar: Control = %TrackToolbar
@onready var _add: MenuButton = %AddTrack
@onready var _key_mode: MenuButton = %CurveKeyMode
@onready var _move_axis: OptionButton = %CurveMoveAxis
@onready var _blend: HSlider = %CurveBlend
@onready var _blend_readout: Label = %CurveBlendValue
@onready var _scroll: ScrollContainer = %TrackScroll
@onready var _canvas: TrackCanvas = %TrackCanvas
@onready var _fields: Control = %TrackEditFields
@onready var _empty: Control = %TrackDetailsEmpty
@onready var _selection_type: Label = %TrackSelectionType
@onready var _name_row: Control = %TrackNameRow
@onready var _time_row: Control = %TrackTimeRow
@onready var _end_row: Control = %TrackEndRow
@onready var _value_row: Control = %TrackValueRow
@onready var _interpolation_row: Control = %TrackInterpolationRow
@onready var _weighted_row: Control = %TrackWeightedRow
@onready var _color_row: Control = %TrackColorRow
@onready var _time_label: Label = %TrackTimeLabel
@onready var _item_name: LineEdit = %TrackItemName
@onready var _item_time: SpinBox = %TrackItemTime
@onready var _item_end: SpinBox = %TrackItemEnd
@onready var _item_value: SpinBox = %TrackItemValue
@onready var _interpolation: OptionButton = %TrackInterpolation
@onready var _weighted: CheckBox = %TrackWeighted
@onready var _item_color: ColorPickerButton = %TrackItemColor
@onready var _menu: PopupMenu = %TrackContextMenu


func _ready() -> void:
	var add_menu := _add.get_popup()
	add_menu.about_to_popup.connect(_fill_add_menu)
	add_menu.id_pressed.connect(_on_menu_action)
	_fill_add_menu()
	for mode in MODE_LABELS.size():
		_interpolation.add_item(MODE_LABELS[mode], mode)
		_key_mode.get_popup().add_radio_check_item(MODE_LABELS[mode], mode)
	_interpolation.add_item("Custom", RichCurve.Mode.LEGACY)
	_interpolation.set_item_disabled(_interpolation.get_item_index(RichCurve.Mode.LEGACY), true)
	_interpolation.add_item("Mixed", MODE_MIXED)
	_interpolation.set_item_disabled(_interpolation.get_item_index(MODE_MIXED), true)
	_key_mode.get_popup().id_pressed.connect(_set_key_mode)
	_move_axis.add_item("Free", 0)
	_move_axis.add_item("Time Only", 1)
	_move_axis.add_item("Value Only", 2)
	_move_axis.select(0)
	_move_axis.item_selected.connect(_on_move_axis_selected)
	_blend.drag_started.connect(_begin_neighbor_blend)
	_blend.drag_ended.connect(_end_neighbor_blend)
	_blend.value_changed.connect(_update_neighbor_blend)
	_menu.id_pressed.connect(_on_menu_action)
	_item_name.text_submitted.connect(_commit_name.unbind(1))
	_item_name.focus_exited.connect(_commit_name)
	_item_time.value_changed.connect(_commit_time)
	_item_end.value_changed.connect(_commit_end)
	_item_value.value_changed.connect(_commit_value)
	_interpolation.item_selected.connect(_commit_interpolation)
	_weighted.toggled.connect(_commit_weighted)
	_item_color.get_popup().about_to_popup.connect(_begin_color_edit)
	_item_color.color_changed.connect(_preview_color)
	_item_color.popup_closed.connect(_commit_color)
	_canvas.selection_requested.connect(select_track)
	_canvas.curve_selection_changed.connect(_on_curve_selection_changed)
	_canvas.seek_requested.connect(seek_requested.emit)
	_canvas.menu_requested.connect(_open_menu)
	_canvas.edit_requested.connect(edit_requested.emit)
	_canvas.remove_requested.connect(_remove_selected)
	_canvas.marker_selection_requested.connect(select_marker)
	_canvas.marker_menu_requested.connect(_open_marker_menu)
	_canvas.marker_remove_requested.connect(_remove_marker)
	%AddClipMarker.pressed.connect(add_marker_at_playhead)
	_canvas.resized.connect(_align_ruler)
	_scroll.resized.connect(_resize_canvas)
	_bind_canvas()
	_refresh_clip()


## Share the primary clip ruler. The comparison ruler stays independent.
func bind_ruler(ruler: Timeline) -> void:
	_ruler = ruler
	if is_node_ready():
		_bind_canvas()


## Replace the selected clip's display data. A null clip closes the authoring panel.
func set_clip(tracks: ClipTracks, duration: float) -> void:
	if _tracks == tracks and _duration == duration:
		return
	_tracks = tracks
	_duration = duration
	if is_node_ready():
		_reset_neighbor_blend()
		_refresh_clip()


## Update the window shading and curve readouts during playback or scrubbing.
func set_playhead(time: float) -> void:
	_playhead = time
	if is_node_ready():
		_canvas.set_playhead(time)


## Re-select the row or entry after a successful draft edit.
func select_track(is_curve: bool, track: int, entry: int = -1) -> void:
	_marker_selected = false
	_marker_entry = -1
	_is_curve = is_curve
	_track = track
	_entry = entry
	if is_node_ready():
		_fill_selection()


## Select an authored marker without changing the preview time.
func select_marker(entry: int) -> void:
	_marker_selected = true
	_marker_entry = entry
	_is_curve = false
	_track = -1
	_entry = -1
	if is_node_ready():
		_fill_selection()


## Insert a named marker at the visible playhead and focus its name.
func add_marker_at_playhead() -> void:
	_add_marker(_playhead)


## Consume Delete for the focused timeline before the editor's scene shortcut.
func handle_delete_key(focused: Control, repeat: bool) -> bool:
	if focused != _canvas:
		return false
	if not repeat:
		if _has_marker():
			_remove_marker(_marker_entry)
		elif not _marker_selected:
			_remove_selected()
	return true


## Fit the value axes when the timeline toolbar fits the whole clip.
func fit_value_axes() -> void:
	_canvas.fit_value_axes()


func _bind_canvas() -> void:
	if is_instance_valid(_ruler):
		_canvas.bind_ruler(_ruler)
		_align_ruler()


func _refresh_clip() -> void:
	visible = _tracks != null and _duration > 0.0
	_toolbar.visible = visible
	if not visible:
		_color_editing = false
		_item_color.get_popup().hide()
		_track = -1
		_entry = -1
		_marker_selected = false
		_marker_entry = -1
		_menu.hide()
	_canvas.set_clip(_tracks, _duration)
	_canvas.set_playhead(_playhead)
	_scroll.visible = _canvas.row_height() > 0.0
	_resize_canvas()
	_fill_selection()
	_align_ruler()


func _resize_canvas() -> void:
	_canvas.set_viewport_height(_scroll.size.y)


func _align_ruler() -> void:
	if not is_instance_valid(_ruler):
		return
	var has_rows := visible and _canvas.row_height() > 0.0
	var trailing := maxf(_ruler.size.x - _canvas.size.x, 0.0)
	_ruler.set_track_insets(TrackCanvas.HEADER_WIDTH if has_rows else 0.0, trailing if has_rows else 0.0)


func _fill_selection() -> void:
	if _filling_details:
		return
	_filling_details = true
	_fill_details()
	_filling_details = false


func _on_curve_selection_changed() -> void:
	_fill_selection()


func _fill_details() -> void:
	if _marker_selected:
		_fill_marker_details()
		return
	_canvas.set_marker_selection(-1)
	var rows: Array[Dictionary] = []
	if _tracks != null:
		rows = _tracks.curve_tracks if _is_curve else _tracks.notify_tracks
	_fields.visible = _track >= 0 and _track < rows.size()
	_empty.visible = not _fields.visible
	if not _fields.visible:
		_track = -1
		_entry = -1
		_canvas.set_selection(_is_curve, _track, _entry)
		_key_mode.disabled = true
		_move_axis.disabled = true
		_blend.editable = false
		return
	var row := rows[_track]
	var curve := _tracks.curve_at(_track) if _is_curve else null
	var count: int = curve.point_count if _is_curve else row.notifies.size()
	if _entry >= count:
		_entry = -1
	_canvas.set_selection(_is_curve, _track, _entry)
	var keys := _curve_keys()
	var has_keys := not keys.is_empty()
	_key_mode.disabled = not has_keys
	_move_axis.disabled = not _is_curve
	_blend.editable = has_keys and count > 1
	_name_row.show()
	_time_row.visible = _entry >= 0 and keys.size() <= 1
	_end_row.hide()
	_time_label.text = "Time"
	_value_row.visible = has_keys and keys.size() == 1
	_interpolation_row.visible = has_keys
	_weighted_row.visible = has_keys
	_color_row.visible = _is_curve or _entry >= 0
	_item_time.min_value = 0.0
	_item_time.max_value = _duration
	_item_end.min_value = 0.0
	_item_end.max_value = _duration
	if _is_curve:
		_item_name.text = row.name
		_set_picker_color(row.get("color", _default_color(true)))
	if _entry < 0:
		_selection_type.text = "Float Curve" if _is_curve else "Notify Track"
		_item_name.text = row.name
	elif _is_curve:
		_selection_type.text = "Curve Key" if keys.size() == 1 else "%d Curve Keys" % keys.size()
		_item_time.set_value_no_signal(curve.get_key_phase(_entry) * _duration)
		_item_value.set_value_no_signal(curve.get_key_value(_entry))
		_fill_key_modes(curve, keys)
	else:
		var item: Dictionary = row.notifies[_entry]
		_end_row.visible = item.end_time >= 0.0
		_selection_type.text = "Notify State" if _end_row.visible else "Notify"
		if item.get("kind", ClipTracks.GENERIC_NOTIFY) == ClipTracks.MELEE_TRACE:
			_selection_type.text = "MeleeTrace"
		_item_name.text = item.name
		_item_time.set_value_no_signal(item.time)
		_set_picker_color(item.get("color", _default_color(false)))
		if _end_row.visible:
			_time_label.text = "Start"
			_item_time.max_value = maxf(item.end_time - _item_time.step, item.time)
			_item_end.min_value = minf(item.time + _item_end.step, item.end_time)
			_item_end.set_value_no_signal(item.end_time)


func _has_marker() -> bool:
	return _marker_selected and _tracks != null and _marker_entry >= 0 and _marker_entry < _tracks.markers.size()


func _fill_marker_details() -> void:
	_canvas.set_selection(false, -1, -1)
	var valid := _has_marker()
	_canvas.set_marker_selection(_marker_entry if valid else -1)
	_fields.visible = valid
	_empty.visible = not valid
	_key_mode.disabled = true
	_move_axis.disabled = true
	_blend.editable = false
	if not valid:
		return
	var marker := _tracks.markers[_marker_entry]
	_selection_type.text = "Clip Marker"
	_name_row.show()
	_time_row.show()
	_end_row.hide()
	_value_row.hide()
	_interpolation_row.hide()
	_weighted_row.hide()
	_color_row.show()
	_time_label.text = "Time"
	_item_name.text = marker.name
	_item_time.min_value = 0.0
	_item_time.max_value = _duration
	_item_time.set_value_no_signal(marker.time)
	_set_picker_color(marker.get("color", _default_color(true)))


func _open_marker_menu(entry: int, time: float) -> void:
	_menu.clear()
	_menu_time = time
	_menu.add_item("Add Marker", ADD_CLIP_MARKER)
	if entry >= 0:
		_menu.add_item("Rename Marker", RENAME_CLIP_MARKER)
		_menu.add_item("Remove Marker", REMOVE_CLIP_MARKER)
	_show_menu()


func _open_menu(is_curve: bool, track: int, entry: int, time: float, value: float, on_header: bool) -> void:
	_menu.clear()
	if is_curve:
		_menu.add_item("Add Curve Key", ADD_CURVE_KEY)
		_menu.add_item("Frame Curve", FRAME_CURVE)
		_menu.add_item("Collapse Curve" if _canvas.is_curve_expanded(track) else "Expand Curve", TOGGLE_CURVE_VIEW)
		_menu.add_item("Save Curve as Preset", SAVE_CURVE_PRESET)
		if not _curve_keys().is_empty():
			_append_key_actions()
	else:
		_menu.add_item("Add Notify", ADD_NOTIFY)
		_menu.add_item("Add Notify State", ADD_STATE)
		_menu.add_item("Add MeleeTrace State", ADD_MELEE_TRACE)
	if entry < 0:
		_menu.add_separator()
		_menu.add_item("Rename Track", RENAME_TRACK)
		_menu.add_item("Remove Track", REMOVE_TRACK)
	_menu_time = time
	_menu_value = value
	if is_curve and on_header:
		var curve := _tracks.curve_at(track)
		_menu_value = curve.sample(time / _duration)
	_show_menu()


func _show_menu() -> void:
	_menu.reset_size()
	_menu.popup_on_parent(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _append_key_actions() -> void:
	_menu.add_separator("Key Interpolation")
	var toolbar_menu := _key_mode.get_popup()
	for mode in MODE_LABELS.size():
		var index := _menu.item_count
		_menu.add_radio_check_item(MODE_LABELS[mode], KEY_MODE_MENU_START + mode)
		_menu.set_item_checked(index, toolbar_menu.is_item_checked(mode))
	var index := _menu.item_count
	_menu.add_check_item("Weighted Tangents", TOGGLE_WEIGHTED)
	_menu.set_item_checked(index, _weighted.button_pressed)
	_menu.set_item_disabled(index, _weighted.disabled)


func _on_menu_action(id: int) -> void:
	if id >= PRESET_MENU_START:
		_add_preset(id)
		return
	if id >= KEY_MODE_MENU_START and id < KEY_MODE_MENU_START + MODE_LABELS.size():
		_set_key_mode(id - KEY_MODE_MENU_START)
		return
	match id:
		ADD_NOTIFY_TRACK:
			edit_requested.emit(&"add_notify_track", {"name": _new_track_name(false)})
		ADD_CURVE_TRACK:
			edit_requested.emit(&"add_curve_track", {"name": _new_track_name(true)})
		ADD_NOTIFY:
			edit_requested.emit(&"add_notify", {"track": _track, "name": "Notify",
				"time": _menu_time, "end_time": ClipTracks.ONE_SHOT})
		ADD_STATE, ADD_MELEE_TRACE:
			var length := _duration * 0.10
			var start := minf(_menu_time, _duration - length)
			var melee := id == ADD_MELEE_TRACE
			edit_requested.emit(&"add_notify", {"track": _track,
				"name": "MeleeTrace" if melee else "Notify State",
				"kind": ClipTracks.MELEE_TRACE if melee else ClipTracks.GENERIC_NOTIFY,
				"time": start, "end_time": start + length})
		ADD_CURVE_KEY:
			_canvas.set_curve_expanded(_track, true)
			edit_requested.emit(&"add_curve_key", {"track": _track,
				"phase": _menu_time / _duration, "value": _menu_value})
		FRAME_CURVE:
			_canvas.frame_curve(_track)
		TOGGLE_CURVE_VIEW:
			_canvas.set_curve_expanded(_track, not _canvas.is_curve_expanded(_track))
		TOGGLE_WEIGHTED:
			_commit_weighted(not _weighted.button_pressed)
		ADD_CLIP_MARKER:
			_add_marker(_menu_time)
		RENAME_CLIP_MARKER:
			_focus_marker_name()
		REMOVE_CLIP_MARKER:
			_remove_marker(_marker_entry)
		SAVE_CURVE_PRESET:
			_save_curve_preset()
		REMOVE_TRACK:
			edit_requested.emit(&"remove_track", {"is_curve": _is_curve, "track": _track})
			return
		RENAME_TRACK:
			select_track(_is_curve, _track)
			_item_name.grab_focus()
			_item_name.select_all()


func _new_track_name(is_curve: bool) -> String:
	var rows := _tracks.curve_tracks if is_curve else _tracks.notify_tracks
	var names: Array[String] = []
	for row in rows:
		names.append(String(row.name).to_lower())
	var base := "Curve" if is_curve else "Notifies"
	var name := base
	var index := 2
	while name.to_lower() in names:
		name = "%s %d" % [base, index]
		index += 1
	return name


func _commit_name() -> void:
	if _filling_details or not _fields.is_visible_in_tree():
		return
	if _has_marker():
		var name := _item_name.text.strip_edges()
		if name != _tracks.markers[_marker_entry].name:
			if _tracks.marker_index(StringName(name)) >= 0:
				status_requested.emit("A marker with that name already exists.")
			else:
				_edit_marker({"name": name})
			_fill_selection()
		return
	if _track < 0:
		return
	if _entry < 0 or _is_curve:
		var rows := _tracks.curve_tracks if _is_curve else _tracks.notify_tracks
		if _item_name.text.strip_edges() == rows[_track].name:
			return
		edit_requested.emit(&"rename_track", {"is_curve": _is_curve, "track": _track,
			"name": _item_name.text})
	else:
		_edit_notify({"name": _item_name.text})
	_fill_selection()


func _commit_time(time: float) -> void:
	if _filling_details:
		return
	if _has_marker():
		_edit_marker({"time": time})
		return
	if _entry < 0:
		return
	if _is_curve:
		_commit_curve_key(time / _duration, _tracks.curve_at(_track).get_key_value(_entry))
	else:
		_edit_notify({"time": time})


func _commit_end(time: float) -> void:
	if not _filling_details and _entry >= 0 and not _is_curve:
		_edit_notify({"end_time": time})


func _commit_value(value: float) -> void:
	if not _filling_details and _is_curve and _entry >= 0:
		var curve := _tracks.curve_at(_track)
		_commit_curve_key(curve.get_key_phase(_entry), value)


func _commit_curve_key(phase: float, value: float) -> void:
	edit_requested.emit(&"set_curve_key", {"track": _track, "key": _entry,
		"phase": phase, "value": value})
	_fill_selection()


func _commit_interpolation(index: int) -> void:
	_set_key_mode(_interpolation.get_item_id(index))


func _curve_keys() -> PackedInt32Array:
	if not _is_curve or _track < 0:
		return PackedInt32Array()
	return _canvas.selected_curve_keys()


func _fill_key_modes(curve: RichCurve, keys: PackedInt32Array) -> void:
	if keys.is_empty():
		return
	var mode: int = curve.key_info(keys[0]).mode
	var weighted := true
	var has_tangent := false
	for key in keys:
		var info := curve.key_info(key)
		if info.mode != mode:
			mode = MODE_MIXED
		if curve.has_handle(key, true):
			has_tangent = true
			weighted = weighted and info.weighted_in
		if curve.has_handle(key, false):
			has_tangent = true
			weighted = weighted and info.weighted_out
	_interpolation.select(_interpolation.get_item_index(mode))
	_weighted.disabled = not has_tangent
	_weighted.set_pressed_no_signal(has_tangent and weighted)
	var menu := _key_mode.get_popup()
	for index in MODE_LABELS.size():
		menu.set_item_checked(index, mode == index)


func _set_key_mode(mode: int) -> void:
	var keys := _curve_keys()
	if not _filling_details and not keys.is_empty() and mode >= 0 and mode < MODE_LABELS.size():
		edit_requested.emit(&"set_curve_key_mode", {"track": _track, "keys": keys, "mode": mode})


func _commit_weighted(weighted: bool) -> void:
	var keys := _curve_keys()
	if not _filling_details and not keys.is_empty():
		edit_requested.emit(&"set_curve_key_weighted", {
			"track": _track, "keys": keys, "weighted": weighted})


func _on_move_axis_selected(index: int) -> void:
	_canvas.set_curve_move_lock(_move_axis.get_item_id(index))


func _begin_neighbor_blend() -> void:
	_blend_keys = _curve_keys()
	if _blend_keys.is_empty():
		return
	_blend_track = _track
	_blend_source = _tracks.curve_at(_track)


func _update_neighbor_blend(amount: float) -> void:
	_blend_readout.text = "%.2f" % amount
	if _blend_source == null:
		if not is_zero_approx(amount):
			var keys := _curve_keys()
			_reset_neighbor_blend()
			_commit_neighbor_blend(_track, keys, amount)
		return
	var preview := _blend_source.duplicate(true) as RichCurve
	if preview.blend_neighbor(_blend_keys, amount):
		_canvas.set_blend_preview(_blend_track, preview)
	else:
		_canvas.set_blend_preview(-1, null)


func _end_neighbor_blend(changed: bool) -> void:
	var track := _blend_track
	var keys := _blend_keys
	var amount := _blend.value
	_reset_neighbor_blend()
	if changed:
		_commit_neighbor_blend(track, keys, amount)


func _commit_neighbor_blend(track: int, keys: PackedInt32Array, amount: float) -> void:
	if track >= 0 and not keys.is_empty() and not is_zero_approx(amount):
		edit_requested.emit(&"blend_curve_neighbor", {"track": track, "keys": keys, "amount": amount})


func _reset_neighbor_blend() -> void:
	_blend_source = null
	_blend_track = -1
	_blend_keys = PackedInt32Array()
	_blend.set_value_no_signal(0.0)
	_blend_readout.text = "0.00"
	_canvas.set_blend_preview(-1, null)


func _fill_add_menu() -> void:
	var menu := _add.get_popup()
	menu.clear()
	menu.add_item("Notify Track", ADD_NOTIFY_TRACK)
	menu.add_item("Float Curve", ADD_CURVE_TRACK)
	_presets = CurvePresets.load_library()
	if _presets == null:
		return
	var names := _presets.names()
	if names.is_empty():
		return
	menu.add_separator("Curve Presets")
	for index in names.size():
		var preset_name := names[index]
		menu.add_item(preset_name, PRESET_MENU_START + index)
		var item := menu.item_count - 1
		menu.set_item_metadata(item, preset_name)
		menu.set_item_disabled(item, _has_curve_named(preset_name))


func _has_curve_named(curve_name: String) -> bool:
	if _tracks != null:
		for row in _tracks.curve_tracks:
			if row.name == curve_name:
				return true
	return false


func _add_preset(id: int) -> void:
	var menu := _add.get_popup()
	var index := menu.get_item_index(id)
	if index < 0 or menu.is_item_disabled(index):
		return
	var row := _presets.get_preset(menu.get_item_metadata(index))
	if not row.is_empty():
		edit_requested.emit(&"add_curve_preset", {"row": row})


func _save_curve_preset() -> void:
	if not _is_curve or _track < 0:
		return
	var row := _tracks.curve_tracks[_track]
	var presets := CurvePresets.load_library()
	if presets == null:
		status_requested.emit("Could not load the curve preset library.")
		return
	var error := presets.save_preset(row)
	match error:
		OK:
			status_requested.emit('Saved curve preset "%s".' % row.name)
		ERR_ALREADY_EXISTS:
			status_requested.emit('A preset named "%s" already exists. Rename this curve to save another.' % row.name)
		_:
			status_requested.emit("Could not save the curve preset. %s" % error_string(error))


func _edit_notify(args: Dictionary) -> void:
	args.track = _track
	args.entry = _entry
	edit_requested.emit(&"set_notify", args)


func _add_marker(time: float) -> void:
	if _tracks == null:
		return
	var name := "Marker"
	var suffix := 2
	while _tracks.marker_index(StringName(name)) >= 0:
		name = "Marker %d" % suffix
		suffix += 1
	edit_requested.emit(&"add_marker", {"name": name, "time": time})
	_focus_marker_name()


func _focus_marker_name() -> void:
	if _has_marker():
		_item_name.grab_focus()
		_item_name.select_all()


func _edit_marker(args: Dictionary) -> void:
	args.entry = _marker_entry
	edit_requested.emit(&"set_marker", args)


func _remove_marker(entry: int) -> void:
	if entry >= 0:
		edit_requested.emit(&"remove_marker", {"entry": entry})


func _default_color(is_curve: bool) -> Color:
	return get_theme_color(&"playhead" if is_curve else &"key", &"WeaponTimeline")


func _set_picker_color(color: Color) -> void:
	if not _color_editing:
		_item_color.color = color


func _begin_color_edit() -> void:
	_color_origin = _item_color.color
	_color_editing = true


func _preview_color(color: Color) -> void:
	if _color_editing and _fields.visible and _color_row.visible and not _marker_selected:
		_canvas.set_color_preview(_is_curve, _track, _entry, color)


func _commit_color() -> void:
	_canvas.clear_color_preview()
	var color := _item_color.color
	var changed := _color_editing and color != _color_origin
	_color_editing = false
	if not changed or not _fields.visible or not _color_row.visible:
		return
	if _has_marker():
		_edit_marker({"color": color})
	elif _is_curve:
		edit_requested.emit(&"set_curve_color", {"track": _track, "color": color})
	else:
		_edit_notify({"color": color})


func _remove_selected() -> void:
	if _track < 0:
		return
	var keys := _curve_keys()
	if not keys.is_empty():
		edit_requested.emit(&"remove_curve_keys", {"track": _track, "keys": keys})
	elif _entry < 0:
		edit_requested.emit(&"remove_track", {"is_curve": _is_curve, "track": _track})
	elif not _is_curve:
		edit_requested.emit(&"remove_notify", {"track": _track, "entry": _entry})
