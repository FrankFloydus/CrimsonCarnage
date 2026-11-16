@tool
extends Control
## Draws editable notify and curve rows against the Tweaker's shared time ruler.

signal selection_requested(is_curve: bool, track: int, entry: int)
signal curve_selection_changed
signal menu_requested(is_curve: bool, track: int, entry: int, time: float,
		value: float, on_header: bool)
signal marker_selection_requested(entry: int)
signal marker_menu_requested(entry: int, time: float)
signal marker_remove_requested(entry: int)
signal edit_requested(operation: StringName, args: Dictionary)
signal remove_requested
signal seek_requested(time: float)

const Timeline := preload("timeline.gd")
const ClipTracks := preload("clip_tracks.gd")
const RichCurve := preload("rich_float_curve.gd")
const HEADER_WIDTH := 180.0
const AXIS_WIDTH := 56.0
const ROW_HEIGHT := 30.0
const MIN_CURVE_HEIGHT := 136.0
const DISCLOSURE_WIDTH := 25.0
const CURVE_COLOR_BAND_WIDTH := 4.0
const CURVE_PAD := 12.0
const HIT_RADIUS := 8.0
const MIN_STATE_DURATION := 0.00001
const TANGENT_RADIUS := 4.0
const TANGENT_DISPLAY_LENGTH := 42.0
const SELECTED_KEY_COLOR := Color("#ffe4a0")

## Curve movement axes, matching the timeline toolbar selector.
enum MoveLock {
	## Move in time and value together.
	BOTH,
	## Move left and right without changing values.
	TIME,
	## Move up and down without changing times.
	VALUE,
}

var _ruler: Timeline
var _tracks: ClipTracks
var _duration := 0.0
var _playhead := 0.0
var _selected_curve := false
var _selected_track := -1
var _selected_entry := -1
var _selected_marker := -1
var _curve_selection := PackedInt32Array()
var _curves: Array[RichCurve] = []
var _expanded_curves: Dictionary[String, bool] = {}
var _expanded_row_height := ROW_HEIGHT + MIN_CURVE_HEIGHT
var _laid_out_height := 0.0
var _curve_move_lock: int = MoveLock.BOTH
var _marquee: Dictionary = {}
var _viewport_height := 0.0
var _curve_plots: Dictionary = {}
var _value_ranges: Dictionary[String, Vector2] = {}
var _color_preview_target := Vector3i(-1, -1, -1)
var _color_preview: Color
var _drag: Dictionary = {}
var _drag_curve: RichCurve
var _drag_curve_keys := PackedInt32Array()
var _blend_track := -1
var _blend_curve: RichCurve
var _panning := false
var _pan_curve := -1


## Attach the same ruler that controls clip playback.
func bind_ruler(ruler: Timeline) -> void:
	if _ruler == ruler:
		return
	if is_instance_valid(_ruler):
		_ruler.view_changed.disconnect(_invalidate_plot)
		_ruler.resized.disconnect(_invalidate_plot)
	_ruler = ruler
	_ruler.view_changed.connect(_invalidate_plot)
	_ruler.resized.connect(_invalidate_plot)


## Replace the displayed model and invalidate projected key positions.
func set_clip(tracks: ClipTracks, duration: float) -> void:
	_update_expanded_curves(tracks)
	_tracks = tracks
	_duration = duration
	_cancel_pointer()
	_blend_track = -1
	_blend_curve = null
	_curves.clear()
	if tracks != null:
		for track in tracks.curve_tracks.size():
			_curves.append(tracks.curve_at(track))
	if tracks == null:
		_value_ranges.clear()
	if tracks == null or _selected_marker >= tracks.markers.size():
		_selected_marker = -1
	if not _curve_selection.is_empty():
		var retained := PackedInt32Array()
		if _selected_track >= 0 and _selected_track < _curves.size():
			for key in _curve_selection:
				if key < _curves[_selected_track].point_count:
					retained.append(key)
		_curve_selection = retained
	_update_row_layout()
	_invalidate_plot()


## Expand curve rows into the resized timeline viewport.
func set_viewport_height(height: float) -> void:
	if is_equal_approx(_viewport_height, height):
		return
	_viewport_height = height
	_update_row_layout()
	_invalidate_plot()


## Height in pixels before the track panel applies its vertical clipping.
func row_height() -> float:
	return _laid_out_height


## Whether a curve shows its editing graph inside the timeline.
func is_curve_expanded(track: int) -> bool:
	return _tracks != null and track >= 0 and track < _tracks.curve_tracks.size() \
			and _expanded_curves.has(_tracks.curve_tracks[track].name)


## Toggle the full editing graph while keeping other lanes in place.
func set_curve_expanded(track: int, expanded: bool) -> void:
	if _tracks == null or track < 0 or track >= _tracks.curve_tracks.size() \
			or is_curve_expanded(track) == expanded:
		return
	var curve_name: String = _tracks.curve_tracks[track].name
	if expanded:
		_expanded_curves[curve_name] = true
	else:
		_expanded_curves.erase(curve_name)
	_cancel_pointer()
	_update_row_layout()
	_invalidate_plot()


## Display a temporary Blend Neighbor result without modifying the authored keys.
func set_blend_preview(track: int, curve: RichCurve) -> void:
	_curve_plots.erase(_blend_track)
	_blend_track = track if curve != null else -1
	_blend_curve = curve
	_curve_plots.erase(_blend_track)
	queue_redraw()


## Fit the selected curve on both axes.
func frame_curve(track: int) -> void:
	if not is_instance_valid(_ruler) or _tracks == null or track < 0 or track >= _tracks.curve_tracks.size():
		return
	set_curve_expanded(track, true)
	var lane := _tracks.curve_tracks[track]
	var curve := _curves[track]
	_value_ranges.erase(lane.name)
	if curve.point_count == 0:
		_ruler.fit()
	else:
		var first := curve.get_key_phase(0) * _duration
		var last := curve.get_key_phase(curve.point_count - 1) * _duration
		var singleton_pad := _duration * 0.05 if curve.point_count == 1 else 0.0
		_ruler.frame_times(first - singleton_pad, last + singleton_pad)
	_invalidate_plot()


## Restore the value fit for every curve without changing the shared playhead.
func fit_value_axes() -> void:
	_value_ranges.clear()
	_invalidate_plot()


## Preview a color picker gesture until its single undoable edit is committed.
func set_color_preview(is_curve: bool, track: int, entry: int, color: Color) -> void:
	_color_preview_target = Vector3i(track, -1 if is_curve else entry, int(is_curve))
	_color_preview = color
	queue_redraw()


## Remove the transient color override.
func clear_color_preview() -> void:
	if _color_preview_target.x >= 0:
		_color_preview_target = Vector3i(-1, -1, -1)
		queue_redraw()


## Highlight the selected row or one entry in that row.
func set_selection(is_curve: bool, track: int, entry: int) -> void:
	var previous := _curve_selection
	_selected_marker = -1
	if not is_curve or entry < 0:
		_curve_selection = PackedInt32Array()
	elif track != _selected_track or entry not in _curve_selection:
		_curve_selection = PackedInt32Array([entry])
	var changed := previous != _curve_selection or (_selected_curve and track != _selected_track)
	_selected_curve = is_curve
	_selected_track = track
	_selected_entry = entry
	if changed:
		curve_selection_changed.emit()
	queue_redraw()


## Highlight a Tweaker marker by its authoring index. A negative index clears the highlight.
func set_marker_selection(entry: int) -> void:
	_selected_marker = entry
	if entry >= 0:
		_selected_curve = false
		_selected_track = -1
		_selected_entry = -1
		_curve_selection.clear()
	queue_redraw()


## Read the selected key indexes on the active float curve.
func selected_curve_keys() -> PackedInt32Array:
	return _curve_selection.duplicate()


## Restrict key dragging to the time axis, the value axis, or both.
func set_curve_move_lock(axis: int) -> void:
	_curve_move_lock = clampi(axis, MoveLock.BOTH, MoveLock.VALUE)


func _set_graph_selection(track: int, keys: PackedInt32Array, entry: int) -> void:
	var changed := track != _selected_track or keys != _curve_selection or entry != _selected_entry
	_selected_marker = -1
	_selected_curve = true
	_selected_track = track
	_curve_selection = keys
	_selected_entry = entry
	if changed:
		selection_requested.emit(true, track, entry)
		curve_selection_changed.emit()
	queue_redraw()


## Update playback shading and cursor without recomputing curve geometry.
func set_playhead(time: float) -> void:
	if _playhead == time:
		return
	_playhead = time
	queue_redraw()


func _invalidate_plot() -> void:
	_curve_plots.clear()
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		_invalidate_plot()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		_cancel_pointer()
	elif what == NOTIFICATION_MOUSE_EXIT and _drag.is_empty() and not _panning:
		mouse_default_cursor_shape = CURSOR_ARROW


func _cancel_pointer() -> void:
	_drag = {}
	_drag_curve = null
	_drag_curve_keys.clear()
	_marquee = {}
	_panning = false
	_pan_curve = -1
	mouse_default_cursor_shape = CURSOR_ARROW


func _update_expanded_curves(tracks: ClipTracks) -> void:
	if tracks == null:
		_expanded_curves.clear()
		return
	var retained: Dictionary[String, bool] = {}
	for row in tracks.curve_tracks:
		if _expanded_curves.has(row.name):
			retained[row.name] = true
	# Keep the selected graph open when its curve is renamed.
	if _tracks != null and _selected_curve and _selected_track >= 0 \
			and _selected_track < tracks.curve_tracks.size() \
			and tracks.curve_tracks.size() == _tracks.curve_tracks.size():
		var previous_name: String = _tracks.curve_tracks[_selected_track].name
		if _expanded_curves.has(previous_name) and not retained.has(previous_name):
			retained[tracks.curve_tracks[_selected_track].name] = true
	_expanded_curves = retained


func _update_row_layout() -> void:
	_laid_out_height = 0.0
	if _tracks != null:
		var lanes := _tracks.notify_tracks.size() + _tracks.curve_tracks.size() + int(_marker_lane_height() > 0.0)
		var open := _expanded_curves.size()
		var available := _viewport_height - (lanes - open) * ROW_HEIGHT
		_expanded_row_height = maxf(ROW_HEIGHT + MIN_CURVE_HEIGHT, floorf(available / maxi(1, open)))
		_laid_out_height = (lanes - open) * ROW_HEIGHT + open * _expanded_row_height
	custom_minimum_size.y = _laid_out_height


func _curve_height(track: int) -> float:
	return _expanded_row_height if is_curve_expanded(track) else ROW_HEIGHT


func _marker_lane_height() -> float:
	return ROW_HEIGHT if _tracks != null and not _tracks.markers.is_empty() else 0.0


func _draw() -> void:
	if _tracks == null or not is_instance_valid(_ruler) or _duration <= 0.0:
		return
	var visible_times := _ruler.visible_time_range()
	var y := _marker_lane_height()
	if y > 0.0:
		_draw_row("Markers", 0.0, false, -1)
		_draw_markers()
	for track in _tracks.notify_tracks.size():
		_draw_row(_tracks.notify_tracks[track].name, y, false, track)
		_draw_notifies(track, y, visible_times)
		y += ROW_HEIGHT
	for track in _tracks.curve_tracks.size():
		var lane := _tracks.curve_tracks[track]
		var plot_color := _item_color(true, track, -1, lane.get("color", _color(&"playhead")))
		var height := _curve_height(track)
		_draw_row(lane.name, y, true, track)
		draw_rect(Rect2(HEADER_WIDTH, y + 1.0, CURVE_COLOR_BAND_WIDTH, ROW_HEIGHT - 2.0), plot_color)
		if is_curve_expanded(track):
			_draw_curve(track, y, height, visible_times, plot_color)
		else:
			_draw_compact_curve(track, y, visible_times, plot_color)
		y += height
	if _is_visible_time(_playhead):
		var x := roundf(_ruler.x_at_time(_playhead)) + 0.5
		draw_line(Vector2(x, 0.0), Vector2(x, y), _color(&"playhead"))
	if _marquee.get("active", false):
		var bounds := _marquee_rect()
		draw_rect(bounds, Color(_color(&"playhead"), 0.18))
		draw_rect(bounds, _color(&"playhead"), false)


func _draw_row(name: String, y: float, is_curve: bool, track: int) -> void:
	var header := _color(&"track")
	var selected := _selected_marker >= 0 if track < 0 else is_curve == _selected_curve and track == _selected_track
	var text := _color(&"key" if selected else &"text")
	if selected:
		header = header.lerp(_color(&"playhead"), 0.18)
	draw_rect(Rect2(0.0, y, size.x, ROW_HEIGHT), Color(header, 0.36))
	draw_rect(Rect2(0.0, y, HEADER_WIDTH, ROW_HEIGHT), header)
	var name_x := 9.0
	var menu_x := HEADER_WIDTH - 22.0
	if is_curve:
		_draw_disclosure(Vector2(DISCLOSURE_WIDTH * 0.5, y + ROW_HEIGHT * 0.5),
				is_curve_expanded(track), text)
		name_x = DISCLOSURE_WIDTH + 4.0
	draw_line(Vector2(0.0, y + ROW_HEIGHT - 0.5), Vector2(size.x, y + ROW_HEIGHT - 0.5), _color(&"tick_minor"))
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	draw_string(font, Vector2(name_x, y + font.get_ascent(font_size) + 5.0), name,
			HORIZONTAL_ALIGNMENT_LEFT, menu_x - name_x - 5.0, font_size, text)
	draw_string(font, Vector2(menu_x, y + font.get_ascent(font_size) + 5.0),
			"⋯", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text)


func _draw_markers() -> void:
	var labels: Array[Dictionary] = []
	for entry in _tracks.markers.size():
		var marker := _tracks.markers[entry]
		var time: float = marker.time
		if _drag.get("is_marker", false) and entry == _drag.entry:
			time = _drag.time
		if not _is_visible_time(time):
			continue
		var x := _ruler.x_at_time(time)
		var selected := entry == _selected_marker
		var color: Color = marker.get("color", _color(&"playhead"))
		if selected:
			draw_circle(Vector2(x, 13.0), 8.0, Color(SELECTED_KEY_COLOR, 0.28))
		draw_colored_polygon(PackedVector2Array([
			Vector2(x - 5.0, 7.0), Vector2(x + 5.0, 7.0),
			Vector2(x + 5.0, 15.0), Vector2(x, 20.0), Vector2(x - 5.0, 15.0),
		]), color)
		draw_line(Vector2(x, 20.0), Vector2(x, 26.0), color)
		var label := {"text": marker.name, "start": x + 9.0, "end": size.x - 8.0}
		if selected:
			labels.push_front(label)
		else:
			labels.append(label)
	_draw_item_labels(labels, 0.0)


func _is_visible_time(time: float) -> bool:
	# Use the ruler's double-precision mapping so clip endpoints stay visible.
	var left := _ruler.time_at_x(0.0)
	var right := _ruler.time_at_x(_ruler.size.x)
	return time >= minf(left, right) and time <= maxf(left, right)


func _draw_disclosure(center: Vector2, expanded: bool, color: Color) -> void:
	var points := PackedVector2Array([Vector2(-2.0, -4.0), Vector2(2.0, 0.0), Vector2(-2.0, 4.0)])
	for index in points.size():
		points[index] = center + (points[index].rotated(PI * 0.5) if expanded else points[index])
	draw_polyline(points, color, 1.25, true)


func _draw_compact_curve(track: int, y: float, times: Vector2, color: Color) -> void:
	draw_rect(Rect2(HEADER_WIDTH + CURVE_COLOR_BAND_WIDTH, y + 1.0,
			maxf(0.0, size.x - HEADER_WIDTH - CURVE_COLOR_BAND_WIDTH), ROW_HEIGHT - 2.0),
			Color(color, color.a * 0.16))
	var curve := _display_curve(track)
	if curve.point_count == 0:
		return
	var vertical := Vector2(y + 5.0, y + ROW_HEIGHT - 5.0)
	var plot := _curve_points(track, curve, times, vertical, _curve_limits(track, true))
	if plot.size() >= 2:
		draw_multiline(plot, color, 1.3, true)


func _display_curve(track: int) -> RichCurve:
	if _drag_curve != null and int(_drag.track) == track:
		return _drag_curve
	if _blend_curve != null and _blend_track == track:
		return _blend_curve
	return _curves[track]


func _draw_notifies(track: int, y: float, visible_times: Vector2) -> void:
	var entries: Array = _tracks.notify_tracks[track].notifies
	var labels: Array[Dictionary] = []
	for entry in entries.size():
		var notify: Dictionary = entries[entry]
		var time := float(notify.time)
		var end_time := float(notify.end_time)
		if _drag_matches(false, track, entry):
			time = _drag.time
			end_time = _drag.end_time
		var selected := not _selected_curve and track == _selected_track and entry == _selected_entry
		var active := end_time >= 0.0 and _playhead >= time and _playhead < end_time
		var color := _item_color(false, track, entry, notify.get("color", _color(&"key")))
		var selection := _color(&"key")
		var label_start: float
		var label_end: float
		if end_time < 0.0:
			if time < visible_times.x or time > visible_times.y:
				continue
			var x := _ruler.x_at_time(time)
			if selected:
				_draw_diamond(Vector2(x, y + ROW_HEIGHT * 0.5), selection, 7.0)
			_draw_diamond(Vector2(x, y + ROW_HEIGHT * 0.5), color, 5.0)
			label_start = x + 9.0
			label_end = size.x - 8.0
		elif time <= visible_times.y and end_time >= visible_times.x:
			var start_x := _ruler.x_at_time(clampf(time, visible_times.x, visible_times.y))
			var end_x := _ruler.x_at_time(clampf(end_time, visible_times.x, visible_times.y))
			var left := minf(start_x, end_x)
			var right := maxf(start_x, end_x)
			var body := Rect2(left, y + 5.0, maxf(right - left, 1.0), ROW_HEIGHT - 10.0)
			if selected:
				draw_rect(body.grow(2.0), Color(selection, 0.75), false, 1.0)
			draw_rect(body, Color(color, color.a * (0.42 if active else 0.24)))
			draw_rect(body, color, false, 1.0)
			if time >= visible_times.x:
				draw_rect(Rect2(start_x - 2.0, body.position.y, 4.0, body.size.y), color)
			if end_time <= visible_times.y:
				draw_rect(Rect2(end_x - 2.0, body.position.y, 4.0, body.size.y), color)
			label_start = left + 6.0
			label_end = right - 5.0
		else:
			continue
		var label := {"text": notify.name, "start": label_start, "end": label_end}
		if selected:
			labels.push_front(label)
		else:
			labels.append(label)
	_draw_item_labels(labels, y)


func _draw_curve(track: int, y: float, height: float, visible_times: Vector2, color: Color) -> void:
	var edited := _drag_curve != null and int(_drag.track) == track
	var plotted := _display_curve(track)
	var limits := _curve_limits(track)
	var vertical := Vector2(y + ROW_HEIGHT + CURVE_PAD, y + height - CURVE_PAD)
	draw_rect(Rect2(0.0, y + ROW_HEIGHT, size.x, height - ROW_HEIGHT), Color(_color(&"track"), 0.36))
	_draw_curve_axes(visible_times, vertical, limits)
	if plotted.point_count == 0:
		return
	var plot := _curve_points(track, plotted, visible_times, vertical, limits)
	if plot.size() >= 2:
		draw_multiline(plot, color, 1.6, true)
	var has_marquee: bool = _marquee.get("active", false) and _marquee.track == track
	var selected_keys: PackedInt32Array
	if has_marquee:
		selected_keys = _marquee.keys
	elif edited and not _drag.has("incoming"):
		selected_keys = _drag_curve_keys
	elif _selected_curve and track == _selected_track:
		selected_keys = _curve_selection
	if not has_marquee:
		for key in selected_keys:
			_draw_tangents(plotted, key, vertical, limits, visible_times)
	for key in plotted.point_count:
		var point := plotted.get_point_position(key)
		var time := plotted.get_key_phase(key) * _duration
		if time >= visible_times.x and time <= visible_times.y and point.y >= limits.x and point.y <= limits.y:
			var selected := key in selected_keys
			var position := _key_position(point, vertical, limits)
			var mode := plotted.get_key_mode(key)
			if selected:
				_draw_curve_key(position, Color("#1a1714"), mode, 9.0)
			_draw_curve_key(position, SELECTED_KEY_COLOR if selected else color, mode, 6.0 if selected else 4.5)
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var value := plotted.sample(clampf(_playhead / _duration, 0.0, 1.0))
	draw_string(font, Vector2(9.0, vertical.x + font.get_ascent(font_size)),
			_ordinate_label(value, 0.001), HORIZONTAL_ALIGNMENT_LEFT,
			HEADER_WIDTH - AXIS_WIDTH - 18.0, font_size, _color(&"text"))


func _draw_curve_key(at: Vector2, color: Color, mode: int, radius: float) -> void:
	match mode:
		RichCurve.Mode.CONSTANT:
			draw_rect(Rect2(at - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), color)
		RichCurve.Mode.AUTO:
			draw_circle(at, radius, color, true, -1.0, true)
		RichCurve.Mode.BREAK:
			draw_colored_polygon(PackedVector2Array([
				at + Vector2(0.0, -radius), at + Vector2(radius, radius * 0.8),
				at + Vector2(-radius, radius * 0.8),
			]), color)
		_:
			_draw_diamond(at, color, radius)


func _draw_tangents(curve: RichCurve, key: int, vertical: Vector2, limits: Vector2, times: Vector2) -> void:
	var point := curve.get_point_position(key)
	var origin := _key_position(point, vertical, limits)
	var bounds := _plot_rect(vertical, times)
	for incoming: bool in [true, false]:
		if not curve.has_handle(key, incoming):
			continue
		var handle := _tangent_position(curve, key, incoming, vertical, limits)
		_clip_tangent_line(origin, handle, bounds)
		if bounds.has_point(handle):
			var info := curve.key_info(key)
			var weighted: bool = info.weighted_in if incoming else info.weighted_out
			draw_circle(handle, TANGENT_RADIUS, SELECTED_KEY_COLOR, weighted, -1.0 if weighted else 1.25, true)


func _clip_tangent_line(origin: Vector2, handle: Vector2, bounds: Rect2) -> void:
	var delta := handle - origin
	var near := 0.0
	var far := 1.0
	for axis in 2:
		if is_zero_approx(delta[axis]):
			if origin[axis] < bounds.position[axis] or origin[axis] > bounds.end[axis]:
				return
			continue
		var first := (bounds.position[axis] - origin[axis]) / delta[axis]
		var last := (bounds.end[axis] - origin[axis]) / delta[axis]
		near = maxf(near, minf(first, last))
		far = minf(far, maxf(first, last))
	if near <= far:
		draw_line(origin + delta * near, origin + delta * far, Color(SELECTED_KEY_COLOR, 0.72), 1.25, true)


func _key_position(point: Vector2, vertical: Vector2, limits: Vector2) -> Vector2:
	return Vector2(_ruler.x_at_time(point.x * _duration), _curve_y(point.y, vertical, limits))


func _tangent_position(curve: RichCurve, key: int, incoming: bool, vertical: Vector2, limits: Vector2) -> Vector2:
	var point := curve.get_point_position(key)
	var origin := _key_position(point, vertical, limits)
	var position := _key_position(point + curve.get_handle_offset(key, incoming), vertical, limits)
	var meta := curve.key_info(key)
	var weighted: bool = meta.weighted_in if incoming else meta.weighted_out
	if weighted:
		return position
	return origin + (position - origin).normalized() * TANGENT_DISPLAY_LENGTH


func _plot_rect(vertical: Vector2, times: Vector2) -> Rect2:
	var first := _ruler.x_at_time(times.x)
	var last := _ruler.x_at_time(times.y)
	return Rect2(minf(first, last), vertical.x, absf(last - first), vertical.y - vertical.x)


func _draw_curve_axes(times: Vector2, vertical: Vector2, limits: Vector2) -> void:
	var first_x := _ruler.x_at_time(times.x)
	var last_x := _ruler.x_at_time(times.y)
	var left := minf(first_x, last_x)
	var right := maxf(first_x, last_x)
	var grid := _color(&"tick_minor")
	var major := _color(&"tick_major")
	draw_rect(Rect2(left, vertical.x, right - left, vertical.y - vertical.x),
			Color(_color(&"track").darkened(0.48), 0.55))
	var time_step := _ruler.major_tick_step()
	for tick in range(ceili(times.x / time_step), floori(times.y / time_step) + 1):
		var x := _ruler.x_at_time(tick * time_step)
		draw_line(Vector2(x, vertical.x), Vector2(x, vertical.y), grid)
	var font := get_theme_default_font()
	var font_size := maxi(10, get_theme_default_font_size() - 1)
	var count := maxf(2.0, floorf((vertical.y - vertical.x) / (font.get_height(font_size) + 10.0)))
	var step := _value_tick_step((limits.y - limits.x) / count)
	for tick in range(ceili(limits.x / step), floori(limits.y / step) + 1):
		var value := tick * step
		var y := _curve_y(value, vertical, limits)
		draw_line(Vector2(left, y), Vector2(right, y), major if tick == 0 else grid)
		draw_string(font, Vector2(HEADER_WIDTH - AXIS_WIDTH + 3.0, y + font_size * 0.35),
				_ordinate_label(value, step), HORIZONTAL_ALIGNMENT_RIGHT, AXIS_WIDTH - 6.0,
				font_size, _color(&"text"))


func _value_tick_step(minimum: float) -> float:
	var decade := pow(10.0, floorf(log(minimum) / log(10.0)))
	var factor := minimum / decade
	return decade * (1.0 if factor <= 1.0 else 2.0 if factor <= 2.0 else 5.0 if factor <= 5.0 else 10.0)


func _ordinate_label(value: float, step: float) -> String:
	if absf(value) >= 10000.0 or (value != 0.0 and absf(value) < 0.0001):
		return "%.2e" % value
	return String.num(value, clampi(ceili(-log(step) / log(10.0)), 0, 6))


func _curve_points(track: int, curve: RichCurve, times: Vector2, vertical: Vector2,
		limits: Vector2) -> PackedVector2Array:
	if _curve_plots.has(track):
		return _curve_plots[track]
	var result := PackedVector2Array()
	for index in range(-1, curve.point_count):
		var start := 0.0 if index < 0 else curve.get_key_phase(index) * _duration
		var end := _duration if index + 1 == curve.point_count else curve.get_key_phase(index + 1) * _duration
		var first := maxf(start, times.x)
		var last := minf(end, times.y)
		if last < first:
			continue
		var mode := RichCurve.Mode.LINEAR if index < 0 or index + 1 == curve.point_count else curve.get_key_mode(index)
		var length := absf(_ruler.x_at_time(first) - _ruler.x_at_time(last))
		var segments := maxi(1, ceili(length / 5.0)) if mode >= RichCurve.Mode.AUTO else 1
		var first_value := curve.get_key_value(index) if mode == RichCurve.Mode.CONSTANT else curve.sample(first / _duration)
		var previous := Vector2(_ruler.x_at_time(first), _curve_y(first_value, vertical, limits))
		for sample_index in range(1, segments + 1):
			var time := lerpf(first, last, float(sample_index) / segments)
			var value := first_value if mode == RichCurve.Mode.CONSTANT else float(curve.sample(time / _duration))
			var point := Vector2(_ruler.x_at_time(time), _curve_y(value, vertical, limits))
			_clip_curve_line(result, previous, point, vertical)
			previous = point
		if mode == RichCurve.Mode.CONSTANT and last == end:
			var next := curve.get_point_position(index + 1)
			_clip_curve_line(result, previous, _key_position(next, vertical, limits), vertical)
	_curve_plots[track] = result
	return result


func _clip_curve_line(points: PackedVector2Array, start: Vector2, end: Vector2, vertical: Vector2) -> void:
	if maxf(start.y, end.y) < vertical.x or minf(start.y, end.y) > vertical.y:
		return
	var start_y := clampf(start.y, vertical.x, vertical.y)
	var end_y := clampf(end.y, vertical.x, vertical.y)
	points.append(start if start.y == start_y else start.lerp(end, inverse_lerp(start.y, end.y, start_y)))
	points.append(end if end.y == end_y else start.lerp(end, inverse_lerp(start.y, end.y, end_y)))


func _curve_limits(track: int, compact: bool = false) -> Vector2:
	var lane := _tracks.curve_tracks[track]
	if not compact and _value_ranges.has(lane.name):
		return _value_ranges[lane.name]
	var curve := _curves[track]
	if curve.point_count == 0:
		return Vector2(0.0, 1.0)
	var low := float(curve.get_point_position(0).y)
	var high := low
	for index in range(1, curve.point_count):
		var value := float(curve.get_point_position(index).y)
		low = minf(low, value)
		high = maxf(high, value)
	var margin := (high - low) * 0.12
	if low == high:
		margin = maxf(0.15, absf(low) * 0.12)
	return Vector2(low - margin, high + margin)


func _curve_y(value: float, vertical: Vector2, limits: Vector2) -> float:
	return lerpf(vertical.y, vertical.x, inverse_lerp(limits.x, limits.y, value))


func _curve_value(y: float, vertical: Vector2, limits: Vector2) -> float:
	return lerpf(limits.x, limits.y, clampf(inverse_lerp(vertical.y, vertical.x, y), 0.0, 1.0))


func _draw_diamond(at: Vector2, color: Color, radius: float) -> void:
	draw_colored_polygon(PackedVector2Array([
		at + Vector2(0.0, -radius), at + Vector2(radius, 0.0),
		at + Vector2(0.0, radius), at + Vector2(-radius, 0.0),
	]), color)


func _draw_item_labels(labels: Array[Dictionary], y: float) -> void:
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var baseline := y + (ROW_HEIGHT - font.get_height(font_size)) * 0.5 + font.get_ascent(font_size)
	var occupied: Array[Rect2] = []
	for label in labels:
		var room := float(label.end) - float(label.start)
		if room < 12.0:
			continue
		var width := minf(room, font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT,
				-1, font_size).x)
		var bounds := Rect2(label.start, y, width + 4.0, ROW_HEIGHT)
		var clear := true
		for used in occupied:
			if used.intersects(bounds):
				clear = false
				break
		if not clear:
			continue
		occupied.append(bounds)
		draw_string(font, Vector2(label.start, baseline), label.text, HORIZONTAL_ALIGNMENT_LEFT,
				room, font_size, _color(&"key"))


func _color(role: StringName) -> Color:
	return get_theme_color(role, &"WeaponTimeline")


func _item_color(is_curve: bool, track: int, entry: int, saved: Color) -> Color:
	return _color_preview if _color_preview_target == Vector3i(track, entry, int(is_curve)) else saved


func _gui_input(event: InputEvent) -> void:
	if _tracks == null or not is_instance_valid(_ruler) or _duration <= 0.0:
		return
	if event is InputEventMouseButton:
		_mouse_button(event)
	elif event is InputEventMouseMotion:
		if _panning:
			_ruler.pan_track(-event.relative.x)
			_pan_value_axis(event.relative.y)
			accept_event()
		elif not _drag.is_empty():
			_update_drag(event)
			accept_event()
		elif not _marquee.is_empty():
			_update_marquee(event.position)
			accept_event()
		else:
			_update_cursor(event.position)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_DELETE:
				if _selected_marker >= 0:
					marker_remove_requested.emit(_selected_marker)
				else:
					remove_requested.emit()
				accept_event()
			KEY_F:
				if _selected_curve and _selected_track >= 0:
					frame_curve(_selected_track)
					accept_event()
			KEY_ESCAPE:
				if not _drag.is_empty() or not _marquee.is_empty():
					_cancel_pointer()
					_invalidate_plot()
					accept_event()


func _mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed
		_pan_curve = _graph_at(event.position) if _panning else -1
		_update_cursor(event.position)
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and not _drag.is_empty():
		_commit_drag()
		_update_cursor(event.position)
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and not _marquee.is_empty():
		_commit_marquee()
		accept_event()
		return
	if _scroll_plot(event):
		accept_event()
		return
	if not event.pressed or event.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return
	var candidate := _entry_at(event.position, event.button_index == MOUSE_BUTTON_LEFT)
	if candidate.is_empty():
		return
	grab_focus()
	if candidate.get("is_marker", false):
		_marker_mouse_down(event, candidate)
		_update_cursor(event.position)
		accept_event()
		return
	if candidate.on_disclosure and event.button_index == MOUSE_BUTTON_LEFT:
		set_curve_expanded(candidate.track, not is_curve_expanded(candidate.track))
		_update_cursor(event.position)
		accept_event()
		return
	if candidate.on_graph and event.button_index == MOUSE_BUTTON_LEFT:
		_curve_mouse_down(event, candidate)
		_update_cursor(event.position)
		accept_event()
		return
	if candidate.on_graph and event.button_index == MOUSE_BUTTON_RIGHT \
			and candidate.entry < 0 and _selected_curve and _selected_track == candidate.track:
		candidate.entry = _selected_entry
	selection_requested.emit(candidate.is_curve, candidate.track, candidate.entry)
	if event.button_index == MOUSE_BUTTON_RIGHT or candidate.on_menu:
		menu_requested.emit(candidate.is_curve, candidate.track, candidate.entry,
				candidate.pointer_time, candidate.pointer_value, candidate.on_header)
	elif candidate.entry >= 0:
		_drag = candidate
		_drag.pointer = event.position
		if not _is_notify_state_handle(_drag):
			seek_requested.emit(_seek_time(_drag))
	elif not candidate.on_header:
		_ruler.scrub_track_at(event.position.x, event.ctrl_pressed)
	_update_cursor(event.position)
	accept_event()


func _marker_mouse_down(event: InputEventMouseButton, hit: Dictionary) -> void:
	marker_selection_requested.emit(hit.entry)
	if event.button_index == MOUSE_BUTTON_RIGHT or hit.on_menu:
		marker_menu_requested.emit(hit.entry, hit.pointer_time)
	elif hit.entry >= 0:
		_drag = hit
		_drag.pointer = event.position
		seek_requested.emit(hit.time)
	elif not hit.on_header:
		_ruler.scrub_track_at(event.position.x, event.ctrl_pressed)


func _curve_mouse_down(event: InputEventMouseButton, hit: Dictionary) -> void:
	var track: int = hit.track
	var key: int = hit.entry
	var keys := _curve_selection.duplicate() if _selected_curve and _selected_track == track else PackedInt32Array()
	if key < 0:
		if event.double_click:
			_set_graph_selection(track, keys, _selected_entry if not keys.is_empty() else -1)
			frame_curve(track)
			return
		_marquee = {
			"track": track, "origin": event.position, "tip": event.position,
			"base": keys if event.shift_pressed or event.ctrl_pressed else PackedInt32Array(),
			"toggle": event.ctrl_pressed, "free": event.ctrl_pressed,
			"keys": keys, "active": false,
		}
		return
	if hit.has("incoming"):
		_drag = hit
		_drag.pointer = event.position
		seek_requested.emit(hit.time)
		return
	if event.ctrl_pressed and key in keys:
		keys.remove_at(keys.find(key))
		_set_graph_selection(track, keys, keys[0] if not keys.is_empty() else -1)
		return
	if key not in keys:
		if not event.shift_pressed and not event.ctrl_pressed:
			keys.clear()
		keys.append(key)
	_set_graph_selection(track, keys, key)
	_drag = hit
	_drag.pointer = event.position
	_drag.keys = keys.duplicate()
	_drag.delta = Vector2.ZERO
	_drag.axis = MoveLock.BOTH
	seek_requested.emit(hit.time)


func _update_marquee(position: Vector2) -> void:
	var origin: Vector2 = _marquee.origin
	if not _marquee.active and position.distance_squared_to(origin) < 9.0:
		return
	_marquee.active = true
	_marquee.tip = position
	var bounds := _marquee_rect()
	var track: int = _marquee.track
	var keys: PackedInt32Array = _marquee.base.duplicate()
	var vertical := _curve_vertical(track)
	var limits := _curve_limits(track)
	var curve := _curves[track]
	for key in curve.point_count:
		if not bounds.grow(0.5).has_point(_key_position(curve.get_point_position(key), vertical, limits)):
			continue
		if _marquee.toggle and key in keys:
			keys.remove_at(keys.find(key))
		elif key not in keys:
			keys.append(key)
	_marquee.keys = keys
	queue_redraw()


func _marquee_rect() -> Rect2:
	var origin: Vector2 = _marquee.origin
	var tip: Vector2 = _marquee.tip
	var plot := _plot_rect(_curve_vertical(_marquee.track), _ruler.visible_time_range())
	return Rect2(origin, tip - origin).abs().intersection(plot)


func _commit_marquee() -> void:
	var marquee := _marquee
	_marquee = {}
	var keys: PackedInt32Array = marquee.keys if marquee.active else marquee.base
	_set_graph_selection(marquee.track, keys, keys[0] if not keys.is_empty() else -1)
	if not marquee.active:
		_ruler.scrub_track_at(marquee.origin.x, marquee.free)


func _curve_at_y(y: float) -> int:
	var offset := y - _marker_lane_height() - _tracks.notify_tracks.size() * ROW_HEIGHT
	if offset < 0.0:
		return -1
	for track in _tracks.curve_tracks.size():
		offset -= _curve_height(track)
		if offset < 0.0:
			return track
	return -1


func _graph_at(position: Vector2) -> int:
	var track := _curve_at_y(position.y)
	if position.x < HEADER_WIDTH or not is_curve_expanded(track):
		return -1
	return track if position.y >= _curve_top(track) + ROW_HEIGHT else -1


func _update_cursor(position: Vector2) -> void:
	if _panning:
		mouse_default_cursor_shape = CURSOR_DRAG
		return
	var hit := _drag
	if hit.is_empty() and Rect2(Vector2.ZERO, size).has_point(position):
		hit = _entry_at(position, false)
	var cursor := CURSOR_ARROW
	if hit.get("on_menu", false) or hit.get("on_disclosure", false):
		cursor = CURSOR_POINTING_HAND
	elif hit.get("entry", -1) >= 0:
		if hit.get("is_marker", false):
			cursor = CURSOR_HSIZE
		elif hit.is_curve:
			if hit.has("incoming"):
				cursor = CURSOR_CROSS
			elif _curve_move_lock == MoveLock.TIME:
				cursor = CURSOR_HSIZE
			elif _curve_move_lock == MoveLock.VALUE:
				cursor = CURSOR_VSIZE
			else:
				cursor = CURSOR_MOVE
		elif hit.end_time < 0.0 or hit.handle == &"body":
			cursor = CURSOR_MOVE
		else:
			cursor = CURSOR_HSIZE
	mouse_default_cursor_shape = cursor


func _scroll_plot(event: InputEventMouseButton) -> bool:
	if not event.pressed or event.position.x < HEADER_WIDTH:
		return false
	var curve := _graph_at(event.position)
	if curve < 0 and not event.ctrl_pressed and not event.shift_pressed:
		return false
	if not _ruler.scroll_track_at(event):
		return false
	if curve >= 0 and not event.ctrl_pressed and not event.shift_pressed \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var wheel := event.factor if event.factor > 0.0 else 1.0
		var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		var factor := pow(Timeline.ZOOM_FACTOR, -direction * wheel)
		var limits := _curve_limits(curve)
		var anchor := _curve_value(event.position.y, _curve_vertical(curve), limits)
		_set_curve_limits(curve, (limits - Vector2.ONE * anchor) * factor + Vector2.ONE * anchor)
	return true


func _pan_value_axis(delta: float) -> void:
	if _pan_curve < 0 or is_zero_approx(delta):
		return
	var limits := _curve_limits(_pan_curve)
	var vertical := _curve_vertical(_pan_curve)
	var shift := delta * (limits.y - limits.x) / (vertical.y - vertical.x)
	_set_curve_limits(_pan_curve, limits + Vector2.ONE * shift)


func _set_curve_limits(track: int, limits: Vector2) -> void:
	if not limits.is_finite() or limits.y <= limits.x:
		return
	_value_ranges[_tracks.curve_tracks[track].name] = limits
	_curve_plots.erase(track)
	queue_redraw()


func _curve_top(track: int) -> float:
	var top := _marker_lane_height() + _tracks.notify_tracks.size() * ROW_HEIGHT
	for index in track:
		top += _curve_height(index)
	return top


func _curve_vertical(track: int) -> Vector2:
	var top := _curve_top(track)
	return Vector2(top + ROW_HEIGHT + CURVE_PAD, top + _curve_height(track) - CURVE_PAD)


func _entry_at(at: Vector2, cycle_notifies: bool) -> Dictionary:
	var marker_height := _marker_lane_height()
	if at.y >= 0.0 and at.y < marker_height:
		return _marker_at(at, cycle_notifies)
	var notify_extent := marker_height + _tracks.notify_tracks.size() * ROW_HEIGHT
	var is_curve := at.y >= notify_extent
	var track := _curve_at_y(at.y) if is_curve else floori((at.y - marker_height) / ROW_HEIGHT)
	if track < 0 or track >= (_tracks.curve_tracks.size() if is_curve else _tracks.notify_tracks.size()):
		return {}
	var row_top := _curve_top(track) if is_curve else marker_height + track * ROW_HEIGHT
	var in_label_row := at.y < row_top + ROW_HEIGHT
	var hit := {
		"is_curve": is_curve, "track": track, "entry": -1,
		"on_header": at.x < HEADER_WIDTH,
		"on_menu": at.x >= HEADER_WIDTH - 28.0 and at.x < HEADER_WIDTH and in_label_row,
		"on_disclosure": is_curve and in_label_row and at.x < DISCLOSURE_WIDTH,
		"on_graph": is_curve and is_curve_expanded(track) and not in_label_row and at.x >= HEADER_WIDTH,
		"pointer_time": _ruler.time_at_x(at.x), "pointer_value": 0.0,
	}
	if hit.on_header:
		hit.pointer_time = _playhead
		return hit
	if is_curve:
		if hit.on_graph:
			_find_curve_entry(hit, at, _curve_vertical(track))
		else:
			hit.pointer_value = _curves[track].sample(hit.pointer_time / _duration)
	else:
		_find_notify_entry(hit, at, cycle_notifies)
	return hit


func _marker_at(at: Vector2, cycle: bool) -> Dictionary:
	var header := at.x < HEADER_WIDTH
	var hit := {
		"is_marker": true, "is_curve": false, "track": -1, "entry": -1,
		"on_header": header, "on_menu": at.x >= HEADER_WIDTH - 28.0 and header,
		"pointer_time": _playhead if header else _ruler.time_at_x(at.x),
	}
	if header:
		return hit
	var nearest := HIT_RADIUS
	var matches := PackedInt32Array()
	for entry in _tracks.markers.size():
		var time: float = _tracks.markers[entry].time
		if not _is_visible_time(time):
			continue
		var distance := absf(_ruler.x_at_time(time) - at.x)
		if distance > nearest:
			continue
		if distance < nearest:
			matches.clear()
			nearest = distance
		matches.append(entry)
	if not matches.is_empty():
		var selected := maxi(matches.find(_selected_marker), 0)
		if cycle and _selected_marker in matches:
			selected = (selected + 1) % matches.size()
		hit.entry = matches[selected]
		hit.time = _tracks.markers[hit.entry].time
		hit.original_time = hit.time
	return hit


func _find_curve_entry(hit: Dictionary, at: Vector2, vertical: Vector2) -> void:
	var curve := _curves[int(hit.track)]
	hit.limits = _curve_limits(hit.track)
	hit.vertical = vertical
	hit.pointer_value = _curve_value(at.y, vertical, hit.limits)
	var times := _ruler.visible_time_range()
	var nearest := HIT_RADIUS * HIT_RADIUS
	for key in curve.point_count:
		var point := curve.get_point_position(key)
		var time := curve.get_key_phase(key) * _duration
		if time < times.x or time > times.y or point.y < hit.limits.x or point.y > hit.limits.y:
			continue
		var position := _key_position(point, vertical, hit.limits)
		var distance := at.distance_squared_to(position)
		if distance <= nearest:
			nearest = distance
			hit.entry = key
			hit.time = time
			hit.value = point.y
			hit.original_time = time
			hit.original_value = point.y
	if _selected_curve and hit.track == _selected_track:
		_find_tangent(hit, at, curve, vertical, nearest)


func _find_tangent(hit: Dictionary, at: Vector2, curve: RichCurve, vertical: Vector2, nearest: float) -> void:
	var bounds := _plot_rect(vertical, _ruler.visible_time_range())
	for key in _curve_selection:
		for incoming: bool in [true, false]:
			if not curve.has_handle(key, incoming):
				continue
			var handle := _tangent_position(curve, key, incoming, vertical, hit.limits)
			var distance := at.distance_squared_to(handle)
			if distance > nearest or not bounds.has_point(handle):
				continue
			nearest = distance
			hit.entry = key
			hit.incoming = incoming
			hit.handle_position = handle
			hit.time = curve.get_key_phase(key) * _duration


func _find_notify_entry(hit: Dictionary, at: Vector2, cycle: bool) -> void:
	var entries: Array = _tracks.notify_tracks[hit.track].notifies
	var times := _ruler.visible_time_range()
	var best := INF
	var matches: Array[Dictionary] = []
	for index in entries.size():
		var notify: Dictionary = entries[index]
		var time := float(notify.time)
		var end_time := float(notify.end_time)
		var start_x := _ruler.x_at_time(time)
		var nearest := absf(at.x - start_x) if time >= times.x and time <= times.y else INF
		var handle := &"start"
		if end_time >= 0.0:
			var end_x := _ruler.x_at_time(end_time)
			var to_end := absf(at.x - end_x) if end_time >= times.x and end_time <= times.y else INF
			if to_end < nearest:
				nearest = to_end
				handle = &"end"
			if nearest > HIT_RADIUS and at.x >= minf(start_x, end_x) and at.x <= maxf(start_x, end_x):
				handle = &"body"
				nearest = HIT_RADIUS
		if nearest > HIT_RADIUS:
			continue
		if nearest < best and not is_equal_approx(nearest, best):
			best = nearest
			matches.clear()
		if is_equal_approx(nearest, best):
			matches.append({"entry": index, "name": notify.name, "time": time,
				"end_time": end_time, "original_time": time, "original_end_time": end_time,
				"handle": handle})
	if matches.is_empty():
		return
	var selected := 0
	if not _selected_curve and hit.track == _selected_track:
		for index in matches.size():
			if matches[index].entry == _selected_entry:
				selected = (index + 1) % matches.size() if cycle else index
				break
	hit.merge(matches[selected], true)


func _drag_matches(is_curve: bool, track: int, entry: int) -> bool:
	return not _drag.is_empty() and _drag.is_curve == is_curve and _drag.track == track and _drag.entry == entry


func _update_drag(event: InputEventMouseMotion) -> void:
	if not _drag.get("moved", false) and event.position.distance_squared_to(_drag.pointer) < 9.0:
		return
	if _drag.get("is_marker", false):
		var x := _ruler.x_at_time(_drag.original_time) + event.position.x - float(_drag.pointer.x)
		_drag.time = _ruler.time_at_x(x, event.ctrl_pressed)
		_drag.moved = _drag.time != _drag.original_time
		queue_redraw()
		return
	var previous_time := _seek_time(_drag)
	if _drag.is_curve:
		if _drag.has("incoming"):
			_update_tangent_drag(event.position)
		else:
			_update_curve_drag(event)
	else:
		var time := _ruler.time_at_x(event.position.x, event.ctrl_pressed)
		var original_start: float = _drag.original_time
		var original_end: float = _drag.original_end_time
		match _drag.handle:
			&"body":
				var length := original_end - original_start
				var start := clampf(original_start + time - float(_drag.pointer_time), 0.0, _duration - length)
				_drag.time = start
				_drag.end_time = start + length
			&"end":
				_drag.end_time = clampf(time, original_start + MIN_STATE_DURATION, _duration)
			&"start":
				var last := original_end - MIN_STATE_DURATION if original_end >= 0.0 else _duration
				_drag.time = clampf(time, 0.0, maxf(last, 0.0))
		_drag.moved = _drag.time != original_start or _drag.end_time != original_end
	if not _is_notify_state_handle(_drag) and _seek_time(_drag) != previous_time:
		seek_requested.emit(_seek_time(_drag))
	queue_redraw()


func _update_curve_drag(event: InputEventMouseMotion) -> void:
	var original := _curves[int(_drag.track)]
	var pixel_delta: Vector2 = event.position - _drag.pointer
	var axis := _curve_move_lock
	if axis == MoveLock.BOTH and event.shift_pressed:
		if _drag.axis == MoveLock.BOTH:
			_drag.axis = MoveLock.TIME if absf(pixel_delta.x) > absf(pixel_delta.y) else MoveLock.VALUE
		axis = _drag.axis
	elif not event.shift_pressed:
		_drag.axis = MoveLock.BOTH
	var relative_time := float(_drag.original_time) + _ruler.time_at_x(event.position.x) - float(_drag.pointer_time)
	var time := _ruler.time_at_x(_ruler.x_at_time(relative_time), event.ctrl_pressed)
	var limits: Vector2 = _drag.limits
	var vertical: Vector2 = _drag.vertical
	var value_per_pixel := (limits.y - limits.x) / (vertical.y - vertical.x)
	var delta := Vector2((time - float(_drag.original_time)) / _duration, -pixel_delta.y * value_per_pixel)
	match axis:
		MoveLock.TIME:
			delta.y = 0.0
		MoveLock.VALUE:
			delta.x = 0.0
	var keys: PackedInt32Array = _drag.keys
	var min_phase := 1.0
	var max_phase := 0.0
	for key in keys:
		var info := original.key_info(key)
		min_phase = minf(min_phase, info.phase)
		max_phase = maxf(max_phase, info.phase)
	delta.x = clampf(delta.x, -min_phase, 1.0 - max_phase)
	if delta == _drag.delta:
		return
	var preview := original.duplicate(true) as RichCurve
	var moved := preview.move_keys(keys, delta)
	if moved.is_empty() and delta != Vector2.ZERO:
		return
	_drag_curve = preview
	_drag_curve_keys = keys if delta == Vector2.ZERO else moved
	_drag.delta = delta
	_drag.time = float(preview.key_info(_drag_curve_keys[keys.find(_drag.entry)]).phase) * _duration
	_drag.moved = delta != Vector2.ZERO
	_curve_plots.erase(_drag.track)


func _update_tangent_drag(pointer: Vector2) -> void:
	var original := _curves[int(_drag.track)]
	var key: int = _drag.entry
	var incoming: bool = _drag.incoming
	var position: Vector2 = _drag.handle_position + pointer - _drag.pointer
	var phase := _ruler.time_at_x(position.x) / _duration - original.get_key_phase(key)
	var epsilon := 0.000001
	phase = minf(-epsilon, phase) if incoming else maxf(epsilon, phase)
	var vertical: Vector2 = _drag.vertical
	var limits: Vector2 = _drag.limits
	var value := lerpf(limits.x, limits.y, inverse_lerp(vertical.y, vertical.x, position.y))
	var offset := Vector2(phase, value - original.get_key_value(key))
	var preview := original.duplicate(true) as RichCurve
	if not preview.set_key_tangent(key, incoming, offset):
		return
	_drag_curve = preview
	_drag.offset = offset
	_drag.moved = true
	_curve_plots.erase(_drag.track)


func _seek_time(hit: Dictionary) -> float:
	if not hit.is_curve and hit.handle == &"end":
		return hit.end_time
	return hit.time


func _is_notify_state_handle(hit: Dictionary) -> bool:
	return not hit.is_curve and hit.end_time >= 0.0 and hit.handle != &"body"


func _commit_drag() -> void:
	var drag := _drag
	var keys := _drag_curve_keys
	_drag = {}
	_drag_curve = null
	_drag_curve_keys = PackedInt32Array()
	_curve_plots.erase(drag.track)
	queue_redraw()
	if not drag.get("moved", false):
		return
	if drag.get("is_marker", false):
		edit_requested.emit(&"set_marker", {"entry": drag.entry, "time": drag.time})
	elif drag.is_curve:
		if drag.has("incoming"):
			edit_requested.emit(&"set_curve_key_tangent", {"track": drag.track, "key": drag.entry,
				"incoming": drag.incoming, "offset": drag.offset})
		else:
			edit_requested.emit(&"move_curve_keys", {"track": drag.track, "keys": drag.keys, "delta": drag.delta})
			_set_graph_selection(drag.track, keys, keys[drag.keys.find(drag.entry)])
	else:
		edit_requested.emit(&"set_notify", {"track": drag.track, "entry": drag.entry,
			"name": drag.name, "time": drag.time, "end_time": drag.end_time})
