extends RefCounted
## Packs independent radial coatings and binds them to runtime materials in one World3D.

const MaterialSlot = preload("res://addons/dynamic_sky/surfaces/weather_material_slot.gd")
const FIELD := &"dynamic_sky_radial_material_field"
const ENABLED := &"dynamic_sky_radial_material_enabled"
const MAX_CELLS := 8
const WIDTH := 1 + MAX_CELLS * 2
const RECONCILE_SECONDS := 0.25

var _world: World3D
var _image: Image
var _texture: ImageTexture
var _payload := PackedVector4Array()
var _bound: Dictionary[RefCounted, bool]
var _compatible: Dictionary[int, bool]
var _elapsed := RECONCILE_SECONDS


func update(host: Node3D, weather: RefCounted, candidates: Dictionary, delta: float, active: bool) -> void:
	var storms: Array = weather.get_radial_storms() if active else []
	if storms.is_empty():
		clear()
		return
	var world := host.get_world_3d()
	if _world != world:
		clear()
		_world = world
	var origin := Vector2(host.global_position.x, host.global_position.z)
	var rows := PackedVector4Array([Vector4(origin.x, origin.y, 0.0, 0.0)])
	var remaining := MAX_CELLS
	for index in range(storms.size() - 1, -1, -1):
		var storm: Node3D = storms[index]
		if not storm.apply_material_state or not storm.global_position.is_finite():
			continue
		var position := Vector2(storm.global_position.x, storm.global_position.z) - origin
		var radius: float = storm.outer_radius
		var target: Vector3 = storm.get_material_state()
		# Keep the highest-priority valid storms, then apply them in ascending order.
		rows.insert(1, Vector4(target.x, target.y, target.z, storm.get_effective_alpha()))
		rows.insert(1, Vector4(position.x, position.y, radius, radius * storm.inner_radius_fraction))
		remaining -= 1
		if remaining == 0:
			break
	var count := MAX_CELLS - remaining
	rows[0].z = float(count)
	rows.resize(WIDTH)
	var changed_presence := _payload.is_empty() or _payload[0].z != float(count)
	if count > 0 and rows != _payload:
		_upload(rows)
	_payload = rows
	_elapsed += maxf(delta, 0.0)
	if changed_presence or _elapsed >= RECONCILE_SECONDS:
		_elapsed = 0.0
		_reconcile(candidates, count > 0)


func manages_accumulation(geometry: GeometryInstance3D) -> bool:
	return is_instance_valid(geometry) and _compatible.has(geometry.get_instance_id())


func clear() -> void:
	for slot in _bound:
		_release(slot)
	_bound.clear()
	_compatible.clear()
	_payload.clear()
	_world = null
	_elapsed = RECONCILE_SECONDS


func _upload(rows: PackedVector4Array) -> void:
	if _image == null:
		_image = Image.create_empty(WIDTH, 1, false, Image.FORMAT_RGBAF)
	for index in WIDTH:
		var row := rows[index]
		_image.set_pixel(index, 0, Color(row.x, row.y, row.z, row.w))
	if _texture == null:
		_texture = ImageTexture.create_from_image(_image)
	else:
		_texture.update(_image)


func _reconcile(candidates: Dictionary, use_field: bool) -> void:
	var active_slots: Dictionary[RefCounted, bool]
	_compatible.clear()
	for reference: WeakRef in candidates.values():
		var geometry := reference.get_ref() as MeshInstance3D
		if (
			geometry == null or not geometry.is_inside_tree() or geometry.get_world_3d() != _world
			or geometry.mesh == null
		):
			continue
		if geometry.material_override != null:
			_register(geometry, MaterialSlot.WHOLE_OVERRIDE, use_field, active_slots)
		else:
			for index in geometry.mesh.get_surface_count():
				_register(geometry, index, use_field, active_slots)
	for slot in _bound:
		if not active_slots.has(slot):
			_release(slot)
	_bound = active_slots


func _register(
	geometry: MeshInstance3D, index: int, use_field: bool, active_slots: Dictionary[RefCounted, bool],
) -> void:
	var authored := MaterialSlot.get_authored(geometry, index)
	if not _accepts(authored):
		return
	if not use_field:
		_compatible[geometry.get_instance_id()] = true
		return
	var slot := MaterialSlot.acquire(geometry, index, get_instance_id())
	if slot == null:
		return
	var bound_texture: Variant = slot.local.get_shader_parameter(FIELD)
	if bound_texture != null and bound_texture != _texture:
		slot.release(get_instance_id())
		return
	_compatible[geometry.get_instance_id()] = true
	if bound_texture == null:
		slot.local.set_shader_parameter(FIELD, _texture)
		slot.local.set_shader_parameter(ENABLED, true)
	active_slots[slot] = true


func _accepts(material: ShaderMaterial) -> bool:
	if (
		material == null or material.shader == null or material.get_shader_parameter(FIELD) != null
		or material.get_shader_parameter(&"dynamic_sky_weather_enabled") == false
	):
		return false
	for uniform in material.shader.get_shader_uniform_list():
		if uniform.name == FIELD and uniform.type == TYPE_OBJECT:
			return true
	return false


func _release(slot: RefCounted) -> void:
	if slot.local.get_shader_parameter(FIELD) == _texture:
		slot.local.set_shader_parameter(ENABLED, false)
		slot.local.set_shader_parameter(FIELD, null)
	slot.release(get_instance_id())
