extends RefCounted
## Fits the visible weapon between the camera and nearby world collision.

const SEARCH_STEPS := 8

var _visuals: Node3D
var _weapon: Node3D
var _rest_transform: Transform3D
var _rest_visible: bool
var _mesh_bounds: AABB
var _has_bounds := false
var _scale := 1.0
var _box := BoxShape3D.new()
var _query := PhysicsShapeQueryParameters3D.new()
var _overlap := PhysicsIntersectShapeResult3D.new()


func _init() -> void:
	_query.shape = _box
	_overlap.max_intersections = 1


func set_visuals(visuals: Node3D) -> void:
	if _visuals != null:
		_visuals.transform = _rest_transform
		_visuals.visible = _rest_visible
	_visuals = visuals
	_has_bounds = false
	_scale = 1.0
	if _visuals == null:
		return

	_weapon = _visuals.get_parent_node_3d()
	_rest_transform = _visuals.transform
	_rest_visible = _visuals.visible
	var to_weapon := _weapon.global_transform.affine_inverse()
	for node in _visuals.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.mesh == null:
			continue
		var bounds := (to_weapon * mesh.global_transform) * mesh.get_aabb()
		_mesh_bounds = _mesh_bounds.merge(bounds) if _has_bounds else bounds
		_has_bounds = true

	# Publish the new weapon after checking its first pose in physics.
	if _has_bounds:
		_visuals.hide()


func update(
		delta: float,
		camera: Camera3D,
		collision_mask: int,
		padding: float,
		recovery_time: float,
		excluded: Array[RID]
) -> void:
	if not _has_bounds or not _rest_visible:
		return
	var camera_local := _weapon.to_local(camera.global_position)
	var limit := 1.0
	if collision_mask != 0:
		_query.collision_mask = collision_mask
		_query.exclude = excluded
		limit = _clear_scale(camera.global_position, camera_local, padding)

	# Pull inward immediately. Let the weapon ease back out as space opens up.
	var previous_scale := _scale
	_scale = limit
	if limit > previous_scale and recovery_time > 0.0 and collision_mask != 0:
		_scale = move_toward(previous_scale, limit, delta / recovery_time)
	var was_visible := _visuals.visible
	_visuals.visible = _scale > 0.0
	if _visuals.visible:
		_visuals.transform = Transform3D(
				_rest_transform.basis.scaled(Vector3.ONE * _scale),
				camera_local.lerp(_rest_transform.origin, _scale)
		)
	if _visuals.visible and (_scale < previous_scale or not was_visible):
		_visuals.reset_physics_interpolation()


func _clear_scale(camera_position: Vector3, camera_local: Vector3, padding: float) -> float:
	var space := _weapon.get_world_3d().direct_space_state
	# Include the camera so shrinking produces nested boxes and catches thin walls
	# even if the uncorrected blade has already passed through to the far side.
	var envelope := _mesh_bounds.expand(camera_local)
	var basis := _weapon.global_basis
	var size := envelope.size * basis.get_scale().abs()
	var center := _weapon.to_global(envelope.get_center())
	_query.transform = Transform3D(basis.orthonormalized(), center)
	var border := Vector3.ONE * (2.0 * padding)
	if not _overlaps(space, size + border, center):
		return 1.0

	var clear := 0.0
	var blocked := 1.0
	for index in SEARCH_STEPS:
		var test := (clear + blocked) * 0.5
		if _overlaps(space, size * test + border, camera_position.lerp(center, test)):
			blocked = test
		else:
			clear = test
	return clear


func _overlaps(space: PhysicsDirectSpaceState3D, size: Vector3, center: Vector3) -> bool:
	_box.size = size
	_query.transform.origin = center
	return space.intersect_shape_into(_query, _overlap)
