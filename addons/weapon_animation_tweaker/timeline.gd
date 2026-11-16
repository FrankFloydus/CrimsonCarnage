@tool
extends Range
## Zoomable time ruler. The view window is independent of playback time.

signal drag_started
signal drag_ended(value_changed: bool)
signal view_changed

const ZOOM_FACTOR := 1.6
const MAX_ZOOM := 128.0
const INSET := 10.0
const KEY_SPACING := 8.0

## Allow seeking with the mouse and keyboard while the preview is available.
@export var editable := true:
	set(enabled):
		editable = enabled
		if not enabled:
			_cancel_pointer()
		_update_readout()
		queue_redraw()

## Optional path to the time label paired with this ruler.
@export var readout_path := NodePath()

var _key_times := PackedFloat64Array()
var _window_start := 0.0
var _zoom := 1.0
var _leading_space := 0.0
var _trailing_space := 0.0
var _dragging := false
var _panning := false
var _drag_start_value := 0.0
var _time_readout: Label
var _loop_start := 0.0
var _loop_end := 0.0


func _ready() -> void:
	if not readout_path.is_empty():
		_time_readout = get_node_or_null(readout_path) as Label
	elif owner != null:
		_time_readout = owner.get_node_or_null("%TimeReadout") as Label
	step = 0.0
	changed.connect(_clamp_window)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	_clamp_window()


## Set the sorted authored key times used for display and snapping.
func set_key_times(times: PackedFloat64Array) -> void:
	var sorted := PackedFloat64Array()
	for time in times:
		if is_finite(time):
			sorted.append(time)
	sorted.sort()
	_key_times.clear()
	for time in sorted:
		if _key_times.is_empty() or _key_times[-1] != time:
			_key_times.append(time)
	queue_redraw()


## Highlight the active preview loop interval in clip seconds.
func set_loop_region(start: float, end: float) -> void:
	if not is_finite(start) or not is_finite(end) or end <= start:
		clear_loop_region()
	elif _loop_start != start or _loop_end != end:
		_loop_start = start
		_loop_end = end
		queue_redraw()


## Hide the preview loop highlight.
func clear_loop_region() -> void:
	if _loop_end > _loop_start:
		_loop_start = 0.0
		_loop_end = 0.0
		queue_redraw()


## Show the full clip without moving the playhead.
func fit() -> void:
	_zoom = 1.0
	_window_start = min_value
	_clamp_window()


## Frame the given times with the same mapping used for timeline and curve rows.
func frame_times(first: float, last: float) -> void:
	var duration := _duration()
	if duration <= 0.0:
		return
	var span := maxf(0.0, last - first)
	span = maxf(span * 1.20, duration / MAX_ZOOM)
	_zoom = clampf(duration / span, 1.0, MAX_ZOOM)
	_window_start = (first + last - _window_span()) * 0.5
	_clamp_window()


## Increase time zoom around the visible playhead or the center of the ruler.
func zoom_in() -> void:
	_zoom_at(_playhead_fraction(), ZOOM_FACTOR)


## Reduce time zoom around the visible playhead or the center of the ruler.
func zoom_out() -> void:
	_zoom_at(_playhead_fraction(), 1.0 / ZOOM_FACTOR)


## Reserve room for headers and the scrollbar of the aligned track rows.
func set_track_insets(leading: float, trailing: float) -> void:
	if is_equal_approx(leading, _leading_space) and is_equal_approx(trailing, _trailing_space):
		return
	_leading_space = leading
	_trailing_space = trailing
	_clamp_window()


## Get the start and end times visible on the shared ruler.
func visible_time_range() -> Vector2:
	return Vector2(_window_start, _window_start + _window_span())


## Time grid interval shared with the float curve canvas.
func major_tick_step() -> float:
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var width := font.get_string_size("%.3f" % max_value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	return _ruler_step(maxf(64.0, width + 20.0) * maxf(_window_span(), 0.000001) / _pixel_span())


## Map a clip time to the aligned track coordinates.
func x_at_time(time: float) -> float:
	return _x_at(time, maxf(_window_span(), 0.000001))


## Map a shared track position to a time, with optional existing key snapping.
func time_at_x(x: float, free: bool = true) -> float:
	var span := _window_span()
	var time := _window_start + _fraction_at(x) * span
	return time if free else _nearest_key(time, _window_start, _window_start + span)


## Seek from a click in a track row using the normal scrub signals.
func scrub_track_at(x: float, free: bool) -> void:
	if not editable:
		return
	var previous := value
	drag_started.emit()
	_scrub(x, free)
	drag_ended.emit(value != previous)


## Share wheel zoom and Shift-wheel pan with the aligned track rows.
func scroll_track_at(event: InputEventMouseButton) -> bool:
	if not event.pressed:
		return false
	var direction := 0.0
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT:
			direction = -1.0
		MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_RIGHT:
			direction = 1.0
	if direction == 0.0:
		return false
	var steps := event.factor if event.factor > 0.0 else 1.0
	if event.shift_pressed or event.button_index in [MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		pan_track(direction * steps * _pixel_span() * 0.12)
	else:
		_zoom_at(_fraction_at(event.position.x), pow(ZOOM_FACTOR, -direction * steps))
	return true


## Pan the shared time window by a horizontal drag in the track rows.
func pan_track(pixels: float) -> void:
	var direction := -1.0 if is_layout_rtl() else 1.0
	_window_start += direction * pixels * _window_span() / _pixel_span()
	_clamp_window()


func _get_minimum_size() -> Vector2:
	return Vector2(120.0, float(get_theme_default_font_size()) + 32.0)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_VISIBILITY_CHANGED, NOTIFICATION_EXIT_TREE:
			_cancel_pointer()
		NOTIFICATION_THEME_CHANGED:
			update_minimum_size()
			queue_redraw()


func _cancel_pointer() -> void:
	_dragging = false
	_panning = false
	mouse_default_cursor_shape = CURSOR_ARROW


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_mouse_button(event)
	elif event is InputEventMouseMotion:
		if _panning:
			pan_track(-event.relative.x)
			accept_event()
		elif _dragging and editable:
			_scrub(event.position.x, event.ctrl_pressed)
			accept_event()
	elif event is InputEventKey and editable:
		var direction := 0
		if event.is_action_pressed(&"ui_left", true):
			direction = -1
		elif event.is_action_pressed(&"ui_right", true):
			direction = 1
		if direction != 0:
			_move_with_key(-direction if is_layout_rtl() else direction, event.ctrl_pressed)
			accept_event()


func _mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed and _zoom > 1.0
		mouse_default_cursor_shape = CURSOR_DRAG if _panning else CURSOR_ARROW
		accept_event()
	elif event.button_index == MOUSE_BUTTON_LEFT and editable:
		if event.pressed:
			grab_focus()
			_dragging = true
			_drag_start_value = value
			drag_started.emit()
			_scrub(event.position.x, event.ctrl_pressed)
		elif _dragging:
			_scrub(event.position.x, event.ctrl_pressed)
			_dragging = false
			drag_ended.emit(value != _drag_start_value)
		accept_event()
	elif scroll_track_at(event):
		accept_event()


func _duration() -> float:
	return maxf(0.0, max_value - min_value)


func _window_span() -> float:
	return _duration() / _zoom


func _pixel_span() -> float:
	return maxf(1.0, size.x - _leading_space - _trailing_space - INSET * 2.0)


func _fraction_at(x: float) -> float:
	var fraction := clampf((x - _leading_space - INSET) / _pixel_span(), 0.0, 1.0)
	return 1.0 - fraction if is_layout_rtl() else fraction


func _x_at(time: float, span: float) -> float:
	var fraction := (time - _window_start) / span
	if is_layout_rtl():
		fraction = 1.0 - fraction
	return _leading_space + INSET + _pixel_span() * fraction


func _playhead_fraction() -> float:
	var span := _window_span()
	if span <= 0.0 or value < _window_start or value > _window_start + span:
		return 0.5
	return (value - _window_start) / span


func _clamp_window() -> void:
	_window_start = clampf(_window_start, min_value, maxf(min_value, max_value - _window_span()))
	_update_readout()
	queue_redraw()
	view_changed.emit()


func _zoom_at(fraction: float, factor: float) -> void:
	var anchor := _window_start + fraction * _window_span()
	_zoom = clampf(_zoom * factor, 1.0, MAX_ZOOM)
	_window_start = anchor - fraction * _window_span()
	_clamp_window()


func _scrub(x: float, free: bool) -> void:
	value = time_at_x(x, free)


func _nearest_key(time: float, start: float, finish: float) -> float:
	var first := _key_times.bsearch(start)
	var after_last := _key_times.bsearch(finish, false)
	if first == after_last:
		return time
	var next := _key_times.bsearch(time)
	if next <= first:
		return _key_times[first]
	if next >= after_last:
		return _key_times[after_last - 1]
	var previous := _key_times[next - 1]
	return previous if time - previous <= _key_times[next] - time else _key_times[next]


func _move_with_key(direction: int, free: bool) -> void:
	var first := _key_times.bsearch(min_value)
	var after_last := _key_times.bsearch(max_value, false)
	if free or first == after_last:
		value += direction * _window_span() * 0.01
		_keep_playhead_visible()
	else:
		step_keyframe(direction)


## Seek to the next or previous authored key within the clip.
func step_keyframe(direction: int) -> void:
	var lower := _key_times.bsearch(value)
	var exact := lower < _key_times.size() and _key_times[lower] == value
	var index := lower - 1 if direction < 0 else lower + int(exact)
	# Free scrubbing can land on the decimal equivalent of a float32 import time.
	if not exact and index >= 0 and index < _key_times.size() and absf(_key_times[index] - value) < 0.0000001:
		index += direction
	if index >= 0 and index < _key_times.size():
		var time := _key_times[index]
		if time >= min_value and time <= max_value:
			value = time
	_keep_playhead_visible()


func _keep_playhead_visible() -> void:
	if value < _window_start:
		_window_start = value
	elif value > _window_start + _window_span():
		_window_start = value - _window_span()
	_clamp_window()


func _value_changed(_new_value: float) -> void:
	_update_readout()


func _update_readout() -> void:
	if not is_instance_valid(_time_readout):
		return
	var reading := "%.3f / %.3f s" % [value, max_value] if editable else "— / — s"
	if _time_readout.text != reading:
		_time_readout.text = reading


func _draw() -> void:
	var bounds := Rect2(Vector2.ZERO, size)
	var frame := get_theme_stylebox(&"normal") if has_theme_stylebox(&"normal") else get_theme_stylebox(&"normal", &"LineEdit")
	draw_style_box(frame, bounds)
	var span := _window_span()
	if span > 0.0 and size.x > _leading_space + _trailing_space + INSET * 2.0:
		var color := _timeline_color(&"text", get_theme_color(&"font_color", &"Label"))
		var font := get_theme_default_font()
		var font_size := get_theme_default_font_size()
		var axis_y := float(font_size) + 12.0
		draw_rect(Rect2(_leading_space + 2.0, axis_y,
				size.x - _leading_space - _trailing_space - 4.0, size.y - axis_y - 2.0),
				_timeline_color(&"track", Color(color, 0.06)))
		_draw_loop_region(color, span, axis_y)
		_draw_ruler(font, font_size, color, span, axis_y)
		_draw_keys(color, span, axis_y)
		if editable and value >= _window_start and value <= _window_start + span:
			_draw_playhead(color, span)
	if has_focus():
		var focus_style := get_theme_stylebox(&"focus") if has_theme_stylebox(&"focus") else get_theme_stylebox(&"focus", &"LineEdit")
		draw_style_box(focus_style, bounds)


func _timeline_color(role: StringName, fallback: Color) -> Color:
	var color := get_theme_color(role) if has_theme_color(role) else fallback
	if not editable:
		color.a *= 0.45
	return color


func _draw_loop_region(color: Color, span: float, axis_y: float) -> void:
	var window_end := _window_start + span
	var start := maxf(_loop_start, _window_start)
	var end := minf(_loop_end, window_end)
	if end <= start:
		return
	var start_x := _x_at(start, span)
	var end_x := _x_at(end, span)
	var tint := _timeline_color(&"playhead", color)
	var bottom_y := size.y - 2.0
	draw_rect(Rect2(minf(start_x, end_x), axis_y, absf(end_x - start_x), bottom_y - axis_y),
			Color(tint, tint.a * 0.18))
	var edge := Color(tint, tint.a * 0.76)
	if _loop_start >= _window_start:
		var x := roundf(start_x) + 0.5
		draw_line(Vector2(x, axis_y), Vector2(x, bottom_y), edge)
	if _loop_end <= window_end:
		var x := roundf(end_x) + 0.5
		draw_line(Vector2(x, axis_y), Vector2(x, bottom_y), edge)


func _draw_ruler(font: Font, font_size: int, color: Color, span: float, axis_y: float) -> void:
	var step_seconds := major_tick_step()
	var decimals := clampi(ceili(-log(step_seconds) / log(10.0)), 0, 9)
	var major_color := _timeline_color(&"tick_major", Color(color, color.a * 0.43))
	var minor_color := _timeline_color(&"tick_minor", Color(color, color.a * 0.22))
	var subdivisions := 4 if is_equal_approx(step_seconds * pow(10.0, decimals), 2.0) else 5
	var minor_step := step_seconds / subdivisions
	var start_minor := ceili(_window_start / minor_step)
	var end_minor := floori((_window_start + span) / minor_step)
	var rtl := is_layout_rtl()
	var right := size.x - _trailing_space
	var label_boundary := right if rtl else _leading_space
	draw_line(Vector2(_leading_space + INSET, axis_y), Vector2(right - INSET, axis_y), major_color)
	for index in range(start_minor, end_minor + 1):
		var time := index * minor_step
		var x := roundf(_x_at(time, span)) + 0.5
		if index % subdivisions != 0:
			draw_line(Vector2(x, axis_y - 3.0), Vector2(x, axis_y), minor_color)
			continue
		draw_line(Vector2(x, axis_y - 6.0), Vector2(x, axis_y), major_color)
		var label := String.num(time, decimals)
		var label_width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var label_start := _leading_space + 5.0
		var text_x := clampf(x - label_width / 2.0, label_start, maxf(label_start, right - label_width - 5.0))
		if (rtl and text_x + label_width > label_boundary) or (not rtl and text_x < label_boundary):
			continue
		draw_string(font, Vector2(text_x, axis_y - 8.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
		label_boundary = text_x - 6.0 if rtl else text_x + label_width + 6.0


func _ruler_step(minimum: float) -> float:
	var decade := pow(10.0, floorf(log(minimum) / log(10.0)))
	for scale: float in [1.0, 2.0, 5.0, 10.0]:
		if decade * scale >= minimum:
			return decade * scale
	return decade * 10.0


func _draw_keys(color: Color, span: float, axis_y: float) -> void:
	var gap := KEY_SPACING * span / _pixel_span()
	var marker_color := _timeline_color(&"key", Color(color, color.a * 0.66))
	var y := (axis_y + size.y) * 0.5
	var index := _key_times.bsearch(_window_start)
	var finish := _key_times.bsearch(_window_start + span, false)
	while index < finish:
		var time := _key_times[index]
		var x := _x_at(time, span)
		draw_colored_polygon(PackedVector2Array([
			Vector2(x, y - 3.5), Vector2(x + 3.5, y), Vector2(x, y + 3.5), Vector2(x - 3.5, y),
		]), marker_color)
		index = maxi(index + 1, _key_times.bsearch(time + gap))


func _draw_playhead(color: Color, span: float) -> void:
	var default_accent := get_theme_color(&"accent_color", &"Editor") if has_theme_color(&"accent_color", &"Editor") else color
	var accent := _timeline_color(&"playhead", default_accent)
	var x := roundf(_x_at(value, span)) + 0.5
	draw_line(Vector2(x, 3.0), Vector2(x, size.y - 2.0), accent)
	draw_colored_polygon(PackedVector2Array([
		Vector2(x - 4.5, 1.0), Vector2(x + 4.5, 1.0), Vector2(x, 6.0),
	]), accent)
