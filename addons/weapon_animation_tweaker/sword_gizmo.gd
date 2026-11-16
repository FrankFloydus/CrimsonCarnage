@tool
extends Control
## Shows move and rotate handles for a sword in the isolated preview viewport.

signal drag_started
signal drag_ended
signal move_dragged(axis: int, amount: float)
signal rotate_dragged(axis: int, degrees: float)

const MOVE := 0
const ROTATE := 1
const HIDE := 2
const RING_SEGMENTS := 64
const AXIS_THEME_COLORS: Array[StringName] = [&"axis_x_color", &"axis_y_color", &"axis_z_color"]
const AXIS_COLORS: Array[Color] = [Color(0.96, 0.30, 0.33), Color(0.54, 0.86, 0.32), Color(0.35, 0.64, 1.0)]

var _camera: Camera3D
var _socket: Node3D
var _sword: Node3D
var _mode := MOVE
var _handles: Array[PackedVector2Array] = []
var _world_axes: Array[Vector3] = []
var _pivot := Vector3.ZERO
var _screen_shift := Vector2.ZERO
var _radius := 0.0
var _ui_scale := 1.0
var _hovered := -1

var _drag_axis := -1
var _drag_position := Vector2.ZERO
var _drag_tangent := Vector2.ZERO
var _drag_shift := Vector2.ZERO
var _drag_size := Vector2.ZERO
var _drag_camera := Transform3D.IDENTITY
var _drag_clip_inverse := Projection()
var _drag_pivot := Vector3.ZERO
var _drag_axes: Array[Vector3] = []
var _drag_reference := 0.0
var _drag_last_angle := 0.0
var _drag_angle := 0.0
var _drag_uses_plane := false
var _last_amount := 0.0


## Set the preview camera, animated socket, and selected sword within that socket.
func configure(camera: Camera3D, socket: Node3D, sword: Node3D) -> void:
	if camera != _camera or socket != _socket or sword != _sword:
		_finish_drag()
		_camera = camera
		_socket = socket
		_sword = sword
		_hovered = -1
	_update_processing()
	queue_redraw()


## Choose move (0), rotate (1), or hidden (2).
func set_mode(index: int) -> void:
	if index < MOVE or index > HIDE or index == _mode:
		return
	_finish_drag()
	_mode = index
	_hovered = -1
	_update_processing()
	queue_redraw()


func _ready() -> void:
	clip_contents = true
	if Engine.is_editor_hint():
		_ui_scale = EditorInterface.get_editor_scale()
	mouse_exited.connect(_clear_hover)
	visibility_changed.connect(_visibility_updated)
	_update_processing()


func _process(_delta: float) -> void:
	queue_redraw()


func _visibility_updated() -> void:
	if not is_visible_in_tree():
		_finish_drag()
		_clear_hover()
	_update_processing()


func _update_processing() -> void:
	var active := _mode != HIDE and is_instance_valid(_camera) and is_instance_valid(_socket) \
			and is_instance_valid(_sword) and is_visible_in_tree()
	set_process(active)
	mouse_filter = MOUSE_FILTER_PASS if active else MOUSE_FILTER_IGNORE


func _clear_hover() -> void:
	_hovered = -1
	mouse_default_cursor_shape = CURSOR_ARROW
	queue_redraw()


func _draw() -> void:
	_project_handles()
	for axis in _handles.size():
		var path := _handles[axis]
		if path.size() < 2:
			continue
		var color := AXIS_COLORS[axis]
		if has_theme_color(AXIS_THEME_COLORS[axis], &"Editor"):
			color = get_theme_color(AXIS_THEME_COLORS[axis], &"Editor")
		var selected := axis == _drag_axis or axis == _hovered
		if selected:
			color = color.lightened(0.30)
		var width := (3.2 if selected else 2.3) * _ui_scale
		draw_polyline(path, Color(0.0, 0.0, 0.0, 0.8), width + 2.0 * _ui_scale, true)
		draw_polyline(path, color, width, true)
		if _mode == MOVE:
			var tip := path[1]
			var direction := (tip - path[0]).normalized()
			var base := tip - direction * (9.0 * _ui_scale)
			var side := direction.orthogonal() * (4.5 * _ui_scale)
			var arrow := PackedVector2Array([tip, base + side, base - side])
			draw_colored_polygon(arrow, color)
			arrow.append(tip)
			draw_polyline(arrow, Color(0.0, 0.0, 0.0, 0.8), _ui_scale, true)


func _project_handles() -> void:
	_handles.clear()
	_world_axes.clear()
	if _mode == HIDE or not is_instance_valid(_camera) or not is_instance_valid(_socket) \
			or not is_instance_valid(_sword) or not _camera.is_inside_tree() or not _sword.is_visible_in_tree():
		return
	var viewport_size := _camera.get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0 or size.x < 18.0 or size.y < 18.0:
		return
	var camera_transform := _camera.get_camera_transform()
	_pivot = _sword.global_position
	var depth := -(camera_transform.affine_inverse() * _pivot).z
	if not is_finite(depth) or depth <= _camera.near + 0.0001 or depth >= _camera.far:
		return
	var pixels := minf((54.0 if _mode == MOVE else 43.0) * _ui_scale, minf(size.x, size.y) * 0.24)
	var center := _camera.unproject_position(_pivot)
	if not center.is_finite():
		return
	var overlay_scale := size / viewport_size
	var offset := _camera.project_position(center + Vector2(pixels / overlay_scale.x, 0.0), depth)
	var projected_radius := offset.distance_to(_pivot)
	# Keep the complete ring and all arrows in front of the near plane.
	_radius = minf(projected_radius, 0.45 * minf(depth - _camera.near, _camera.far - depth))
	if not is_finite(_radius) or _radius <= 0.0:
		return
	center *= overlay_scale
	# The first-person grip can be outside the picture while its blade is visible.
	# Shift the handles as a group, then remove that shift when solving the drag.
	var margin := Vector2.ONE * minf(pixels * 1.35, minf(size.x, size.y) * 0.44)
	_screen_shift = center.clamp(margin, size - margin) - center
	var screen_center := center + _screen_shift
	var basis := _socket.global_basis
	if _mode == ROTATE:
		# A local rotation uses the selected node's axes, including its current pose.
		# Move still uses the socket basis, whose scale maps offsets to world units.
		var world_pose := _sword.global_basis
		if not world_pose.is_finite() or absf(world_pose.determinant()) < 1.0e-12:
			return
		basis = Basis(world_pose.get_rotation_quaternion())
	_world_axes = [basis.x, basis.y, basis.z]
	if _world_axes.any(func(axis: Vector3) -> bool: return not axis.is_finite() or axis.length_squared() < 1.0e-12):
		return
	for axis in 3:
		var path := PackedVector2Array()
		if _mode == MOVE:
			var world_tip := _pivot + _world_axes[axis].normalized() * _radius
			var tip := _camera.unproject_position(world_tip) * overlay_scale + _screen_shift
			var direction := (tip - screen_center).normalized()
			if tip.is_finite() and tip.distance_to(screen_center) >= 10.0 * _ui_scale:
				path = PackedVector2Array([screen_center + direction * 5.0 * _ui_scale, tip])
		else:
			var first := _world_axes[(axis + 1) % 3].normalized()
			var second := _world_axes[(axis + 2) % 3].normalized()
			for index in RING_SEGMENTS + 1:
				var angle := TAU * index / RING_SEGMENTS
				var world_point := _pivot + (first * cos(angle) + second * sin(angle)) * _radius
				path.append(_camera.unproject_position(world_point) * overlay_scale + _screen_shift)
		_handles.append(path)


func _gui_input(event: InputEvent) -> void:
	if _mode == HIDE:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.alt_pressed:
				return
			_project_handles()
			var hit := _hit_handle(event.position)
			if hit.x >= 0 and _begin_drag(hit, event.position):
				accept_event()
		elif _drag_axis >= 0:
			accept_event()
			_update_drag(event.position)
			_finish_drag()
	elif event is InputEventMouseMotion:
		if _drag_axis >= 0:
			accept_event()
			if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
				_update_drag(event.position)
			else:
				_finish_drag()
		else:
			_hovered = _hit_handle(event.position).x
			mouse_default_cursor_shape = CURSOR_POINTING_HAND if _hovered >= 0 else CURSOR_ARROW
			queue_redraw()


func _hit_handle(mouse: Vector2) -> Vector2i:
	var hit := Vector2i(-1, -1)
	var nearest := pow(8.0 * _ui_scale, 2.0)
	for axis in _handles.size():
		var path := _handles[axis]
		for segment in path.size() - 1:
			if path[segment].distance_squared_to(path[segment + 1]) < 0.01:
				continue
			var point := Geometry2D.get_closest_point_to_segment(mouse, path[segment], path[segment + 1])
			var distance := point.distance_squared_to(mouse)
			if distance < nearest:
				nearest = distance
				hit = Vector2i(axis, segment)
	return hit


func _begin_drag(hit: Vector2i, mouse: Vector2) -> bool:
	_drag_size = size
	_drag_shift = _screen_shift
	_drag_camera = _camera.get_camera_transform()
	_drag_clip_inverse = _camera.get_camera_projection().inverse()
	_drag_pivot = _pivot
	_drag_axes = _world_axes.duplicate()
	_drag_position = mouse
	_drag_angle = 0.0
	_last_amount = 0.0
	var path := _handles[hit.x]
	if _mode == MOVE:
		_drag_reference = _axis_distance(mouse, hit.x)
		if not is_finite(_drag_reference):
			return false
	else:
		_drag_tangent = (path[hit.y + 1] - path[hit.y]) * (RING_SEGMENTS / TAU)
		_drag_last_angle = _ring_angle(mouse, hit.x)
		_drag_uses_plane = is_finite(_drag_last_angle)
		if not _drag_uses_plane and _drag_tangent.length_squared() < 1.0:
			return false
	_drag_axis = hit.x
	drag_started.emit()
	return true


func _ray(mouse: Vector2) -> PackedVector3Array:
	var uv := (mouse - _drag_shift) / _drag_size
	var normalized := Vector2(2.0 * uv.x - 1.0, 1.0 - 2.0 * uv.y)
	var sample_a := _drag_clip_inverse * Vector4(normalized.x, normalized.y, -1.0, 1.0)
	var sample_b := _drag_clip_inverse * Vector4(normalized.x, normalized.y, 0.0, 1.0)
	var a := Vector3(sample_a.x, sample_a.y, sample_a.z) / sample_a.w
	var b := Vector3(sample_b.x, sample_b.y, sample_b.z) / sample_b.w
	return PackedVector3Array([_drag_camera * a, (_drag_camera.basis * (b - a)).normalized()])


func _axis_distance(mouse: Vector2, axis: int) -> float:
	var ray := _ray(mouse)
	var direction := _drag_axes[axis]
	var projected := direction.dot(ray[1])
	var denominator := direction.length_squared() - projected * projected
	if denominator < 1.0e-5 * direction.length_squared():
		return INF
	var delta := ray[0] - _drag_pivot
	return (direction.dot(delta) - projected * ray[1].dot(delta)) / denominator


func _ring_angle(mouse: Vector2, axis: int) -> float:
	var ray := _ray(mouse)
	var first := _drag_axes[(axis + 1) % 3].normalized()
	var second := _drag_axes[(axis + 2) % 3].normalized()
	var normal := first.cross(second).normalized()
	var denominator := normal.dot(ray[1])
	# Use the screen tangent for rings seen edge-on. A ray-plane intersection
	# at that angle would turn a one-pixel mouse movement into a large rotation.
	if absf(denominator) < 0.14:
		return INF
	var distance := normal.dot(_drag_pivot - ray[0]) / denominator
	var radial := ray[0] + ray[1] * distance - _drag_pivot
	if distance < 0.0 or radial.length_squared() < 1.0e-10:
		return INF
	return atan2(second.dot(radial), first.dot(radial))


func _update_drag(mouse: Vector2) -> void:
	var amount := 0.0
	if _mode == MOVE:
		amount = _axis_distance(mouse, _drag_axis) - _drag_reference
	elif _drag_uses_plane:
		var angle := _ring_angle(mouse, _drag_axis)
		if not is_finite(angle):
			return
		_drag_angle += wrapf(angle - _drag_last_angle, -PI, PI)
		_drag_last_angle = angle
		amount = rad_to_deg(_drag_angle)
	else:
		amount = rad_to_deg((mouse - _drag_position).dot(_drag_tangent) / _drag_tangent.length_squared())
	if not is_finite(amount) or is_equal_approx(amount, _last_amount):
		return
	_last_amount = amount
	if _mode == MOVE:
		move_dragged.emit(_drag_axis, amount)
	else:
		rotate_dragged.emit(_drag_axis, amount)


func _finish_drag() -> void:
	if _drag_axis >= 0:
		_drag_axis = -1
		drag_ended.emit()
