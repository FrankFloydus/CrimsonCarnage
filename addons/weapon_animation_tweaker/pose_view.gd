@tool
extends Control
## Navigates the private pose camera and picks projected joints.

signal bone_selected(index: int)

const ORBIT_SPEED := 0.008
const POLE_LIMIT := PI * 0.49
const MIN_FRAME_RADIUS := 0.08
const FRAME_FILL := 0.75
const JOINT_COLOR := Color(0.78, 0.83, 0.90, 0.92)
const SELECTED_COLOR := Color(0.24, 0.78, 1.0)
const SHADOW_COLOR := Color(0.0, 0.0, 0.0, 0.72)
const FLY_KEYS: Dictionary[Key, Vector3] = {
	KEY_W: Vector3.FORWARD,
	KEY_S: Vector3.BACK,
	KEY_A: Vector3.LEFT,
	KEY_D: Vector3.RIGHT,
	KEY_Q: Vector3.DOWN,
	KEY_E: Vector3.UP,
}

var _camera: Camera3D
var _bones: Array[Node3D] = []
var _parents := PackedInt32Array()
var _active := false
var _selected := -1
var _hovered := -1
var _ui_scale := 1.0
var _points := PackedVector2Array()
var _depths := PackedFloat32Array()
var _pivot := Vector3.ZERO
var _has_pivot := false
var _navigation_button := MOUSE_BUTTON_NONE
var _panning := false
var _drag_zoom := false
var _fly_keys: Dictionary[Key, bool] = {}
var _fly_shift := false
var _fly_alt := false
var _fly_speed := 5.0
var _fly_sensitivity := 0.25
var _fly_invert_y := false
var _fly_distance := 1.0
var _mouse_before_fly := Vector2.ZERO
var _mouse_mode_before_fly := Input.MOUSE_MODE_VISIBLE


## Bind the separate pose camera and the joint hierarchy in preview order.
func configure(camera: Camera3D, bones: Array[Node3D], parents: PackedInt32Array) -> void:
	if camera == _camera and bones == _bones and parents == _parents:
		return
	_stop_freelook()
	_camera = camera
	_bones.assign(bones)
	_parents = parents.duplicate()
	_has_pivot = false
	_navigation_button = MOUSE_BUTTON_NONE
	_hovered = -1
	set_selected(-1)
	_update_input()


## Switch pointer ownership with the preview mode.
func set_active(active: bool) -> void:
	_active = active
	if not active:
		_stop_freelook()
		_navigation_button = MOUSE_BUTTON_NONE
		_leave()
		if has_focus():
			release_focus()
	_update_input()


## Highlight the same joint as the inspector's selection.
func set_selected(index: int) -> void:
	_selected = index if index >= 0 and index < _bones.size() else -1
	queue_redraw()


## Frame the selected joint and its immediate neighbors, or all joints.
func frame_target() -> void:
	if not _has_camera():
		return
	var bounds: Variant = _joint_bounds(_selected)
	if bounds == null:
		return
	_pivot = bounds.get_center()
	_has_pivot = true
	var radius := maxf(bounds.size.length() * 0.5, MIN_FRAME_RADIUS)
	var aspect := _viewport_aspect()
	var tight_axis := minf(1.0, aspect if _camera.keep_aspect == Camera3D.KEEP_HEIGHT else 1.0 / aspect)
	var offset := _camera.global_basis.z.normalized()
	var distance := maxf(2.0 * _camera.near, radius + _camera.near)
	if _camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		_camera.size = 2.0 * radius / (tight_axis * FRAME_FILL)
		distance = maxf(distance, _camera.global_position.distance_to(_pivot))
	else:
		var tangent := tan(deg_to_rad(_camera.fov) * 0.5) * tight_axis * FRAME_FILL
		distance = maxf(distance, radius / sin(atan(tangent)))
	_set_camera_position(_pivot + offset * distance)


func _ready() -> void:
	clip_contents = true
	set_process_input(false)
	if Engine.is_editor_hint():
		_ui_scale = EditorInterface.get_editor_scale()
		var settings := EditorInterface.get_editor_settings()
		_fly_speed = settings.get_setting("editors/3d/freelook/freelook_base_speed")
		_fly_sensitivity = settings.get_setting("editors/3d/freelook/freelook_sensitivity")
		_fly_invert_y = settings.get_setting("editors/3d/freelook/freelook_invert_y_axis")
	mouse_exited.connect(_leave)
	focus_exited.connect(_stop_freelook)
	visibility_changed.connect(_visibility_updated)
	_update_input()


func _process(delta: float) -> void:
	if _navigation_button == MOUSE_BUTTON_RIGHT:
		if _has_camera():
			_fly(delta)
		else:
			_stop_freelook()
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_EXIT_TREE:
		_stop_freelook()


func _leave() -> void:
	_hovered = -1
	mouse_default_cursor_shape = CURSOR_ARROW
	queue_redraw()


func _visibility_updated() -> void:
	if not is_visible_in_tree():
		_stop_freelook()
		_navigation_button = MOUSE_BUTTON_NONE
		_leave()
	_update_input()


func _has_camera() -> bool:
	return is_instance_valid(_camera) and _camera.is_inside_tree()


func _update_input() -> void:
	var enabled := _active and _has_camera() and is_visible_in_tree()
	mouse_filter = MOUSE_FILTER_PASS if enabled else MOUSE_FILTER_IGNORE
	focus_mode = FOCUS_CLICK if enabled else FOCUS_NONE
	set_process(enabled)
	queue_redraw()


func _draw() -> void:
	if not _active or not _has_camera():
		return
	_project_bones()
	for index in _points.size():
		var parent := _parent(index)
		if parent < 0 or not _in_front(index) or not _in_front(parent):
			continue
		var color := _joint_color(index)
		draw_line(_points[parent], _points[index], SHADOW_COLOR, 4.0 * _ui_scale, true)
		draw_line(_points[parent], _points[index], color, 1.8 * _ui_scale, true)
	for index in _points.size():
		if not _in_front(index):
			continue
		var radius := (5.0 if index == _selected or index == _hovered else 3.0) * _ui_scale
		draw_circle(_points[index], radius + _ui_scale, SHADOW_COLOR, true, -1.0, true)
		draw_circle(_points[index], radius, _joint_color(index), true, -1.0, true)
	var labeled := _hovered if _hovered >= 0 else _selected
	if _in_front(labeled) and Rect2(Vector2.ZERO, size).has_point(_points[labeled]):
		_draw_label(labeled)


func _draw_label(index: int) -> void:
	var label := String(_bones[index].name)
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var margin := 4.0 * _ui_scale
	var top_left := _points[index] + Vector2(9.0, -8.0) * _ui_scale
	top_left = top_left.clamp(Vector2.ZERO, (size - text_size - Vector2.ONE * 2.0 * margin).max(Vector2.ZERO))
	draw_rect(Rect2(top_left, text_size + Vector2.ONE * 2.0 * margin), SHADOW_COLOR)
	var baseline := top_left + Vector2(margin, margin + font.get_ascent(font_size))
	draw_string(font, baseline, label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, _joint_color(index))


func _joint_color(index: int) -> Color:
	if index == _selected:
		return SELECTED_COLOR
	return JOINT_COLOR.lightened(0.65) if index == _hovered else JOINT_COLOR


func _project_bones() -> void:
	_points.resize(_bones.size())
	_depths.resize(_bones.size())
	var viewport_size := _camera.get_viewport().get_visible_rect().size
	var scale := size / viewport_size.max(Vector2.ONE)
	var inverse := _camera.get_camera_transform().affine_inverse()
	for index in _bones.size():
		_points[index] = Vector2.INF
		_depths[index] = INF
		if not _bone_available(index):
			continue
		var position := _bones[index].global_position
		var depth := -(inverse * position).z
		if not is_finite(depth) or depth <= _camera.near or depth >= _camera.far:
			continue
		_points[index] = _camera.unproject_position(position) * scale
		_depths[index] = depth


func _parent(index: int) -> int:
	var parent := _parents[index] if index < _parents.size() else -1
	return parent if parent >= 0 and parent < _bones.size() and parent != index else -1


func _bone_available(index: int) -> bool:
	return index >= 0 and index < _bones.size() and is_instance_valid(_bones[index]) and _bones[index].is_inside_tree()


func _in_front(index: int) -> bool:
	return index >= 0 and index < _points.size() and _points[index].is_finite()


func _pick(point: Vector2) -> int:
	if not Rect2(Vector2.ZERO, size).has_point(point):
		return -1
	var picked := -1
	var best := pow(9.0 * _ui_scale, 2.0)
	for index in _points.size():
		if not _in_front(index):
			continue
		var distance := point.distance_squared_to(_points[index])
		if _closer(index, picked, distance, best):
			best = distance
			picked = index
	if picked >= 0:
		return picked
	best = pow(6.0 * _ui_scale, 2.0)
	for index in _points.size():
		var parent := _parent(index)
		if parent < 0 or not _in_front(index) or not _in_front(parent):
			continue
		if _points[parent].distance_squared_to(_points[index]) < 1.0:
			continue
		var on_segment := Geometry2D.get_closest_point_to_segment(point, _points[parent], _points[index])
		var distance := point.distance_squared_to(on_segment)
		if _closer(index, picked, distance, best):
			best = distance
			picked = index
	return picked


func _closer(index: int, picked: int, distance: float, best: float) -> bool:
	return distance < best or (picked >= 0 and is_equal_approx(distance, best) and _depths[index] < _depths[picked])


func _gui_input(event: InputEvent) -> void:
	if not _active or not _has_camera():
		return
	if event is InputEventMouseButton:
		_mouse_button(event)
	elif event is InputEventMouseMotion:
		_mouse_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F \
			and not event.alt_pressed and not event.ctrl_pressed and not event.meta_pressed and not event.shift_pressed:
		frame_target()
		accept_event()


func _input(event: InputEvent) -> void:
	# Capturing can place the system pointer outside this Control.
	if _navigation_button != MOUSE_BUTTON_RIGHT:
		return
	if not _has_camera():
		_stop_freelook()
		return
	if event is InputEventMouseMotion:
		_fly_look(event.screen_relative if event.screen_relative != Vector2.ZERO else event.relative)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed:
			_stop_freelook()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var direction := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			_fly_speed = clampf(_fly_speed * pow(1.18, event.factor * direction), 0.05, _camera.far)
	elif event is InputEventKey:
		var key: Key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
		_fly_shift = event.shift_pressed
		_fly_alt = event.alt_pressed
		if key in FLY_KEYS:
			_fly_keys[key] = event.pressed
		elif key == KEY_ESCAPE and event.pressed:
			_stop_freelook()
		elif key not in [KEY_SHIFT, KEY_ALT]:
			return
	else:
		return
	get_viewport().set_input_as_handled()


func _mouse_button(event: InputEventMouseButton) -> void:
	if not event.pressed:
		if _navigation_button != MOUSE_BUTTON_NONE and event.button_index == _navigation_button:
			_navigation_button = MOUSE_BUTTON_NONE
			accept_event()
		return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		if _navigation_button == MOUSE_BUTTON_NONE and _camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
			_start_freelook(event)
			accept_event()
	elif event.button_index == MOUSE_BUTTON_MIDDLE or (event.button_index == MOUSE_BUTTON_LEFT and event.alt_pressed):
		if _navigation_button == MOUSE_BUTTON_NONE:
			_ensure_pivot()
			_navigation_button = event.button_index
			_panning = event.shift_pressed
			_drag_zoom = event.ctrl_pressed
			_leave()
			grab_focus()
		accept_event()
	elif event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_ensure_pivot()
		_zoom(-event.factor if event.button_index == MOUSE_BUTTON_WHEEL_UP else event.factor)
		grab_focus()
		accept_event()
	elif event.button_index == MOUSE_BUTTON_LEFT:
		grab_focus()
		_project_bones()
		var hit := _pick(event.position)
		if hit >= 0:
			bone_selected.emit(hit)
			accept_event()


func _mouse_motion(event: InputEventMouseMotion) -> void:
	if _navigation_button != MOUSE_BUTTON_NONE:
		var button := MOUSE_BUTTON_MASK_MIDDLE if _navigation_button == MOUSE_BUTTON_MIDDLE else MOUSE_BUTTON_MASK_LEFT
		if event.button_mask & button:
			if _panning:
				_pan(event.relative)
			elif _drag_zoom:
				_zoom(event.relative.y * 0.05 / _ui_scale)
			else:
				_orbit(event.relative / _ui_scale)
			accept_event()
			return
		_navigation_button = MOUSE_BUTTON_NONE
	_project_bones()
	_hovered = _pick(event.position)
	mouse_default_cursor_shape = CURSOR_POINTING_HAND if _hovered >= 0 else CURSOR_ARROW


func _start_freelook(event: InputEventMouseButton) -> void:
	_ensure_pivot()
	_fly_distance = maxf(_camera.global_position.distance_to(_pivot), 2.0 * _camera.near)
	_fly_speed = maxf(_fly_speed, 0.05)
	_fly_shift = event.shift_pressed
	_fly_alt = event.alt_pressed
	for key in FLY_KEYS:
		if Input.is_physical_key_pressed(key):
			_fly_keys[key] = true
	_mouse_before_fly = get_viewport().get_mouse_position()
	_mouse_mode_before_fly = Input.mouse_mode
	_navigation_button = MOUSE_BUTTON_RIGHT
	_leave()
	grab_focus()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	set_process_input(true)


func _stop_freelook() -> void:
	if _navigation_button != MOUSE_BUTTON_RIGHT:
		return
	_navigation_button = MOUSE_BUTTON_NONE
	set_process_input(false)
	_fly_keys.clear()
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = _mouse_mode_before_fly
		if is_inside_tree() and _mouse_mode_before_fly != Input.MOUSE_MODE_CAPTURED:
			get_viewport().warp_mouse(_mouse_before_fly)


func _fly_look(pixels: Vector2) -> void:
	var angles := _camera.global_basis.get_euler()
	var sensitivity := deg_to_rad(_fly_sensitivity)
	var vertical := pixels.y if _fly_invert_y else -pixels.y
	angles.x = clampf(angles.x + vertical * sensitivity, -POLE_LIMIT, POLE_LIMIT)
	angles.y -= pixels.x * sensitivity
	_camera.global_basis = Basis.from_euler(Vector3(angles.x, angles.y, 0.0))
	_pivot = _camera.global_position - _camera.global_basis.z * _fly_distance


func _fly(delta: float) -> void:
	var direction := Vector3.ZERO
	for key in _fly_keys:
		if _fly_keys[key]:
			direction += FLY_KEYS[key]
	if direction == Vector3.ZERO:
		return
	var multiplier := (3.0 if _fly_shift else 1.0) / (3.0 if _fly_alt else 1.0)
	var offset := _camera.global_basis * direction * _fly_speed * multiplier * delta
	_camera.global_position += offset
	_pivot += offset


func _joint_bounds(selected: int) -> Variant:
	var bounds: Variant = null
	var local := _bone_available(selected)
	for index in _bones.size():
		if local and index != selected and index != _parent(selected) and _parent(index) != selected:
			continue
		if not _bone_available(index):
			continue
		var position := _bones[index].global_position
		if not position.is_finite():
			continue
		bounds = AABB(position, Vector3.ZERO) if bounds == null else bounds.expand(position)
	return bounds


func _ensure_pivot() -> void:
	if _has_pivot:
		return
	var bounds: Variant = _joint_bounds(-1)
	_pivot = bounds.get_center() if bounds != null else _camera.global_position - _camera.global_basis.z * 2.0
	_has_pivot = true


func _viewport_aspect() -> float:
	var viewport_size := _camera.get_viewport().get_visible_rect().size.max(Vector2.ONE)
	return viewport_size.x / viewport_size.y


func _orbit(pixels: Vector2) -> void:
	var offset := _camera.global_position - _pivot
	var distance := offset.length()
	if distance < _camera.near:
		distance = 2.0 * _camera.near
		offset = _camera.global_basis.z.normalized() * distance
	var yaw := atan2(offset.x, offset.z) - pixels.x * ORBIT_SPEED
	var elevation := clampf(asin(clampf(offset.y / distance, -1.0, 1.0)) + pixels.y * ORBIT_SPEED, -POLE_LIMIT, POLE_LIMIT)
	var planar := cos(elevation)
	var direction := Vector3(sin(yaw) * planar, sin(elevation), cos(yaw) * planar)
	_set_camera_position(_pivot + direction * distance)


func _pan(pixels: Vector2) -> void:
	var viewport_size := _camera.get_viewport().get_visible_rect().size.max(Vector2.ONE)
	var inverse := _camera.get_camera_transform().affine_inverse()
	var distance := maxf(-(inverse * _pivot).z, _camera.near)
	var center := viewport_size * 0.5
	var source := _camera.project_position(center, distance)
	var target := _camera.project_position(center - pixels * viewport_size / size.max(Vector2.ONE), distance)
	var offset := target - source
	_camera.global_position += offset
	_pivot += offset


func _zoom(scroll: float) -> void:
	var factor := pow(1.18, scroll)
	if _camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		_camera.size = clampf(_camera.size * factor, 0.02, _camera.far)
		return
	var offset := _camera.global_position - _pivot
	var distance := maxf(offset.length(), _camera.near)
	var direction := offset.normalized() if not offset.is_zero_approx() else _camera.global_basis.z.normalized()
	_set_camera_position(_pivot + direction * clampf(distance * factor, 2.0 * _camera.near, 0.9 * _camera.far))


func _set_camera_position(position: Vector3) -> void:
	_camera.global_position = position
	var offset := position - _pivot
	var up := Vector3.FORWARD if absf(offset.normalized().dot(Vector3.UP)) > 0.999 else Vector3.UP
	_camera.look_at(_pivot, up)
	queue_redraw()
