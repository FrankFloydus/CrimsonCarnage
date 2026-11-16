extends RefCounted
## Automatically supplies per-instance weather to compatible geometry in the root's World3D.

const RadialMaterialField = preload("res://addons/dynamic_sky/surfaces/radial_material_field.gd")
const PARAMETER := &"dynamic_sky_weather"
const MARKER := &"dynamic_sky_weather_enabled"
const DEFAULT_TEXTURES := {
	&"dynamic_sky_snow_albedo": "res://addons/dynamic_sky/surfaces/textures/snowpack_albedo.webp",
	&"dynamic_sky_snow_normal": "res://addons/dynamic_sky/surfaces/textures/snowpack_normal.webp",
	&"dynamic_sky_snow_orm": "res://addons/dynamic_sky/surfaces/textures/snowpack_orm.webp",
}

class SurfaceEntry extends RefCounted:
	var geometry: WeakRef
	var previous_value: Variant
	var state := Vector4.ZERO

var _radial_field := RadialMaterialField.new()
var _host: WeakRef
var _tree: SceneTree
var _enabled := false
var _refresh_seconds := 0.0
var _watched: Dictionary[int, WeakRef]
var _surfaces: Dictionary[int, SurfaceEntry]
var _rain_receivers: Array[MeshInstance3D]
var _rain_receivers_dirty: bool = true
var _shader_compatibility: Dictionary[int, bool]
var _shader_references: Dictionary[int, WeakRef]


func bind(host: Node3D) -> void:
	unbind()
	_host = weakref(host)
	_tree = host.get_tree()
	_tree.node_added.connect(_node_added)
	_tree.node_removed.connect(_node_removed)
	_watch_branch(_tree.root)


func unbind() -> void:
	_radial_field.clear()
	_restore_surfaces()
	for reference in _watched.values():
		var geometry := reference.get_ref() as GeometryInstance3D
		if geometry != null:
			geometry.property_list_changed.disconnect(_refresh_geometry.bind(reference))
	_watched.clear()
	for identifier in _shader_references:
		var shader := _shader_references[identifier].get_ref() as Shader
		if shader != null:
			shader.changed.disconnect(_shader_changed.bind(identifier))
	_shader_references.clear()
	_shader_compatibility.clear()
	if is_instance_valid(_tree):
		_tree.node_added.disconnect(_node_added)
		_tree.node_removed.disconnect(_node_removed)
	_tree = null
	_host = null
	_enabled = false
	_refresh_seconds = 0.0
	_rain_receivers = []
	_rain_receivers_dirty = true


func apply(
	weather: RefCounted, delta: float, base_temperature: float,
	settings: DynamicSkyMaterialWeatherSettings, active: bool = true, preserve_radial_cloud_coverage: bool = false,
) -> void:
	var should_enable := settings != null and settings.enabled
	if should_enable != _enabled:
		_enabled = should_enable
		if _enabled:
			for reference in _watched.values():
				_refresh_geometry(reference)
		else:
			_restore_surfaces()
	var host := _host.get_ref() as Node3D if _host != null else null
	if host == null or not host.is_inside_tree():
		return
	_radial_field.update(host, weather, _watched, delta, _enabled and active)
	if not _enabled or not active:
		return
	# Runtime material assignment does not emit property_list_changed in Godot.
	# Reconcile occasionally so material swaps need no extra setup on their meshes.
	_refresh_seconds += maxf(delta, 0.0)
	if _refresh_seconds >= 0.5:
		_refresh_seconds = 0.0
		for reference in _watched.values():
			_refresh_geometry(reference)
	for identifier in _surfaces.keys():
		var entry := _surfaces[identifier]
		var geometry := entry.geometry.get_ref() as GeometryInstance3D
		if geometry == null or not geometry.is_inside_tree():
			_surfaces.erase(identifier)
			_rain_receivers_dirty = true
			continue
		if geometry.get_world_3d() != host.get_world_3d():
			_restore_surface(identifier)
			continue
		var position := geometry.global_transform * geometry.get_aabb().get_center()
		var conditions: Dictionary = weather.sample_at(position, preserve_radial_cloud_coverage, true)
		if conditions.is_empty():
			continue
		var accumulation_conditions := conditions
		var accumulation_precipitation: Vector2 = conditions.get(
			&"surface_precipitation", DynamicSkySurface.USE_AIRBORNE_PRECIPITATION,
		)
		if _radial_field.manages_accumulation(geometry):
			accumulation_conditions = weather.sample_at(position, preserve_radial_cloud_coverage, true, true)
			accumulation_precipitation = accumulation_conditions.get(
				&"surface_precipitation", Vector2(accumulation_conditions[&"rain"], accumulation_conditions[&"snow"]),
			)
		entry.state = DynamicSkySurface.calculate_weather_state(
			Vector3(entry.state.x, entry.state.y, entry.state.z),
			conditions[&"rain"], accumulation_conditions[&"snow"], accumulation_conditions[&"dust"], delta,
			base_temperature + float(accumulation_conditions[&"temperature_offset"]), settings,
			float(accumulation_conditions.get(&"snow_coverage_limit", 1.0)), accumulation_precipitation,
		)
		if geometry.get_instance_shader_parameter(PARAMETER) != entry.state:
			geometry.set_instance_shader_parameter(PARAMETER, entry.state)


func uses_radial_coating(geometry: GeometryInstance3D) -> bool:
	return _radial_field.manages_accumulation(geometry)


## Returns cached weather-managed mesh candidates for the optional rain contact normal field.
func get_rain_contact_receivers() -> Array[MeshInstance3D]:
	if _rain_receivers_dirty:
		var receivers: Array[MeshInstance3D] = []
		for entry in _surfaces.values():
			var geometry := entry.geometry.get_ref() as MeshInstance3D
			if geometry != null:
				receivers.append(geometry)
		_rain_receivers = receivers
		_rain_receivers_dirty = false
	return _rain_receivers


func _watch_branch(node: Node) -> void:
	if node is GeometryInstance3D:
		_watch_geometry(weakref(node))
	for child in node.get_children():
		_watch_branch(child)


func _node_added(node: Node) -> void:
	if node is GeometryInstance3D:
		_watch_geometry.call_deferred(weakref(node))


func _node_removed(node: Node) -> void:
	var identifier := node.get_instance_id()
	if _watched.has(identifier):
		node.property_list_changed.disconnect(_refresh_geometry.bind(_watched[identifier]))
		_watched.erase(identifier)
		_restore_surface(identifier)


func _watch_geometry(reference: WeakRef) -> void:
	var host := _host.get_ref() as Node3D if _host != null else null
	var geometry := reference.get_ref() as GeometryInstance3D
	if host == null or geometry == null or not geometry.is_inside_tree():
		return
	if geometry.get_world_3d() != host.get_world_3d():
		return
	var identifier := geometry.get_instance_id()
	if _watched.has(identifier):
		return
	_watched[identifier] = reference
	geometry.property_list_changed.connect(_refresh_geometry.bind(reference))
	_refresh_geometry(reference)


func _refresh_geometry(reference: WeakRef) -> void:
	var geometry := reference.get_ref() as GeometryInstance3D
	if geometry == null or not _enabled:
		return
	var compatible := false
	for material in _get_materials(geometry):
		if material is ShaderMaterial and material.shader != null and _has_weather_hook(material.shader):
			compatible = true
			for parameter in DEFAULT_TEXTURES:
				if material.get_shader_parameter(parameter) == null:
					material.set_shader_parameter(parameter, load(DEFAULT_TEXTURES[parameter]))
	var identifier := geometry.get_instance_id()
	if compatible and not _surfaces.has(identifier):
		var entry := SurfaceEntry.new()
		entry.geometry = reference
		for property in geometry.get_property_list():
			if property.name == "instance_shader_parameters/dynamic_sky_weather":
				if property.usage & PROPERTY_USAGE_STORAGE:
					entry.previous_value = geometry.get_instance_shader_parameter(PARAMETER)
		_surfaces[identifier] = entry
		_rain_receivers_dirty = true
	elif not compatible:
		_restore_surface(identifier)


func _has_weather_hook(shader: Shader) -> bool:
	var identifier := shader.get_instance_id()
	if _shader_compatibility.has(identifier):
		return _shader_compatibility[identifier]
	if not _shader_references.has(identifier):
		_shader_references[identifier] = weakref(shader)
		shader.changed.connect(_shader_changed.bind(identifier))
	var compatible := false
	for property in shader.get_shader_uniform_list():
		if property.name == MARKER:
			compatible = true
			break
	_shader_compatibility[identifier] = compatible
	return compatible


func _shader_changed(identifier: int) -> void:
	_shader_compatibility.erase(identifier)


func _get_materials(geometry: GeometryInstance3D) -> Array[Material]:
	var materials: Array[Material] = []
	if geometry.material_override != null:
		materials.append(geometry.material_override)
	elif geometry is MeshInstance3D and geometry.mesh != null:
		for surface in geometry.mesh.get_surface_count():
			var material: Material = geometry.get_active_material(surface)
			if material != null:
				materials.append(material)
	elif geometry is MultiMeshInstance3D and geometry.multimesh != null and geometry.multimesh.mesh != null:
		for surface in geometry.multimesh.mesh.get_surface_count():
			var material: Material = geometry.multimesh.mesh.surface_get_material(surface)
			if material != null:
				materials.append(material)
	return materials


func _restore_surface(identifier: int) -> void:
	if not _surfaces.has(identifier):
		return
	var entry := _surfaces[identifier]
	var geometry := entry.geometry.get_ref() as GeometryInstance3D
	if geometry != null:
		geometry.set_instance_shader_parameter(PARAMETER, entry.previous_value)
	_surfaces.erase(identifier)
	_rain_receivers_dirty = true


func _restore_surfaces() -> void:
	for identifier in _surfaces.keys():
		_restore_surface(identifier)
