extends RefCounted
## Shares one transient ShaderMaterial per effective geometry slot across weather effects.

const WHOLE_OVERRIDE := -1

var authored: ShaderMaterial
var local: ShaderMaterial
var _geometry: WeakRef
var _mesh: Mesh
var _index: int
var _previous: Material
var _users: Dictionary[int, bool]


static func get_authored(geometry: MeshInstance3D, index: int) -> ShaderMaterial:
	if not _can_use(geometry, index):
		return null
	var slot := _get_registered(geometry, index)
	if slot != null:
		if slot.is_current() and not slot._users.is_empty():
			return slot.authored
		slot._restore()
	return _get_assignment(geometry, index) as ShaderMaterial if index == WHOLE_OVERRIDE else geometry.get_active_material(index) as ShaderMaterial


static func acquire(geometry: MeshInstance3D, index: int, user: int) -> RefCounted:
	var material := get_authored(geometry, index)
	if material == null:
		return null
	var slot := _get_registered(geometry, index)
	if slot == null:
		# Load self by script path to keep this internal helper out of the global class list.
		slot = load("res://addons/dynamic_sky/surfaces/weather_material_slot.gd").new()
		slot._geometry = weakref(geometry)
		slot._mesh = geometry.mesh
		slot._index = index
		slot._previous = _get_assignment(geometry, index)
		slot.authored = material
		slot.local = material.duplicate() as ShaderMaterial
		geometry.set_meta(_key(index), slot)
		_set_assignment(geometry, index, slot.local)
	slot._users[user] = true
	return slot


func is_current() -> bool:
	var geometry := _geometry.get_ref() as MeshInstance3D
	if geometry == null or not _can_use(geometry, _index):
		return false
	if _get_registered(geometry, _index) != self or _get_assignment(geometry, _index) != local:
		return false
	return _index == WHOLE_OVERRIDE or (
		geometry.mesh == _mesh and (_previous != null or _mesh.surface_get_material(_index) == authored)
	)


func release(user: int) -> void:
	_users.erase(user)
	if _users.is_empty():
		_restore()


func _restore() -> void:
	var geometry := _geometry.get_ref() as MeshInstance3D
	if geometry == null or _get_registered(geometry, _index) != self:
		return
	var indexed_assignment := _index >= 0 and _index < geometry.get_surface_override_material_count()
	var still_owned := (_index == WHOLE_OVERRIDE or indexed_assignment) and _get_assignment(geometry, _index) == local
	if still_owned and indexed_assignment and geometry.mesh == null:
		# Godot retains indexed assignments while the mesh RID is empty, but cannot set one.
		if not geometry.property_list_changed.is_connected(_restore_after_mesh_change):
			geometry.property_list_changed.connect(_restore_after_mesh_change)
		return
	if geometry.property_list_changed.is_connected(_restore_after_mesh_change):
		geometry.property_list_changed.disconnect(_restore_after_mesh_change)
	geometry.remove_meta(_key(_index))
	if still_owned:
		_set_assignment(geometry, _index, _previous)


func _restore_after_mesh_change() -> void:
	_restore()


static func _can_use(geometry: MeshInstance3D, index: int) -> bool:
	return index == WHOLE_OVERRIDE or (
		geometry.material_override == null and geometry.mesh != null
		and index >= 0 and index < geometry.mesh.get_surface_count()
	)


static func _get_assignment(geometry: MeshInstance3D, index: int) -> Material:
	return geometry.material_override if index == WHOLE_OVERRIDE else geometry.get_surface_override_material(index)


static func _set_assignment(geometry: MeshInstance3D, index: int, material: Material) -> void:
	if index == WHOLE_OVERRIDE:
		geometry.material_override = material
	else:
		geometry.set_surface_override_material(index, material)


static func _get_registered(geometry: MeshInstance3D, index: int) -> RefCounted:
	var key := _key(index)
	return geometry.get_meta(key) as RefCounted if geometry.has_meta(key) else null


static func _key(index: int) -> StringName:
	return &"_dynamic_sky_weather_material_slot_override" if index == WHOLE_OVERRIDE else StringName("_dynamic_sky_weather_material_slot_%d" % index)
