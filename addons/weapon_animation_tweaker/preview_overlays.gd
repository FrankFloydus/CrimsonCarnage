@tool
extends RefCounted
## Owns socket markers and paths inside the tweaker's private preview.

const RIGHT_COLOR := Color(1.0, 0.65, 0.12)
const LEFT_COLOR := Color(0.20, 0.90, 0.96)
const KEY_METADATA: Array[StringName] = [&"right_socket_key_times", &"left_socket_key_times"]
const KEY_DOT_SHADER := """
shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, fog_disabled;

void vertex() {
	POINT_SIZE = 5.0;
}

void fragment() {
	if (distance(POINT_COORD, vec2(0.5)) > 0.5) {
		discard;
	}
	ALBEDO = COLOR.rgb;
	ALPHA = 1.0;
}
"""

var _player: AnimationPlayer
var _socket_paths: Array[NodePath] = []
var _draft: Animation
var _show_sockets := false
var _show_path := false
var _path_dirty := true
var _markers: Array[MeshInstance3D] = []
var _paths: Array[MeshInstance3D] = []
var _line_material: StandardMaterial3D
var _dot_material: ShaderMaterial


## Bind to the private player and its draft with paths relative to the player's root.
func configure(player: AnimationPlayer, socket_paths: Array[NodePath], draft: Animation) -> void:
	var stage_changed := _player != player or _socket_paths != socket_paths
	if stage_changed:
		clear()
		_player = player
		_socket_paths.assign(socket_paths)
		for index in _socket_paths.size():
			_add_marker(index)
	_draft = draft
	rebuild()
	_update_visibility()


## Toggle current-pose markers independently of the full clip path and key dots.
func set_visible(show_sockets: bool, show_path: bool) -> void:
	_show_sockets = show_sockets
	_show_path = show_path
	if _show_path and _path_dirty:
		rebuild()
	_update_visibility()


## Refresh the path after a draft edit. Seeking and playing need no rebuild.
func rebuild() -> void:
	_path_dirty = true
	if not _show_path:
		return
	_path_dirty = false
	_remove_nodes(_paths)
	if _draft == null or not is_instance_valid(_player):
		return
	for index in _socket_paths.size():
		_add_path(index)


## Detach every generated overlay node when the preview stage is released.
func clear() -> void:
	_remove_nodes(_markers)
	_remove_nodes(_paths)
	_player = null
	_socket_paths.clear()
	_draft = null
	_path_dirty = true


## Return the unique authored times for both selected sockets on the timeline.
## Clips without source metadata use their actual position and rotation keys.
static func key_times(draft: Animation, socket_paths: Array[NodePath]) -> PackedFloat64Array:
	var times := PackedFloat64Array()
	if draft == null:
		return times
	for index in socket_paths.size():
		if not socket_paths[index].is_empty():
			times.append_array(_socket_key_times(draft, socket_paths[index], _side(socket_paths[index], index)))
	return _sorted_unique(times, draft.length)


static func _side(path: NodePath, index: int) -> int:
	if not path.is_empty() and path.get_name_count() > 0:
		var name := String(path.get_name(path.get_name_count() - 1)).to_lower()
		if name.contains("left"):
			return 1
		if name.contains("right") or name == "weaponcontrol":
			return 0
	return mini(index, 1)


static func _socket_key_times(draft: Animation, path: NodePath, side: int) -> PackedFloat64Array:
	var times := PackedFloat64Array()
	var metadata := KEY_METADATA[side]
	if draft.has_meta(metadata):
		var authored: Variant = draft.get_meta(metadata)
		if authored is PackedFloat32Array or authored is PackedFloat64Array:
			for time: float in authored:
				times.append(time)
			return _sorted_unique(times, draft.length)
	for track in draft.get_track_count():
		if not draft.track_is_enabled(track):
			continue
		var track_path := draft.track_get_path(track)
		if NodePath(String(track_path.get_concatenated_names())) != path:
			continue
		match draft.track_get_type(track):
			Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D:
				_append_track_times(draft, track, times)
			Animation.TYPE_VALUE:
				var property := track_path.get_concatenated_subnames()
				if property in [&"position", &"rotation", &"rotation_degrees", &"quaternion", &"transform"]:
					_append_track_times(draft, track, times)
	return _sorted_unique(times, draft.length)


static func _append_track_times(draft: Animation, track: int, times: PackedFloat64Array) -> void:
	for key in draft.track_get_key_count(track):
		times.append(draft.track_get_key_time(track, key))


static func _sorted_unique(times: PackedFloat64Array, duration: float) -> PackedFloat64Array:
	var valid := PackedFloat64Array()
	for time: float in times:
		if is_finite(time) and time >= 0.0 and (time <= duration or is_equal_approx(time, duration)):
			valid.append(minf(time, duration))
	valid.sort()
	var result := PackedFloat64Array()
	for time: float in valid:
		if result.is_empty() or result[-1] != time:
			result.append(time)
	return result


func _mount(index: int) -> Node3D:
	if not is_instance_valid(_player) or _socket_paths[index].is_empty():
		return null
	var root := _player.get_node_or_null(_player.root_node)
	return root.get_node_or_null(_socket_paths[index]) as Node3D if root != null else null


func _add_marker(index: int) -> void:
	var mount := _mount(index)
	if mount == null:
		return
	var sphere := SphereMesh.new()
	sphere.radius = 0.014
	sphere.height = sphere.radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	var material := _unshaded_material(125)
	material.albedo_color = LEFT_COLOR if _side(_socket_paths[index], index) == 1 else RIGHT_COLOR
	sphere.material = material
	_markers.append(_attach_mesh(mount, sphere, mount.get_parent() as Camera3D))


func _add_path(index: int) -> void:
	var mount := _mount(index)
	if mount == null:
		return
	var parent := mount.get_parent_node_3d()
	if parent == null:
		return
	var path := _socket_paths[index]
	var track := _position_track(path)
	if track < 0:
		return
	var side := _side(path, index)
	var dots := _socket_key_times(_draft, path, side)
	var times := dots.duplicate()
	_append_track_times(_draft, track, times)
	times.append(0.0)
	times.append(_draft.length)
	var curve := _sample_positions(track, _sorted_unique(times, _draft.length))
	var points := _sample_positions(track, dots)
	if curve.size() < 2 and points.is_empty():
		return
	_ensure_path_materials()
	var mesh := ImmediateMesh.new()
	var color := LEFT_COLOR if side == 1 else RIGHT_COLOR
	if curve.size() >= 2:
		_add_surface(mesh, Mesh.PRIMITIVE_LINE_STRIP, _line_material, curve, color)
	if not points.is_empty():
		_add_surface(mesh, Mesh.PRIMITIVE_POINTS, _dot_material, points, color)
	_paths.append(_attach_mesh(parent, mesh, parent as Camera3D))


func _position_track(path: NodePath) -> int:
	for property in [":position", ":transform"]:
		var track := _draft.find_track(NodePath(String(path) + property), Animation.TYPE_VALUE)
		if track >= 0 and _draft.track_is_enabled(track) and _draft.track_get_key_count(track) > 0:
			return track
	var track := _draft.find_track(path, Animation.TYPE_POSITION_3D)
	return track if track >= 0 and _draft.track_is_enabled(track) and _draft.track_get_key_count(track) > 0 else -1


func _sample_positions(track: int, times: PackedFloat64Array) -> PackedVector3Array:
	var points := PackedVector3Array()
	var position_track := _draft.track_get_type(track) == Animation.TYPE_POSITION_3D
	for time: float in times:
		var position := Vector3.INF
		if position_track:
			position = _draft.position_track_interpolate(track, time)
		else:
			var value: Variant = _draft.value_track_interpolate(track, time)
			if value is Vector3:
				position = value
			elif value is Transform3D:
				position = value.origin
		if position.is_finite():
			points.append(position)
	return points


static func _unshaded_material(priority: int) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.no_depth_test = true
	material.disable_fog = true
	material.render_priority = priority
	return material


func _ensure_path_materials() -> void:
	if _line_material != null:
		return
	_line_material = _unshaded_material(126)
	_line_material.vertex_color_use_as_albedo = true
	var shader := Shader.new()
	shader.code = KEY_DOT_SHADER
	_dot_material = ShaderMaterial.new()
	_dot_material.shader = shader
	_dot_material.render_priority = 127


static func _attach_mesh(parent: Node3D, mesh: Mesh, camera: Camera3D) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	if camera != null:
		instance.layers = camera.cull_mask
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	parent.add_child(instance, false, Node.INTERNAL_MODE_BACK)
	return instance


static func _add_surface(mesh: ImmediateMesh, primitive: Mesh.PrimitiveType, material: Material,
		points: PackedVector3Array, color: Color) -> void:
	mesh.surface_begin(primitive, material)
	mesh.surface_set_color(color)
	for point in points:
		mesh.surface_add_vertex(point)
	mesh.surface_end()


func _update_visibility() -> void:
	for marker in _markers:
		if is_instance_valid(marker):
			marker.visible = _show_sockets
	for path in _paths:
		if is_instance_valid(path):
			path.visible = _show_path


static func _remove_nodes(nodes: Array[MeshInstance3D]) -> void:
	for overlay in nodes:
		if not is_instance_valid(overlay):
			continue
		var parent := overlay.get_parent()
		if parent != null:
			parent.remove_child(overlay)
		overlay.queue_free()
	nodes.clear()
