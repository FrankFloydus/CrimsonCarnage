@tool
class_name DynamicSkySnowTrackReceiver
extends Node3D
## Owns snow-track displacement for one subdivided, Y-up weather-responsive mesh.

const SkyLookup = preload("res://addons/dynamic_sky/weather/wind/wind_source.gd")
const MaterialSlot = preload("res://addons/dynamic_sky/surfaces/weather_material_slot.gd")
const TrackField = preload("res://addons/dynamic_sky/surfaces/snow_tracks/snow_track_field.gd")
const SNOW_COVERAGE_CHANGED := &"snow_coverage_changed"
const TRACK_PARAMETERS: Array[StringName] = [
	&"snow_tracks_enabled", &"snow_track_field", &"snow_track_rect", &"snow_track_resolution",
	&"snow_track_depth", &"snow_track_compression", &"snow_track_rim",
	&"snow_track_normal_strength", &"snow_track_retain_grazing_relief",
]
const MINIMUM_TRACK_DEPTH := 0.02
const SDFGI_DEPTH_STEP_METERS := 0.02
const SDFGI_DEPTH_EPSILON_METERS := 0.0001
const SDFGI_REFRESH_INTERVAL_SECONDS := 1.5
const SDFGI_SETTLE_SECONDS := 0.35

## Mesh whose visible vertices are displaced. Keep local +Y up and use a shader with the Snow Track Geometry uniforms.
@export var geometry: MeshInstance3D

## Track field bounds in the mesh's local X/Z coordinates, in meters. Empty uses the full mesh bounds.
@export var track_region: Rect2:
	set(value):
		track_region = value
		if _material != null:
			_bind_settings()
		update_configuration_warnings()

## Existing accumulation component that supplies the receiver's current settled snow fraction.
@export var accumulation: DynamicSkySurface:
	set(value):
		_disconnect_accumulation()
		accumulation = value
		if _sdfgi_refresh_supported:
			_connect_accumulation()
			_update_sdfgi_depth()

## Original collision body underneath the snow. The tracks never modify this shape.
@export var substrate: CollisionObject3D

## Physical depth, rim, compression and sample spacing shared by this receiver's marks.
@export var settings: DynamicSkySnowTrackSettings

## Weather rig providing local snowfall, water, and Space state. Empty resolves it in the same World3D.
@export var sky_override: DynamicSky

## Collision layers that prevent marks beneath a solid roof. Zero skips the upward check.
@export_flags_3d_physics var roof_mask: int = 1

## Maximum upward distance from the substrate to check for cover, in meters.
@export_range(0.0, 40.0, 0.1, "suffix:m") var roof_probe_height: float = 12.0

var _sky: DynamicSky
var _field: TrackField
var _texture: ImageTexture
var _material: ShaderMaterial
var _material_slot: RefCounted
var _original_cull_margin: float
var _local_rect: Rect2
var _horizontal_scale: Vector2
var _restore_elapsed: float
var _dirty: bool
var _sdfgi_refresh_supported: bool
var _sdfgi_depth: float
var _sdfgi_submitted_depth: float
var _sdfgi_quiet_seconds: float
var _sdfgi_cooldown: float


func _ready() -> void:
	set_physics_process(false)
	if Engine.is_editor_hint() or not _get_configuration_warnings().is_empty():
		return
	_material_slot = MaterialSlot.acquire(geometry, MaterialSlot.WHOLE_OVERRIDE, get_instance_id())
	if _material_slot == null:
		return
	_original_cull_margin = geometry.extra_cull_margin
	_material = _material_slot.local
	_sdfgi_refresh_supported = _supports_sdfgi_refresh()
	if _sdfgi_refresh_supported:
		_connect_accumulation()
		geometry.visibility_changed.connect(_wake_sdfgi_refresh)
	settings.changed.connect(_bind_settings)
	_bind_settings()


func _exit_tree() -> void:
	if settings != null and settings.changed.is_connected(_bind_settings):
		settings.changed.disconnect(_bind_settings)
	_disconnect_accumulation()
	if is_instance_valid(geometry) and geometry.visibility_changed.is_connected(_wake_sdfgi_refresh):
		geometry.visibility_changed.disconnect(_wake_sdfgi_refresh)
	var owns_override: bool = _material_slot != null and _material_slot.is_current()
	if _material_slot != null:
		for parameter in TRACK_PARAMETERS:
			_material.set_shader_parameter(parameter, _material_slot.authored.get_shader_parameter(parameter))
		_material_slot.release(get_instance_id())
		_material_slot = null
	if is_instance_valid(geometry) and owns_override:
		if (
			_sdfgi_refresh_supported and not is_ancestor_of(geometry) and _has_static_sdfgi_geometry()
			and maxf(_sdfgi_depth, _sdfgi_submitted_depth) >= SDFGI_DEPTH_EPSILON_METERS
		):
			_invalidate_geometry_sdfgi()
		geometry.extra_cull_margin = _original_cull_margin


func _connect_accumulation() -> void:
	if is_instance_valid(accumulation) and accumulation.has_signal(SNOW_COVERAGE_CHANGED):
		accumulation.connect(SNOW_COVERAGE_CHANGED, _on_snow_coverage_changed)


func _disconnect_accumulation() -> void:
	# The editor can have a non-tool surface whose script signal is unavailable.
	if (
		is_instance_valid(accumulation) and accumulation.has_signal(SNOW_COVERAGE_CHANGED)
		and accumulation.is_connected(SNOW_COVERAGE_CHANGED, _on_snow_coverage_changed)
	):
		accumulation.disconnect(SNOW_COVERAGE_CHANGED, _on_snow_coverage_changed)


func _get_configuration_warnings() -> PackedStringArray:
	if geometry == null or geometry.mesh == null or accumulation == null or substrate == null or settings == null:
		return PackedStringArray(["Assign a mesh, its accumulation component, a substrate body, and track settings."])
	var material := geometry.material_override as ShaderMaterial
	if material == null or not _supports_track_geometry(material):
		return PackedStringArray(["Assign a ShaderMaterial that includes Snow Track Geometry in Material Override."])
	if geometry.global_basis.y.normalized().dot(Vector3.UP) < 0.999:
		return PackedStringArray(["The receiving mesh's local +Y axis must point up. Author slopes in its vertices."])
	if not _get_track_rect().has_area():
		return PackedStringArray(["Place the track region inside the mesh's local X/Z bounds."])
	return PackedStringArray()


func _supports_track_geometry(material: ShaderMaterial) -> bool:
	if material.shader == null:
		return false
	var uniforms: Dictionary[StringName, int]
	for property: Dictionary in material.shader.get_shader_uniform_list():
		uniforms[property.name] = property.type
	return (
		uniforms.get(&"snow_tracks_enabled") == TYPE_BOOL
		and uniforms.get(&"snow_track_rect") == TYPE_VECTOR4
		and uniforms.get(&"snow_track_resolution") == TYPE_VECTOR2
		and uniforms.get(&"snow_track_depth") == TYPE_FLOAT
		and uniforms.get(&"snow_track_compression") == TYPE_FLOAT
		and uniforms.get(&"snow_track_rim") == TYPE_FLOAT
	)


## Returns the uncompressed snow depth supported by the current accumulated layer, in meters.
func get_snow_depth_meters() -> float:
	if settings == null or not is_instance_valid(accumulation):
		return 0.0
	return settings.snow_depth_meters * accumulation.get_accumulation().y


## Clears this receiver's marks. Its underlying mesh, collision, and accumulated snow stay in place.
func clear_tracks() -> void:
	if _field == null:
		return
	_field.clear()
	_restore_elapsed = 0.0
	_dirty = true
	set_physics_process(true)


## Resolves a stamp against this receiver during a physics tick.
## Returns its field position and pressure, or an empty result if there is no exposed snow contact.
func resolve_contact(point: Vector3, diameter: float, excluded_body: RID = RID()) -> Dictionary:
	var depth := get_snow_depth_meters()
	if _field == null or depth <= MINIMUM_TRACK_DEPTH or not point.is_finite() or not is_finite(diameter) or diameter <= 0.0:
		return {}
	_sky = SkyLookup.resolve(self, sky_override, _sky)
	if _sky != null and _sky.is_space_mode():
		return {}
	var local := geometry.to_local(point)
	var field_position := (Vector2(local.x, local.z) - _local_rect.position) * _horizontal_scale
	if not _field.contains(field_position):
		return {}

	var range_meters := depth + diameter * 0.5
	var excluded: Array[RID] = []
	if excluded_body.is_valid():
		excluded.append(excluded_body)
	var query := PhysicsRayQueryParameters3D.create(
		point + Vector3.UP * 0.05, point - Vector3.UP * range_meters, substrate.collision_layer, excluded
	)
	var space := get_world_3d().direct_space_state
	var hit := space.intersect_ray(query)
	if hit.is_empty() or hit.collider != substrate or hit.normal.y < 0.50:
		return {}
	var ground: Vector3 = hit.position
	var exposure := null if _sky == null else _sky.get_node_or_null(^"WeatherExposure") as DynamicSkyWeatherExposure
	if exposure != null and ground.y <= exposure.get_water_level_at(ground):
		return {}
	if roof_mask != 0 and roof_probe_height > 0.05:
		excluded.append(substrate.get_rid())
		var roof_query := PhysicsRayQueryParameters3D.create(
			ground + Vector3.UP * 0.05, ground + Vector3.UP * roof_probe_height, roof_mask, excluded
		)
		if not space.intersect_ray(roof_query).is_empty():
			return {}
	var pressure := lerpf(1.0, 0.2, clampf((point.y - ground.y - depth) / (diameter * 0.5), 0.0, 1.0))
	return {&"position": field_position, &"pressure": pressure}


## Applies a swept mark between two accepted contacts in this receiver's field coordinates.
func write_contact(from: Vector2, to: Vector2, diameter: float, pressure: float) -> void:
	if (
		_field == null or not is_finite(diameter) or diameter <= 0.0
		or not is_finite(pressure) or pressure <= 0.0
		or not _field.contains(from) or not _field.contains(to)
	):
		return
	if _field.stamp(from, to, diameter, clampf(pressure, 0.0, 1.0)):
		_dirty = true
		set_physics_process(true)


func _physics_process(delta: float) -> void:
	if _field != null and _field.has_marks():
		if get_snow_depth_meters() <= 0.001:
			_field.clear()
			_restore_elapsed = 0.0
			_dirty = true
		else:
			_sky = SkyLookup.resolve(self, sky_override, _sky)
			var weather := 0.0 if _sky == null else float(_sky.get_weather_at(global_position)[&"snow"])
			var interval := 15.0 / lerpf(1.0, 5.0, pow(weather, 3.0))
			_restore_elapsed += delta
			if _restore_elapsed >= interval:
				_restore_elapsed = fmod(_restore_elapsed, interval)
				_field.restore_step()
				_dirty = true
	if _field != null and _dirty:
		_texture.update(_field.get_image())
		_dirty = false
	var refresh_active := _advance_sdfgi_refresh(delta)
	set_physics_process(refresh_active or (_field != null and _field.has_marks()))


func _supports_sdfgi_refresh() -> bool:
	return (
		RenderingServer.get_current_rendering_method() == "forward_plus"
		and RenderingServer.has_method(&"instance_invalidate_sdfgi")
	)


func _has_static_sdfgi_geometry() -> bool:
	if (
		not is_instance_valid(geometry) or not geometry.is_inside_tree() or not geometry.is_visible_in_tree()
		or geometry.gi_mode != GeometryInstance3D.GI_MODE_STATIC
	):
		return false
	var viewport := geometry.get_viewport()
	var world := viewport.find_world_3d() if viewport != null else null
	return world != null and world.scenario.is_valid() and geometry.get_instance().is_valid()


func _on_snow_coverage_changed(_coverage: float) -> void:
	_update_sdfgi_depth()


func _update_sdfgi_depth() -> void:
	if not _sdfgi_refresh_supported:
		return
	var depth := get_snow_depth_meters() if _field != null else 0.0
	if absf(depth - _sdfgi_depth) >= SDFGI_DEPTH_EPSILON_METERS:
		_sdfgi_depth = depth
		_sdfgi_quiet_seconds = 0.0
	_wake_sdfgi_refresh()


func _wake_sdfgi_refresh() -> void:
	if _has_pending_sdfgi_refresh() and _has_static_sdfgi_geometry():
		set_physics_process(true)


func _has_pending_sdfgi_refresh() -> bool:
	return absf(_sdfgi_depth - _sdfgi_submitted_depth) >= SDFGI_DEPTH_EPSILON_METERS


func _advance_sdfgi_refresh(delta: float) -> bool:
	if not _sdfgi_refresh_supported:
		return false
	_sdfgi_cooldown = maxf(_sdfgi_cooldown - delta, 0.0)
	if not _has_pending_sdfgi_refresh() or not _has_static_sdfgi_geometry():
		return _sdfgi_cooldown > 0.0
	_sdfgi_quiet_seconds += delta
	if _sdfgi_cooldown <= 0.0 and (
		absf(_sdfgi_depth - _sdfgi_submitted_depth) >= SDFGI_DEPTH_STEP_METERS
		or _sdfgi_quiet_seconds >= SDFGI_SETTLE_SECONDS
	):
		_invalidate_geometry_sdfgi()
		_sdfgi_submitted_depth = _sdfgi_depth
		_sdfgi_cooldown = SDFGI_REFRESH_INTERVAL_SECONDS
	return true


func _invalidate_geometry_sdfgi() -> void:
	RenderingServer.call(&"instance_invalidate_sdfgi", geometry.get_instance())


func _get_track_rect() -> Rect2:
	var bounds := geometry.mesh.get_aabb()
	var mesh_rect := Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))
	return mesh_rect.intersection(track_region) if track_region.has_area() else mesh_rect


func _bind_settings() -> void:
	var next_rect := _get_track_rect()
	_horizontal_scale = Vector2(geometry.global_basis.x.length(), geometry.global_basis.z.length())
	var extent := next_rect.size * _horizontal_scale
	if extent.x <= 0.001 or extent.y <= 0.001:
		_field = null
		_texture = null
		_material.set_shader_parameter(&"snow_tracks_enabled", false)
		_material.set_shader_parameter(&"snow_track_field", null)
		set_physics_process(false)
		_update_sdfgi_depth()
		return
	var size := TrackField.sample_count(extent, settings.texel_size_meters)
	if _field == null or _local_rect != next_rect or not _field.extent.is_equal_approx(extent) or _field.size != size:
		_local_rect = next_rect
		_field = TrackField.new(extent, settings.texel_size_meters)
		_texture = ImageTexture.create_from_image(_field.get_image())
		_material.set_shader_parameter(&"snow_track_field", _texture)
		_material.set_shader_parameter(&"snow_track_rect", Vector4(
			_local_rect.position.x, _local_rect.position.y, _local_rect.size.x, _local_rect.size.y
		))
		_material.set_shader_parameter(&"snow_track_resolution", Vector2(_field.size))
		_restore_elapsed = 0.0
		_dirty = false
	_material.set_shader_parameter(&"snow_tracks_enabled", true)
	_material.set_shader_parameter(&"snow_track_depth", settings.snow_depth_meters)
	_material.set_shader_parameter(&"snow_track_compression", settings.compression)
	_material.set_shader_parameter(&"snow_track_rim", settings.rim_height_meters)
	_material.set_shader_parameter(&"snow_track_normal_strength", settings.normal_strength)
	_material.set_shader_parameter(&"snow_track_retain_grazing_relief", settings.retain_grazing_relief)
	geometry.extra_cull_margin = maxf(_original_cull_margin, settings.snow_depth_meters + settings.rim_height_meters)
	_update_sdfgi_depth()
