class_name BloodComponent
extends Node3D
## Add as a direct child of a hittable entity to play blood effects when it is struck.

const MAX_STAINS := 12
const VECTORS_PER_STAIN := 5
const BURST_SURFACE_SEARCH := 0.14
const BURST_SURFACE_INSET := 0.015
const STAIN_DECAL := preload("res://scenes/effects/blood_world_decal.tscn")

## Preset for spray, world deposits, and body stains. Empty uses Humanoid Blood.
@export var blood_profile: BloodProfile

@export_group("Body Stain Mesh")
## Optional skeleton that drives the mesh and its bone-attached collision bodies.
@export var skeleton: Skeleton3D
## Optional explicit stain receiver. Skinned meshes need the stain shader and bind coordinates.
@export var surface: MeshInstance3D

@export_storage var splatter_style: BloodSplatterStyle
@export_storage var stain_size := Vector2(0.34, 0.34)
@export_storage var stain_depth := 0.08
@export_storage var stain_strength := 0.95
@export_storage var stain_limit := MAX_STAINS

var _stains := PackedVector4Array()
var _stain_material: ShaderMaterial
var _stain_style: BloodSplatterStyle
var _rigid_stains: Array[Decal] = []
var _previous_mask := -1
var _previous_angle := 0.0


func _exit_tree() -> void:
	for decal in _rigid_stains:
		if is_instance_valid(decal):
			decal.hide()
			decal.queue_free()
	_rigid_stains.clear()


## Presents a confirmed hit on this target using its assigned blood profile.
func receive_hit(
		collider: CollisionObject3D, point: Vector3, normal: Vector3, direction: Vector3,
		source_exclusions: Array[RID] = []
) -> void:
	if not is_inside_tree() or not is_instance_valid(collider) or direction.is_zero_approx():
		return
	var target := get_parent()
	var presenter := BloodImpact3D.for_target(target)
	var profile := blood_profile if blood_profile != null else presenter.default_profile
	if is_instance_valid(skeleton):
		apply_blood_stain(collider, point, normal, direction, presenter.default_profile)
	elif profile != null:
		var mesh := _find_rigid_stain_mesh(target, collider)
		if mesh != null:
			_apply_rigid_stain(mesh, point, normal, direction, profile, presenter.default_profile)

	var origin := point
	if profile != null and profile.burst_scene != null:
		origin = resolve_blood_burst_origin(collider, point, normal)
	var excluded := source_exclusions.duplicate()
	if target is CollisionObject3D:
		excluded.append((target as CollisionObject3D).get_rid())
	for node in target.find_children("*", "CollisionObject3D", true, false):
		excluded.append((node as CollisionObject3D).get_rid())
	if not excluded.has(collider.get_rid()):
		excluded.append(collider.get_rid())
	presenter.play_hit(profile, point, origin, normal, direction, excluded)


func _find_rigid_stain_mesh(target: Node, collider: CollisionObject3D) -> MeshInstance3D:
	if is_instance_valid(surface):
		return surface if _is_rigid_stain_mesh(surface) else null
	var node: Node = collider
	while node != null:
		var mesh := node as MeshInstance3D
		if _is_rigid_stain_mesh(mesh):
			return mesh
		if node == target:
			break
		node = node.get_parent()

	var candidate: MeshInstance3D
	for child in target.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if _is_rigid_stain_mesh(mesh):
			if candidate != null:
				return null
			candidate = mesh
	return candidate


func _is_rigid_stain_mesh(mesh: MeshInstance3D) -> bool:
	return mesh != null and mesh.mesh != null and mesh.skin == null and mesh.is_visible_in_tree()


func _apply_rigid_stain(
		mesh: MeshInstance3D, point: Vector3, normal: Vector3, direction: Vector3,
		profile: BloodProfile, fallback_profile: BloodProfile
) -> void:
	if normal.is_zero_approx() or profile.stain_strength <= 0.0:
		return
	var style := profile.splatter_style
	if style == null and fallback_profile != null:
		style = fallback_profile.splatter_style
	if style == null:
		return
	var masks := style.masks
	var mask_index := style.pick_mask(_previous_mask, masks)
	if mask_index < 0:
		return
	_previous_mask = mask_index

	# Use the visible surface when the hit body is a slightly offset collision proxy.
	var depth := maxf(profile.stain_depth, 0.001)
	normal = normal.normalized()
	var triangles := mesh.mesh.generate_triangle_mesh()
	if triangles != null:
		var local_from_world := mesh.global_transform.affine_inverse()
		var offset := normal * maxf(depth, BURST_SURFACE_SEARCH)
		var hit := triangles.intersect_segment(local_from_world * (point + offset),
				local_from_world * (point - offset))
		if not hit.is_empty():
			point = mesh.global_transform * (hit.position as Vector3)
			var mesh_normal := (local_from_world.basis.transposed() * (hit.normal as Vector3)).normalized()
			normal = mesh_normal if mesh_normal.dot(normal) >= 0.0 else -mesh_normal

	var tangent := _sample_stain_tangent(style, normal, direction.normalized())
	var footprint := profile.stain_size * style.sample_size()
	var decal := STAIN_DECAL.instantiate() as Decal
	decal.texture_albedo = masks[mask_index]
	decal.texture_orm = style.compact_orm if mask_index == 0 else style.fan_orm
	decal.size = Vector3(maxf(footprint.x, 0.001), depth * 2.0, maxf(footprint.y, 0.001))
	var tint := style.sample_tint()
	tint.a *= profile.stain_strength
	decal.modulate = tint
	decal.cull_mask = mesh.layers
	mesh.add_child(decal, false, Node.INTERNAL_MODE_BACK)
	decal.global_transform = Transform3D(Basis(normal.cross(tangent), normal, tangent), point)
	decal.reset_physics_interpolation()

	for index in range(_rigid_stains.size() - 1, -1, -1):
		if not is_instance_valid(_rigid_stains[index]):
			_rigid_stains.remove_at(index)
	while _rigid_stains.size() >= clampi(profile.stain_limit, 1, MAX_STAINS):
		var oldest: Decal = _rigid_stains.pop_front()
		oldest.hide()
		oldest.queue_free()
	_rigid_stains.append(decal)


## Projects a hit onto the visible mesh in the struck bone's frame and starts the spray under it.
func resolve_blood_burst_origin(collider: CollisionObject3D, point: Vector3, normal: Vector3) -> Vector3:
	var outward := normal.normalized()
	if outward.is_zero_approx():
		return point
	var bone := _get_hit_bone(collider)
	if bone < 0 or not is_instance_valid(surface) or surface.mesh == null:
		return point - outward * BURST_SURFACE_INSET
	# Move the query through the bone into the mesh's cached bind-pose triangles.
	var triangles := surface.mesh.generate_triangle_mesh()
	if triangles != null:
		var bind_from_world := _get_bind_from_world(bone)
		var center := bind_from_world * point
		var offset := bind_from_world.basis * (outward * BURST_SURFACE_SEARCH)
		var hit := triangles.intersect_segment(center, center - offset)
		var other := triangles.intersect_segment(center, center + offset)
		if not other.is_empty() and (hit.is_empty() or
				center.distance_squared_to(other.position) < center.distance_squared_to(hit.position)):
			hit = other
		if not hit.is_empty():
			var skin_normal := (bind_from_world.basis.transposed() * (hit.normal as Vector3)).normalized()
			if skin_normal.dot(outward) < 0.0:
				skin_normal = -skin_normal
			return bind_from_world.affine_inverse() * hit.position - skin_normal * BURST_SURFACE_INSET
	return _get_burst_origin_inside_collider(collider, point, outward)


## Places one mark from a world-space contact on a bone-attached collider.
func apply_blood_stain(
		collider: CollisionObject3D, point: Vector3, normal: Vector3, direction: Vector3,
		fallback_profile: BloodProfile = null
) -> void:
	var profile := blood_profile
	if profile == null and splatter_style == null:
		profile = fallback_profile
	var style := splatter_style
	if profile != null and profile.splatter_style != null:
		style = profile.splatter_style
	elif style == null and fallback_profile != null:
		style = fallback_profile.splatter_style
	if surface == null or style == null:
		return
	var bone := _get_hit_bone(collider)
	if bone < 0 or normal.is_zero_approx():
		return

	var bind_from_world := _get_bind_from_world(bone)
	var center := bind_from_world * point
	var bind_normal := (bind_from_world.basis.inverse().transposed() * normal).normalized()
	var bind_direction := (bind_from_world.basis * direction).normalized()
	var masks := style.masks
	if masks[0] == null and masks[1] == null:
		return
	if _stain_material == null:
		if surface.mesh == null or surface.mesh.get_surface_count() == 0:
			return
		var source_material := surface.get_active_material(0) as ShaderMaterial
		if source_material == null:
			return
		_stain_material = source_material.duplicate() as ShaderMaterial
		if surface.material_override == null:
			surface.set_surface_override_material(0, _stain_material)
		else:
			surface.material_override = _stain_material
	if style != _stain_style:
		_set_stain_style(style, masks)

	var mask_index := style.pick_mask(_previous_mask, masks)
	if mask_index < 0 or mask_index > 1:
		return
	_previous_mask = mask_index
	var tangent := _sample_stain_tangent(style, bind_normal, bind_direction)
	var bitangent := bind_normal.cross(tangent).normalized()
	var size := (profile.stain_size if profile != null else stain_size) * style.sample_size()
	var depth := profile.stain_depth if profile != null else stain_depth
	var strength := profile.stain_strength if profile != null else stain_strength
	var limit := profile.stain_limit if profile != null else stain_limit
	var tint := style.sample_tint().srgb_to_linear()
	var keep_vectors := (clampi(limit, 1, MAX_STAINS) - 1) * VECTORS_PER_STAIN
	if _stains.size() > keep_vectors:
		_stains = _stains.slice(_stains.size() - keep_vectors)
	# The shader reads center, normal, tangent, bitangent, and tint in that order.
	_stains.append(Vector4(center.x, center.y, center.z, strength * tint.a))
	_stains.append(Vector4(bind_normal.x, bind_normal.y, bind_normal.z, maxf(depth, 0.001)))
	_stains.append(Vector4(tangent.x, tangent.y, tangent.z, maxf(size.y, 0.001)))
	_stains.append(Vector4(bitangent.x, bitangent.y, bitangent.z, maxf(size.x, 0.001)))
	_stains.append(Vector4(tint.r, tint.g, tint.b, float(mask_index)))
	_stain_material.set_shader_parameter(&"blood_stains", _stains)
	var count := floori(float(_stains.size()) / VECTORS_PER_STAIN)
	_stain_material.set_shader_parameter(&"blood_stain_count", count)


func _sample_stain_tangent(style: BloodSplatterStyle, normal: Vector3, direction: Vector3) -> Vector3:
	var tangent := direction.slide(normal)
	var head_on := tangent.length_squared() < 0.0625
	if head_on:
		var fallback := Vector3.UP if absf(normal.y) < 0.95 else Vector3.RIGHT
		tangent = fallback.slide(normal)
	_previous_angle = style.sample_angle(head_on, _previous_angle)
	return tangent.normalized().rotated(normal, _previous_angle)


func _set_stain_style(style: BloodSplatterStyle, masks: Array[Texture2D]) -> void:
	_stain_style = style
	# The shader has one mask pair per target, so earlier marks cannot use a different pair.
	_stains.clear()
	_previous_mask = -1
	_previous_angle = 0.0
	_stain_material.set_shader_parameter(&"splatter_compact", masks[0])
	_stain_material.set_shader_parameter(&"splatter_fan", masks[1])
	_stain_material.set_shader_parameter(&"splatter_compact_orm", style.compact_orm)
	_stain_material.set_shader_parameter(&"splatter_fan_orm", style.fan_orm)
	_stain_material.set_shader_parameter(&"use_compact_orm", style.compact_orm != null)
	_stain_material.set_shader_parameter(&"use_fan_orm", style.fan_orm != null)
	_stain_material.set_shader_parameter(&"wet_roughness", style.wet_roughness)


func _get_hit_bone(collider: CollisionObject3D) -> int:
	if not is_instance_valid(skeleton) or not is_instance_valid(collider):
		return -1
	var attachment := collider.get_parent() as BoneAttachment3D
	if attachment == null or attachment.get_parent() != skeleton:
		return -1
	var bone := attachment.get_bone_idx()
	return bone if bone >= 0 and bone < skeleton.get_bone_count() else -1


func _get_bind_from_world(bone: int) -> Transform3D:
	var world_from_bone := skeleton.global_transform * skeleton.get_bone_global_pose(bone)
	var mesh_from_skeleton := surface.global_transform.affine_inverse() * skeleton.global_transform
	return mesh_from_skeleton * skeleton.get_bone_global_rest(bone) * world_from_bone.affine_inverse()


func _get_burst_origin_inside_collider(
		collider: CollisionObject3D, point: Vector3, outward: Vector3
) -> Vector3:
	var closest := point - outward * BURST_SURFACE_INSET
	if not is_instance_valid(collider):
		return closest
	var closest_distance := INF
	for owner_id in collider.get_shape_owners():
		if collider.is_shape_owner_disabled(owner_id):
			continue
		var world_from_shape := collider.global_transform * collider.shape_owner_get_transform(owner_id)
		for shape_index in collider.shape_owner_get_shape_count(owner_id):
			var shape := collider.shape_owner_get_shape(owner_id, shape_index)
			var center := world_from_shape * shape.get_debug_mesh().get_aabb().get_center()
			var to_center := center - point
			var distance := to_center.length_squared()
			if to_center.dot(outward) < 0.0 and distance < closest_distance:
				closest = center
				closest_distance = distance
	return closest
