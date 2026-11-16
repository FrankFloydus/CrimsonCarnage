@tool
extends Control
## Draws the combo's clips and blends in the same time window as its preview ruler.

signal clip_selected(index: int)
signal join_selected(index: int)
signal scrub_requested(seconds: float)
signal reorder_requested(from_index: int, to_index: int)

const Timeline := preload("timeline.gd")
const GUTTER := 78.0
const MIN_BLOCK_WIDTH := 8.0
const REORDER_THRESHOLD := 6.0
const CLIP_COLORS: Array[Color] = [Color("#415c76"), Color("#386664")]

var _ruler: Timeline
var _clips: Array[Dictionary] = []
var _blends: Array[Dictionary] = []
var _selected_clip := -1
var _selected_join := -1
var _pressed_clip := -1
var _drop_clip := -1
var _press_position := Vector2.ZERO
var _reordering := false
var _scrubbing := false
var _panning := false
var _allow_reorder := true


## Share the timeline's time-to-pixel mapping, zoom, and playhead.
func bind_ruler(ruler: Timeline) -> void:
	if _ruler == ruler:
		return
	if is_instance_valid(_ruler):
		_ruler.view_changed.disconnect(queue_redraw)
		_ruler.resized.disconnect(queue_redraw)
		_ruler.value_changed.disconnect(_on_playhead_changed)
	_ruler = ruler
	if is_instance_valid(_ruler):
		_ruler.view_changed.connect(queue_redraw)
		_ruler.resized.connect(queue_redraw)
		_ruler.value_changed.connect(_on_playhead_changed)
		_align_ruler()
		_match_hidden_ruler_width()
	queue_redraw()


## Display the evaluator's clip ranges and transition overlaps.
func set_layout(clips: Array[Dictionary], blends: Array[Dictionary],
		selected_clip: int, selected_join: int) -> void:
	_clips.assign(clips)
	_blends.assign(blends)
	_selected_clip = selected_clip
	_selected_join = selected_join
	queue_redraw()


## Allow dragging clip blocks into a new sequence order.
func set_reorder_enabled(enabled: bool) -> void:
	_allow_reorder = enabled


func _get_minimum_size() -> Vector2:
	return Vector2(0.0, 3.0 * _row_height())


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_THEME_CHANGED:
			update_minimum_size()
			queue_redraw()
		NOTIFICATION_LAYOUT_DIRECTION_CHANGED:
			_align_ruler()
			queue_redraw()
		NOTIFICATION_RESIZED:
			_match_hidden_ruler_width()
			queue_redraw()
		NOTIFICATION_VISIBILITY_CHANGED, NOTIFICATION_EXIT_TREE:
			_reset_pointer()


func _row_height() -> float:
	return float(get_theme_default_font_size()) + 13.0


func _align_ruler() -> void:
	if is_instance_valid(_ruler):
		var rtl := is_layout_rtl()
		_ruler.set_track_insets(0.0 if rtl else GUTTER, GUTTER if rtl else 0.0)


func _match_hidden_ruler_width() -> void:
	if is_instance_valid(_ruler) and not _ruler.visible:
		_ruler.size.x = size.x


func _on_playhead_changed(_seconds: float) -> void:
	queue_redraw()


func _color(role: StringName) -> Color:
	return get_theme_color(role, &"WeaponTimeline")


func _draw() -> void:
	var row_height := _row_height()
	var background := _color(&"track")
	var divider := _color(&"tick_minor")
	var gutter_x := size.x - GUTTER if is_layout_rtl() else 0.0
	draw_rect(Rect2(0.0, 0.0, size.x, size.y), background)
	draw_rect(Rect2(0.0, row_height, size.x, row_height), background.darkened(0.17))
	draw_rect(Rect2(gutter_x, 0.0, GUTTER, size.y), background.lightened(0.04))
	for row in range(1, 4):
		var y := row * row_height - 0.5
		draw_line(Vector2(0.0, y), Vector2(size.x, y), divider)
	var border_x := gutter_x + 0.5 if is_layout_rtl() else GUTTER - 0.5
	draw_line(Vector2(border_x, 0.0), Vector2(border_x, size.y), divider)
	_draw_text(Rect2(gutter_x, 0.0, GUTTER, row_height * 2.0), "Clips", _color(&"text"))
	_draw_text(Rect2(gutter_x, row_height * 2.0, GUTTER, row_height), "Blends", _color(&"text"))
	if not _has_time():
		return
	_draw_grid()
	for blend in _blends:
		if int(blend.index) == _selected_join:
			var span := _block_rect(blend, 2)
			if span.has_area():
				draw_rect(Rect2(span.position.x, 0.0, span.size.x, row_height * 2.0), Color(_color(&"playhead"), 0.09))
	for clip in _clips:
		_draw_clip(clip)
	for blend in _blends:
		_draw_blend(blend)
	var times := _time_window()
	if _ruler.editable and _ruler.value >= times[0] and _ruler.value <= times[1]:
		var x := floorf(_ruler.x_at_time(_ruler.value)) + 0.5
		draw_line(Vector2(x, 0.0), Vector2(x, row_height * 3.0), _color(&"playhead"))


func _draw_grid() -> void:
	var step := _ruler.major_tick_step()
	var times := _time_window()
	for tick in range(ceili(times[0] / step), floori(times[1] / step) + 1):
		var x := floorf(_ruler.x_at_time(tick * step)) + 0.5
		draw_line(Vector2(x, 0.0), Vector2(x, 3.0 * _row_height()), _color(&"tick_minor"))


func _draw_clip(clip: Dictionary) -> void:
	var lane := clampi(int(clip.lane), 0, 1)
	var rect := _block_rect(clip, lane)
	if not rect.has_area():
		return
	var selected := int(clip.index) == _selected_clip
	var drop_target := _reordering and int(clip.index) == _drop_clip
	var fill := CLIP_COLORS[lane]
	var accent := _color(&"playhead")
	if selected:
		fill = fill.lerp(accent, 0.27)
	draw_rect(rect, fill)
	var border := accent if selected or drop_target else fill.lightened(0.20)
	draw_rect(rect.grow(-0.5), border, false, 2.0 if drop_target else 1.0)
	_draw_text(rect, String(clip.label), _color(&"key"))


func _draw_blend(blend: Dictionary) -> void:
	var rect := _block_rect(blend, 2)
	if not rect.has_area():
		return
	var accent := _color(&"playhead")
	var selected := int(blend.index) == _selected_join
	draw_rect(rect, _color(&"track").lerp(accent, 0.40 if selected else 0.21))
	draw_rect(rect.grow(-0.5), accent if selected else accent.darkened(0.35), false)
	var duration := float(blend.end) - float(blend.start)
	var label := "%.3f s" % duration if duration > 0.0 else "Cut"
	_draw_text(rect, label, _color(&"key"))


func _draw_text(rect: Rect2, label: String, color: Color) -> void:
	var margin := 7.0
	var width := rect.size.x - margin * 2.0
	if width < 12.0:
		return
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var line := TextLine.new()
	line.add_string(label, font, font_size)
	line.width = width
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if is_layout_rtl():
		line.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.draw(get_canvas_item(), rect.position + Vector2(margin, (rect.size.y - line.get_size().y) * 0.5), color)


func _has_time() -> bool:
	return is_instance_valid(_ruler) and _ruler.max_value > _ruler.min_value and size.x > GUTTER + 2.0 * Timeline.INSET


func _time_window() -> PackedFloat64Array:
	# Compute endpoint times through the ruler to avoid narrowing them to Vector2 precision.
	var first := _ruler.time_at_x(0.0)
	var last := _ruler.time_at_x(_ruler.size.x)
	return PackedFloat64Array([minf(first, last), maxf(first, last)])


func _block_rect(block: Dictionary, lane: int) -> Rect2:
	var times := _time_window()
	var start := float(block.start)
	var end := float(block.end)
	if end < times[0] or start > times[1]:
		return Rect2()
	var a := _ruler.x_at_time(maxf(start, times[0]))
	var b := _ruler.x_at_time(minf(end, times[1]))
	var left := Timeline.INSET + (0.0 if is_layout_rtl() else GUTTER)
	var right := size.x - Timeline.INSET - (GUTTER if is_layout_rtl() else 0.0)
	var width := clampf(absf(b - a) - 1.0, MIN_BLOCK_WIDTH, maxf(MIN_BLOCK_WIDTH, right - left))
	var x := clampf((a + b - width) * 0.5, left, maxf(left, right - width))
	var height := _row_height()
	return Rect2(x, lane * height + 2.0, width, height - 4.0)


func _item_at(items: Array[Dictionary], at: Vector2, clips: bool) -> Dictionary:
	for item in items:
		var lane := clampi(int(item.get("lane", 0)), 0, 1) if clips else 2
		if _block_rect(item, lane).has_point(at):
			return item
	return {}


func _get_tooltip(at_position: Vector2) -> String:
	if not _has_time():
		return ""
	var item := _item_at(_clips, at_position, true)
	if not item.is_empty():
		return "%s\n%.3f–%.3f s" % [item.get("tooltip", item.label), item.start, item.end]
	item = _item_at(_blends, at_position, false)
	if item.is_empty():
		return ""
	return "Join %d · %.3f s overlap" % [int(item.index) + 1, float(item.end) - float(item.start)]


func _gui_input(event: InputEvent) -> void:
	if not _has_time():
		return
	if event is InputEventMouseButton:
		_mouse_button(event)
	elif event is InputEventMouseMotion:
		_mouse_motion(event)


func _mouse_button(event: InputEventMouseButton) -> void:
	if _ruler.scroll_track_at(event):
		accept_event()
	elif event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed
		mouse_default_cursor_shape = CURSOR_DRAG if _panning else CURSOR_ARROW
		accept_event()
	elif event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press_at(event.position)
		else:
			_release_at(event.position)
		accept_event()


func _press_at(at: Vector2) -> void:
	var blend := _item_at(_blends, at, false)
	if not blend.is_empty():
		join_selected.emit(int(blend.index))
		return
	var clip := _item_at(_clips, at, true)
	if not clip.is_empty():
		_pressed_clip = int(clip.index)
		_press_position = at
		return
	var in_gutter := at.x > size.x - GUTTER if is_layout_rtl() else at.x < GUTTER
	if not in_gutter and _ruler.editable:
		_ruler.grab_focus()
		_scrubbing = true
		scrub_requested.emit(_ruler.time_at_x(at.x))


func _release_at(at: Vector2) -> void:
	if _pressed_clip >= 0:
		var pressed_clip := _pressed_clip
		var destination := int(_item_at(_clips, at, true).get("index", -1))
		var reorder := _reordering
		_reset_pointer()
		if reorder and destination >= 0 and destination != pressed_clip:
			reorder_requested.emit(pressed_clip, destination)
		elif not reorder and destination == pressed_clip:
			clip_selected.emit(pressed_clip)
	elif _scrubbing:
		_scrubbing = false
		scrub_requested.emit(_ruler.time_at_x(at.x))


func _mouse_motion(event: InputEventMouseMotion) -> void:
	if _panning:
		_ruler.pan_track(-event.relative.x)
		accept_event()
		return
	if _scrubbing:
		scrub_requested.emit(_ruler.time_at_x(event.position.x))
		accept_event()
		return
	var clip := _item_at(_clips, event.position, true)
	if _allow_reorder and _pressed_clip >= 0 and (_reordering or event.position.distance_to(_press_position) >= REORDER_THRESHOLD):
		_reordering = true
		_drop_clip = int(clip.get("index", -1))
		mouse_default_cursor_shape = CURSOR_DRAG
		queue_redraw()
		accept_event()
		return
	var has_item := not clip.is_empty() or not _item_at(_blends, event.position, false).is_empty()
	mouse_default_cursor_shape = CURSOR_POINTING_HAND if has_item else CURSOR_ARROW


func _reset_pointer() -> void:
	_pressed_clip = -1
	_drop_clip = -1
	_reordering = false
	_scrubbing = false
	_panning = false
	mouse_default_cursor_shape = CURSOR_ARROW
	queue_redraw()
