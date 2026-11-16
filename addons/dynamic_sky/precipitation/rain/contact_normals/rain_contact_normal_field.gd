extends Node3D
## Shares rain contacts with nearby opaque weather materials in the owning World3D.

const MaterialSlot = preload("res://addons/dynamic_sky/surfaces/weather_material_slot.gd")
const DRAW_SHADER = preload("res://addons/dynamic_sky/precipitation/rain/contact_normals/rain_contact_field_draw.gdshader")
const FIELD_SIZE_METRES: float = 8.0
const RECEIVER_MARGIN_METRES: float = 0.25
const HEIGHT_RANGE_METRES: float = 12.0
const FIELD_PARAMETER: StringName = &"rain_contact_field"
const GAIN_PARAMETER: StringName = &"rain_contact_gain"
const MAPPING_PARAMETER: StringName = &"rain_contact_mapping"
const WEATHER_ENABLED_PARAMETER: StringName = &"dynamic_sky_weather_enabled"

class Receiver extends RefCounted:
	var geometry: WeakRef
	var mesh: Mesh
	var slots: Dictionary[int, RefCounted]

var _receivers: Dictionary[int, Receiver]
var _source: GPUParticles3D
var _alias := RID()
var _mapping := Vector4.INF
var _strength: float
var _atlas_material: ShaderMaterial

@onready var _field: SubViewport = $Field
@onready var _camera: Camera3D = $Field/Camera3D


func _ready() -> void:
	_atlas_material = ShaderMaterial.new()
	_atlas_material.shader = DRAW_SHADER
	_atlas_material.set_shader_parameter(&"metres_per_texel", FIELD_SIZE_METRES / _field.size.x)
	_field.tree_exiting.connect(_release_alias)


func _exit_tree() -> void:
	deactivate()


## Follows the active camera and reuses the existing falling-drop contact simulation.
func update_contacts(
	source: GPUParticles3D,
	observer: Camera3D,
	candidates: Array[MeshInstance3D],
	strength: float,
) -> void:
	if not _can_activate(source, observer, strength) or candidates.is_empty():
		deactivate()
		return
	if _source != source:
		deactivate()
		_source = source

	var next_mapping := _observer_mapping(observer.get_camera_transform())
	var changed := next_mapping != _mapping or not is_equal_approx(strength, _strength)
	_mapping = next_mapping
	_strength = strength
	var half := FIELD_SIZE_METRES * 0.5 + RECEIVER_MARGIN_METRES
	var minimum := Vector3(_mapping.x - half, _mapping.w - HEIGHT_RANGE_METRES, _mapping.y - half)
	var bounds := AABB(minimum, Vector3(half * 2.0, HEIGHT_RANGE_METRES * 2.0, half * 2.0))
	_reconcile_receivers(candidates, bounds, changed)
	if _receivers.is_empty():
		deactivate()
		return

	if not _alias.is_valid():
		_alias = RenderingServer.instance_create2(source.get_base(), _field.find_world_3d().scenario)
		RenderingServer.instance_geometry_set_material_override(_alias, _atlas_material.get_rid())
		RenderingServer.instance_geometry_set_cast_shadows_setting(_alias, RenderingServer.SHADOW_CASTING_SETTING_OFF)
		_field.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if changed:
		_camera.global_position = Vector3(_mapping.x, _mapping.w + 13.0, _mapping.y)
		_atlas_material.set_shader_parameter(&"height_origin_m", _mapping.w)
	RenderingServer.instance_set_transform(_alias, source.global_transform)


## Releases the private draw and restores the material slots still owned by this field.
func deactivate() -> void:
	for receiver in _receivers.values():
		_restore_receiver(receiver)
	_receivers.clear()
	_release_alias()
	_source = null
	_mapping = Vector4.INF
	_strength = 0.0
	if is_instance_valid(_field):
		_field.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _can_activate(source: GPUParticles3D, observer: Camera3D, strength: float) -> bool:
	return (
		strength > 0.0 and is_node_ready() and is_instance_valid(source) and is_instance_valid(observer)
		and source.is_inside_tree() and observer.is_inside_tree()
		and source.get_world_3d() == get_world_3d() and observer.get_world_3d() == get_world_3d()
		and not source.local_coords and source.draw_order == GPUParticles3D.DRAW_ORDER_INDEX
		and source.transform_align == GPUParticles3D.TRANSFORM_ALIGN_DISABLED
	)


func _observer_mapping(view: Transform3D) -> Vector4:
	var step_m := FIELD_SIZE_METRES / _field.size.x
	var direction := Vector2(-view.basis.z.x, -view.basis.z.z).normalized()
	var center := Vector2(view.origin.x, view.origin.z) + direction * 1.75
	return Vector4(
		snappedf(center.x, step_m), snappedf(center.y, step_m), 1.0 / FIELD_SIZE_METRES,
		snappedf(view.origin.y, 0.125),
	)


func _reconcile_receivers(candidates: Array[MeshInstance3D], bounds: AABB, changed: bool) -> void:
	var seen: Dictionary[int, bool]
	var world := get_world_3d()
	for geometry in candidates:
		if (
			not is_instance_valid(geometry) or not geometry.is_inside_tree()
			or geometry.get_world_3d() != world or geometry.mesh == null or geometry.material_override != null
			or not geometry.is_visible_in_tree()
			or not bounds.intersects(geometry.global_transform * geometry.get_aabb().grow(0.01))
		):
			continue
		var identifier := geometry.get_instance_id()
		if seen.has(identifier):
			continue
		seen[identifier] = true
		var receiver := _receivers.get(identifier) as Receiver
		if receiver != null and receiver.mesh != geometry.mesh:
			_restore_receiver(receiver)
			receiver = null
			_receivers.erase(identifier)
		if receiver == null:
			receiver = Receiver.new()
			receiver.geometry = weakref(geometry)
			receiver.mesh = geometry.mesh
		_reconcile_slots(geometry, receiver, changed)
		if receiver.slots.is_empty():
			_receivers.erase(identifier)
		else:
			_receivers[identifier] = receiver
	for identifier in _receivers.keys():
		if not seen.has(identifier):
			_restore_receiver(_receivers[identifier])
			_receivers.erase(identifier)


func _reconcile_slots(geometry: MeshInstance3D, receiver: Receiver, changed: bool) -> void:
	var count := receiver.mesh.get_surface_count()
	for index in receiver.slots.keys():
		if index >= count:
			_clear_slot(receiver.slots[index])
			receiver.slots.erase(index)
	for index in count:
		var slot := receiver.slots.get(index) as RefCounted
		if slot != null:
			if slot.is_current():
				if changed:
					_apply_mapping(slot.local)
				continue
			_clear_slot(slot)
			receiver.slots.erase(index)
		var authored := MaterialSlot.get_authored(geometry, index)
		if not _accepts_field(authored):
			continue
		slot = MaterialSlot.acquire(geometry, index, get_instance_id())
		if slot == null:
			continue
		if slot.local.get_shader_parameter(FIELD_PARAMETER) != null:
			slot.release(get_instance_id())
			continue
		slot.local.set_shader_parameter(FIELD_PARAMETER, _field.get_texture())
		_apply_mapping(slot.local)
		receiver.slots[index] = slot


func _apply_mapping(material: ShaderMaterial) -> void:
	material.set_shader_parameter(GAIN_PARAMETER, _strength)
	material.set_shader_parameter(MAPPING_PARAMETER, _mapping)


func _accepts_field(material: ShaderMaterial) -> bool:
	if material == null or material.shader == null or material.get_shader_parameter(FIELD_PARAMETER) != null:
		return false
	var uniforms := {}
	for property in material.shader.get_shader_uniform_list():
		uniforms[property.name] = property.type
	return (
		uniforms.get(GAIN_PARAMETER) == TYPE_FLOAT and uniforms.get(MAPPING_PARAMETER) == TYPE_VECTOR4
		and uniforms.get(FIELD_PARAMETER) == TYPE_OBJECT
		and material.get_shader_parameter(WEATHER_ENABLED_PARAMETER) != false
	)


func _restore_receiver(receiver: Receiver) -> void:
	for slot in receiver.slots.values():
		_clear_slot(slot)


func _clear_slot(slot: RefCounted) -> void:
	slot.local.set_shader_parameter(GAIN_PARAMETER, slot.authored.get_shader_parameter(GAIN_PARAMETER))
	slot.local.set_shader_parameter(FIELD_PARAMETER, slot.authored.get_shader_parameter(FIELD_PARAMETER))
	slot.local.set_shader_parameter(MAPPING_PARAMETER, slot.authored.get_shader_parameter(MAPPING_PARAMETER))
	slot.release(get_instance_id())


func _release_alias() -> void:
	if _alias.is_valid():
		RenderingServer.free_rid(_alias)
		_alias = RID()
