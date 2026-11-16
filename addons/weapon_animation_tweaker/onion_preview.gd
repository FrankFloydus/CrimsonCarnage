@tool
extends Control
## Samples private animation poses and displays their weapons and skeletons in the preview.

class Ghost:
	var root: Node3D
	var material: StandardMaterial3D
	var meshes: Array[MeshInstance3D] = []
	var mesh_available := PackedByteArray()
	var joints := PackedVector3Array()
	var joint_changed := PackedByteArray()
	var color := Color.WHITE
	var clip: Animation
	var time := 0.0
	var camera_pose := Transform3D.IDENTITY
	var pose_mode := false
	var bones := false
	var model_revision := -1


var _viewport: SubViewport
var _source_camera: Camera3D
var _live_camera: Camera3D
var _sampler_root: Node3D
var _sample_camera: Camera3D
var _sampler: AnimationPlayer
var _library: AnimationLibrary
var _preview_root: Node3D

var _model_paths: Array[NodePath] = []
var _bone_paths: Array[NodePath] = []
var _parents := PackedInt32Array()
var _bind_nodes: Array[Node3D] = []
var _bind_transforms: Array[Transform3D] = []
var _bind_visibility := PackedByteArray()
var _live_models: Array[Node3D] = []
var _sample_models: Array[Node3D] = []
var _model_transforms: Array[Transform3D] = []
var _model_visibility := PackedByteArray()
var _model_revision := 0
var _live_meshes: Array[MeshInstance3D] = []
var _sample_meshes: Array[MeshInstance3D] = []
var _mesh_models := PackedInt32Array()
var _live_bones: Array[Node3D] = []
var _sample_bones: Array[Node3D] = []

var _clip_names: Dictionary[Animation, StringName] = {}
var _next_clip := 0
var _ghosts: Array[Ghost] = []
var _visible_count := 0
var _draw_bones := false
var _last_camera: Camera3D
var _last_camera_transform := Transform3D.IDENTITY
var _last_camera_projection := Projection()
var _last_control_size := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	clip_contents = true
	set_process(false)


## Connect the renderer to the live viewport and the authored bind pose.
## Model and bone paths are relative to the preview camera.
func configure(viewport: SubViewport, source_camera: Camera3D, live_camera: Camera3D,
		model_paths: Array[NodePath], bone_paths: Array[NodePath], bone_parents: PackedInt32Array) -> void:
	if _viewport == viewport and _source_camera == source_camera and _live_camera == live_camera \
			and _model_paths == model_paths and _bone_paths == bone_paths and _parents == bone_parents:
		return
	clear()
	_viewport = viewport
	_source_camera = source_camera
	_live_camera = live_camera
	_model_paths.assign(model_paths)
	_bone_paths.assign(bone_paths)
	_parents = bone_parents.duplicate()


## Display samples in back-to-front order. Each entry supplies clip, time, color,
## the fallback camera_pose, and optionally bones for clips with native tracks.
func set_layers(layers: Array[Dictionary], draw_bones: bool, differences_only: bool = false) -> void:
	_draw_bones = draw_bones
	_visible_count = 0
	if not layers.is_empty() and is_instance_valid(_viewport) and is_instance_valid(_source_camera) \
			and is_instance_valid(_live_camera):
		_prepare_sampler()
		# Edit is camera-local. Pose samples use the shared stage's world space.
		var alignment := Transform3D.IDENTITY if draw_bones else _live_camera.global_transform
		if _preview_root.global_transform != alignment:
			_preview_root.global_transform = alignment
		_sync_models()
		_sync_animations(layers)
		for layer in layers:
			var clip: Animation = layer.get("clip")
			if clip != null:
				_show_layer(clip, layer, differences_only)
	for index in range(_visible_count, _ghosts.size()):
		_ghosts[index].root.hide()
	set_process(_draw_bones and _visible_count > 0)
	queue_redraw()


## Release the private sampler and all of its preview drawables.
func clear() -> void:
	for node in [_sampler_root, _preview_root]:
		if is_instance_valid(node):
			node.hide()
			var parent: Node = node.get_parent()
			if parent != null:
				parent.remove_child(node)
			node.queue_free()
	_viewport = null
	_source_camera = null
	_live_camera = null
	_sampler_root = null
	_sample_camera = null
	_sampler = null
	_library = null
	_preview_root = null
	_model_paths.clear()
	_bone_paths.clear()
	_parents.clear()
	_bind_nodes.clear()
	_bind_transforms.clear()
	_bind_visibility.clear()
	_live_models.clear()
	_sample_models.clear()
	_model_transforms.clear()
	_model_visibility.clear()
	_model_revision = 0
	_live_meshes.clear()
	_sample_meshes.clear()
	_mesh_models.clear()
	_live_bones.clear()
	_sample_bones.clear()
	_clip_names.clear()
	_next_clip = 0
	_ghosts.clear()
	_visible_count = 0
	_draw_bones = false
	_last_camera = null
	set_process(false)
	queue_redraw()


func _prepare_sampler() -> void:
	if is_instance_valid(_sampler_root):
		return
	_sampler_root = Node3D.new()
	_sampler_root.name = "OnionSampler"
	_sampler_root.hide()
	_sample_camera = _source_camera.duplicate(0) as Camera3D
	_sample_camera.name = "PreviewCamera"
	_sample_camera.current = false
	_sample_camera.transform = Transform3D.IDENTITY
	_sampler_root.add_child(_sample_camera)
	_sampler = AnimationPlayer.new()
	_sampler.name = "OnionAnimationPlayer"
	_sampler.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_sampler.root_node = ^".."
	_library = AnimationLibrary.new()
	_sampler.add_animation_library(&"", _library)
	_sampler_root.add_child(_sampler)
	_viewport.add_child(_sampler_root)

	_preview_root = Node3D.new()
	_preview_root.name = "OnionGhosts"
	_viewport.add_child(_preview_root)
	_bind_nodes.assign(_sample_camera.find_children("*", "Node3D", true, false))
	for node in _bind_nodes:
		_bind_transforms.append(node.transform)
		_bind_visibility.append(int(node.visible))
	_bind_models()
	for path in _bone_paths:
		_live_bones.append(_live_camera.get_node_or_null(path) as Node3D)
		_sample_bones.append(_sample_camera.get_node_or_null(path) as Node3D)


func _bind_models() -> void:
	for path in _model_paths:
		var live_model := _live_camera.get_node_or_null(path) as Node3D
		var sample_model := _sample_camera.get_node_or_null(path) as Node3D
		if live_model == null or sample_model == null:
			continue
		var model_index := _sample_models.size()
		_live_models.append(live_model)
		_sample_models.append(sample_model)
		_model_transforms.append(live_model.transform)
		_model_visibility.append(int(live_model.visible))
		for node in sample_model.find_children("*", "MeshInstance3D", true, false):
			var sample_mesh := node as MeshInstance3D
			var live_mesh := live_model.get_node_or_null(sample_model.get_path_to(sample_mesh)) as MeshInstance3D
			if sample_mesh.mesh != null and live_mesh != null:
				_live_meshes.append(live_mesh)
				_sample_meshes.append(sample_mesh)
				_mesh_models.append(model_index)


func _sync_models() -> void:
	var changed := false
	for index in _live_models.size():
		var live := _live_models[index]
		var visibility := int(live.visible)
		if live.transform != _model_transforms[index] or visibility != _model_visibility[index]:
			_model_transforms[index] = live.transform
			_model_visibility[index] = visibility
			changed = true
	if changed:
		_model_revision += 1


func _sync_animations(layers: Array[Dictionary]) -> void:
	var used: Dictionary[Animation, bool] = {}
	for layer in layers:
		var clip: Animation = layer.get("clip")
		if clip != null:
			used[clip] = true
	for clip: Animation in _clip_names.keys():
		if not used.has(clip):
			_library.remove_animation(_clip_names[clip])
			_clip_names.erase(clip)
	for clip in used:
		if not _clip_names.has(clip):
			var name := StringName("sample_%d" % _next_clip)
			_next_clip += 1
			_library.add_animation(name, clip)
			_clip_names[clip] = name


func _show_layer(clip: Animation, layer: Dictionary, differences_only: bool) -> void:
	var ghost := _obtain_ghost(_visible_count)
	_visible_count += 1
	var time := float(layer.get("time", 0.0))
	var camera_pose: Transform3D = layer.get("camera_pose", Transform3D.IDENTITY)
	var draw_joints := _draw_bones and bool(layer.get("bones", true))
	if ghost.clip != clip or ghost.time != time or ghost.camera_pose != camera_pose \
			or ghost.pose_mode != _draw_bones or ghost.bones != draw_joints or ghost.model_revision != _model_revision:
		_sample_ghost(ghost, clip, time, camera_pose, draw_joints)
	ghost.color = layer.get("color", Color(1.0, 1.0, 1.0, 0.45))
	if ghost.material.albedo_color != ghost.color:
		ghost.material.albedo_color = ghost.color
	_apply_difference_visibility(ghost, differences_only)
	ghost.root.show()


func _sample_ghost(ghost: Ghost, clip: Animation, time: float, camera_pose: Transform3D, draw_joints: bool) -> void:
	for index in _bind_nodes.size():
		var node := _bind_nodes[index]
		if node.transform != _bind_transforms[index]:
			node.transform = _bind_transforms[index]
		if node.visible != bool(_bind_visibility[index]):
			node.visible = bool(_bind_visibility[index])
	for index in _sample_models.size():
		_sample_models[index].transform = _model_transforms[index]
		_sample_models[index].visible = bool(_model_visibility[index])
	_sample_camera.transform = camera_pose
	_sampler.play(_clip_names[clip], 0.0)
	_sampler.seek(time, true, true)

	var alignment := Transform3D.IDENTITY if _draw_bones else _sample_camera.global_transform.affine_inverse()
	for index in _sample_meshes.size():
		var sample := _sample_meshes[index]
		var visible_model := bool(_model_visibility[_mesh_models[index]])
		var available := visible_model and _visible_from_camera(sample)
		ghost.mesh_available[index] = int(available)
		if available:
			ghost.meshes[index].transform = alignment * sample.global_transform

	ghost.joints.clear()
	if draw_joints:
		for sample in _sample_bones:
			ghost.joints.append(sample.global_position if sample != null else Vector3.INF)
	ghost.joint_changed.resize(ghost.joints.size())
	ghost.clip = clip
	ghost.time = time
	ghost.camera_pose = camera_pose
	ghost.pose_mode = _draw_bones
	ghost.bones = draw_joints
	ghost.model_revision = _model_revision


func _apply_difference_visibility(ghost: Ghost, differences_only: bool) -> void:
	for index in ghost.meshes.size():
		var live := _live_meshes[index]
		var result := ghost.meshes[index]
		var unchanged := differences_only and live.is_visible_in_tree() \
				and result.global_transform.is_equal_approx(live.global_transform)
		result.visible = bool(ghost.mesh_available[index]) and not unchanged
	for index in ghost.joints.size():
		var live := _live_bones[index]
		var point := ghost.joints[index]
		var moved := not differences_only or live == null or not point.is_equal_approx(live.global_position)
		ghost.joint_changed[index] = int(moved)


func _visible_from_camera(node: Node3D) -> bool:
	var ancestor: Node = node
	while ancestor != null and ancestor != _sample_camera:
		if ancestor is Node3D and not ancestor.visible:
			return false
		ancestor = ancestor.get_parent()
	return true


func _obtain_ghost(index: int) -> Ghost:
	if index < _ghosts.size():
		return _ghosts[index]
	var ghost := Ghost.new()
	ghost.root = Node3D.new()
	ghost.root.name = "OnionSample%d" % (index + 1)
	ghost.root.hide()
	_preview_root.add_child(ghost.root)
	ghost.material = StandardMaterial3D.new()
	ghost.material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost.material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost.material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	ghost.material.disable_fog = true
	ghost.material.render_priority = -12 + index
	for live in _live_meshes:
		var copy := MeshInstance3D.new()
		copy.mesh = live.mesh
		copy.layers = live.layers
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		copy.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		copy.material_override = ghost.material
		ghost.root.add_child(copy)
		ghost.meshes.append(copy)
	ghost.mesh_available.resize(ghost.meshes.size())
	_ghosts.append(ghost)
	return ghost


func _process(_delta: float) -> void:
	var camera := _viewport.get_camera_3d() if is_instance_valid(_viewport) else null
	if camera == null:
		return
	var transform := camera.get_camera_transform()
	var projection := camera.get_camera_projection()
	if camera != _last_camera or transform != _last_camera_transform \
			or projection != _last_camera_projection or size != _last_control_size:
		_last_camera = camera
		_last_camera_transform = transform
		_last_camera_projection = projection
		_last_control_size = size
		queue_redraw()


func _draw() -> void:
	if not _draw_bones or _visible_count == 0 or not is_instance_valid(_viewport):
		return
	var camera := _viewport.get_camera_3d()
	if camera == null:
		return
	var scale := size / _viewport.get_visible_rect().size.max(Vector2.ONE)
	var inverse := camera.get_camera_transform().affine_inverse()
	for index in _visible_count:
		_draw_ghost_skeleton(_ghosts[index], camera, inverse, scale)


func _draw_ghost_skeleton(ghost: Ghost, camera: Camera3D, inverse: Transform3D, scale: Vector2) -> void:
	var points := PackedVector2Array()
	points.resize(ghost.joints.size())
	for index in ghost.joints.size():
		var point := ghost.joints[index]
		var depth := -(inverse * point).z if point.is_finite() else INF
		points[index] = camera.unproject_position(point) * scale if depth > camera.near and depth < camera.far else Vector2.INF
	for index in points.size():
		var parent := _parents[index] if index < _parents.size() else -1
		if parent < 0 or parent >= points.size() or not points[parent].is_finite() or not points[index].is_finite():
			continue
		if _show_joint(ghost, index) or _show_joint(ghost, parent):
			draw_line(points[parent], points[index], ghost.color, 1.8, true)
	for index in points.size():
		if points[index].is_finite() and _show_joint(ghost, index):
			draw_circle(points[index], 2.6, ghost.color, true, -1.0, true)


func _show_joint(ghost: Ghost, index: int) -> bool:
	return ghost.joint_changed[index] != 0
