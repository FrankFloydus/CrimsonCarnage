@tool
class_name DynamicSkyWeatherExposure
extends Node3D
## Filters observer weather while keeping the global weather and surface accumulation independent.

const VOLUMETRIC_CLOUD_MODE := 0
const LUMINANCE_PER_SENSITIVITY := 0.125
const BRIGHT_SCENE_SPEED := &"auto_exposure_bright_scene_speed"
const CLOUD_INTERIOR_SHADER := preload("res://addons/dynamic_sky/weather/exposure/cloud_interior_fog.gdshader")
const CLOUD_FIELD_TEXTURES: Array[StringName] = [&"cloud_formation", &"cloud_erosion_volume", &"cloud_profile"]
const CLOUD_FIELD_PARAMETERS: Array[StringName] = [
	&"sun_direction", &"cloud_coverage", &"cloud_offset", &"cloud_base_km", &"cloud_thickness_km",
	&"cloud_extinction", &"low_cloud_scale", &"cloud_formation_texture_scale",
	&"cloud_formation_phase", &"cloud_formation_z_shift", &"cloud_erosion_scale",
	&"cloud_erosion_intensity", &"cloud_macro_variation", &"cloud_macro_scale",
	&"radial_cloud_cell_count", &"radial_cloud_cells", &"radial_cloud_cell_values",
]
const WEATHER_CHANNELS: Array[StringName] = [
	&"rain", &"snow", &"dust", &"fog_density", &"fog_amount", &"lightning_rate", &"sheet_lightning_rate",
]

## Sole authoring resource for cloud-height, water-surface, and nighttime weather exposure.
@export var settings: DynamicSkyExposureSettings

var _runtime_seconds: float = 0.0
var _cloud_interior_volume: FogVolume
var _exposure_camera: Camera3D
var _exposure_camera_template: CameraAttributesPractical
var _exposure_camera_attributes: CameraAttributesPractical
var _night_storm_camera: bool = false
var _flash_hold_remaining: float = 0.0


func _ready() -> void:
	_runtime_seconds = 0.0


func _process(delta: float) -> void:
	_runtime_seconds += delta


func _exit_tree() -> void:
	_clear_camera_exposure()


## Nighttime weight in heavy rain. Daylight and regular rain retain their lighting.
func get_night_storm_weight(rain: float, sun_height: float) -> float:
	if not _enabled() or settings.night_storm == null or RenderingServer.get_current_rendering_method() != &"forward_plus":
		return 0.0
	var template := settings.night_storm.camera_attributes
	if template != null and not template.has_method(&"is_auto_exposure_using_ev_adaptation"):
		return 0.0
	return smoothstep(0.75, 0.95, rain) * (1.0 - smoothstep(-0.20, -0.05, sun_height))


## Updates the optional local camera exposure. Authored camera and world attributes take precedence.
func update_camera_exposure(camera: Camera3D, dust: float, sun_height: float, storm_weight: float, delta: float) -> void:
	var template := settings.dust_night_exposure if _enabled() else null
	var weight := smoothstep(0.40, 0.92, dust) * (1.0 - smoothstep(-0.26, -0.06, sun_height))
	var storm := false
	if template == null or not template.auto_exposure_enabled or weight <= 0.0001:
		var storm_settings := settings.night_storm if _enabled() else null
		template = storm_settings.camera_attributes if storm_settings != null else null
		weight = storm_weight
		storm = (
			template != null and template.has_method(&"is_auto_exposure_using_ev_adaptation")
			and bool(template.call(&"is_auto_exposure_using_ev_adaptation"))
		)
		if not storm:
			template = null
	if (
		not is_instance_valid(camera) or not camera.is_inside_tree() or weight <= 0.0001
		or template == null or not template.auto_exposure_enabled
		or RenderingServer.get_current_rendering_method() != &"forward_plus"
	):
		_clear_camera_exposure()
		return
	if _exposure_camera != camera or _exposure_camera_template != template or _night_storm_camera != storm:
		_clear_camera_exposure()
	if (
		(camera.attributes != null and camera.attributes != _exposure_camera_attributes)
		or camera.get_world_3d().camera_attributes != null
	):
		_clear_camera_exposure()
		return
	if _exposure_camera_attributes == null:
		_exposure_camera = camera
		_exposure_camera_template = template
		_exposure_camera_attributes = template.duplicate() as CameraAttributesPractical
		_night_storm_camera = storm
	# Equal bounds at the metered gray produce a gain of one at the start of the blend.
	var neutral := template.auto_exposure_scale * template.exposure_sensitivity / LUMINANCE_PER_SENSITIVITY
	var minimum := lerpf(neutral, template.auto_exposure_min_sensitivity, weight)
	var maximum := lerpf(neutral, template.auto_exposure_max_sensitivity, weight)
	if not is_equal_approx(_exposure_camera_attributes.auto_exposure_min_sensitivity, minimum):
		_exposure_camera_attributes.auto_exposure_min_sensitivity = minimum
	if not is_equal_approx(_exposure_camera_attributes.auto_exposure_max_sensitivity, maximum):
		_exposure_camera_attributes.auto_exposure_max_sensitivity = maximum
	if _night_storm_camera:
		_flash_hold_remaining = maxf(0.0, _flash_hold_remaining - delta)
		var speed := 0.0 if _flash_hold_remaining > 0.0 else float(template.get(BRIGHT_SCENE_SPEED))
		if not is_equal_approx(float(_exposure_camera_attributes.get(BRIGHT_SCENE_SPEED)), speed):
			_exposure_camera_attributes.set(BRIGHT_SCENE_SPEED, speed)
	if camera.attributes == null:
		camera.attributes = _exposure_camera_attributes


## Updates the dust-only path for standalone exposure callers.
func update_dust_exposure(camera: Camera3D, dust: float, sun_height: float) -> void:
	update_camera_exposure(camera, dust, sun_height, 0.0, 0.0)


## Pauses bright-scene adaptation only for a full strike on a camera owned by this fallback.
func hold_night_storm_exposure() -> void:
	if not _night_storm_camera or not is_instance_valid(_exposure_camera) or not _enabled() or settings.night_storm == null:
		return
	if _exposure_camera.attributes != _exposure_camera_attributes:
		return
	var duration := maxf(0.0, settings.night_storm.flash_hold_seconds)
	if duration > 0.0:
		_flash_hold_remaining = duration
		_exposure_camera_attributes.set(BRIGHT_SCENE_SPEED, 0.0)


## Returns local shadow grade strength and upper toe. Native Environment adjustments remain authoritative.
func get_night_storm_grade(camera: Camera3D, weight: float) -> Vector2:
	if not _night_storm_camera or not _enabled() or settings.night_storm == null or not is_instance_valid(camera):
		return Vector2.ZERO
	if camera != _exposure_camera or camera.attributes != _exposure_camera_attributes:
		return Vector2.ZERO
	var world := camera.get_world_3d()
	var environment := camera.environment if camera.environment != null else world.environment
	if environment == null:
		environment = world.fallback_environment
	if environment != null and (environment.adjustment_enabled or environment.background_mode == Environment.BG_CANVAS):
		return Vector2.ZERO
	var storm := settings.night_storm
	return Vector2(weight * storm.shadow_grade_strength, storm.shadow_toe_end)


func _clear_camera_exposure() -> void:
	if is_instance_valid(_exposure_camera) and _exposure_camera.attributes == _exposure_camera_attributes:
		_exposure_camera.attributes = null
	_exposure_camera = null
	_exposure_camera_template = null
	_exposure_camera_attributes = null
	_night_storm_camera = false
	_flash_hold_remaining = 0.0


## Returns an independent local view. The original weather channels remain intact.
## Cloud base and thickness use the sky shader's kilometers relative to rig_origin.
func filter_view(
	weather: Dictionary[StringName, Variant], observer: Vector3, rig_origin: Vector3,
	cloud_base_km: float, cloud_thickness_km: float, cloud_mode: int, space_mode: bool = false,
) -> Dictionary[StringName, Variant]:
	var filtered := weather.duplicate()
	if not _enabled() or space_mode:
		return filtered
	var suppression := get_above_cloud_suppression(
		observer, rig_origin, cloud_base_km, cloud_thickness_km, cloud_mode, space_mode
	)
	var multipliers: Dictionary[StringName, float] = {
		&"rain": settings.rain_multiplier,
		&"snow": settings.snow_multiplier,
		&"dust": settings.dust_multiplier,
		&"fog_density": settings.fog_multiplier,
		&"fog_amount": settings.fog_multiplier,
		&"lightning_rate": settings.thunder_multiplier,
		&"sheet_lightning_rate": settings.thunder_multiplier,
	}
	for channel in WEATHER_CHANNELS:
		if filtered.has(channel):
			filtered[channel] *= lerpf(1.0, clampf(multipliers[channel], 0.0, 1.0), suppression)
	if filtered.has(&"wind"):
		filtered[&"wind"] *= lerpf(1.0, clampf(settings.wind_multiplier, 0.0, 1.0), suppression)

	if is_underwater_at(observer):
		for channel in WEATHER_CHANNELS:
			if filtered.has(channel):
				filtered[channel] = 0.0
	return filtered


## Linear height suppression from 10% to 65% of the authored volumetric layer by default.
## Static, Clear, Dynamic 2D, and Space backgrounds bypass this rule.
func get_above_cloud_suppression(
	observer: Vector3, rig_origin: Vector3, cloud_base_km: float, cloud_thickness_km: float,
	cloud_mode: int, space_mode: bool = false,
) -> float:
	if (
		not _enabled() or not settings.above_clouds_enabled or space_mode
		or cloud_mode != VOLUMETRIC_CLOUD_MODE or not observer.is_finite() or not rig_origin.is_finite()
		or not is_finite(cloud_base_km) or not is_finite(cloud_thickness_km)
		or cloud_thickness_km <= 0.0
	):
		return 0.0
	var layer_height := cloud_thickness_km * 1000.0
	var normalized_height := (observer.y - rig_origin.y - cloud_base_km * 1000.0) / layer_height
	var start := clampf(settings.suppression_start, 0.0, 1.0)
	var end := clampf(settings.suppression_end, start + 0.0001, 1.0001)
	return clampf((normalized_height - start) / (end - start), 0.0, 1.0)


## Highest enabled global or local water surface, in absolute world Y meters.
## Returns negative infinity where no water surface has been authored.
func get_water_level_at(world_position: Vector3) -> float:
	if not _enabled() or not world_position.is_finite():
		return -INF
	var level := -INF
	if settings.global_water_enabled and is_finite(settings.global_water_level):
		level = settings.global_water_level
	if not settings.local_water_regions_enabled or not is_inside_tree():
		return level
	var world := get_world_3d()
	for candidate in get_tree().get_nodes_in_group(DynamicSkyWaterRegion.GROUP):
		var region := candidate as DynamicSkyWaterRegion
		if is_instance_valid(region) and region.get_world_3d() == world:
			level = maxf(level, region.get_water_level_at(world_position))
	return level


## A camera exactly on the surface is above water. The source uses a strict comparison.
func is_underwater_at(world_position: Vector3) -> bool:
	return world_position.is_finite() and world_position.y < get_water_level_at(world_position)


## Visibility weight for observer-only atmospheric mist and blowing debris.
## The separate wind multiplier still applies to the returned view-weather wind.
func get_airborne_exposure(
	observer: Vector3, rig_origin: Vector3, cloud_base_km: float, cloud_thickness_km: float,
	cloud_mode: int, space_mode: bool = false,
) -> float:
	if space_mode or is_underwater_at(observer):
		return 0.0
	return 1.0 - get_above_cloud_suppression(
		observer, rig_origin, cloud_base_km, cloud_thickness_km, cloud_mode, space_mode
	)


## Applies the source's startup delay before wetting the screen on a water exit.
func should_wet_on_emerge(was_underwater: bool, now_underwater: bool) -> bool:
	if (
		not _enabled() or not settings.wet_screen_on_emerge
		or not was_underwater or now_underwater or not is_node_ready()
	):
		return false
	return _runtime_seconds > maxf(settings.emerging_runtime_delay_seconds, 0.0)


## Feeds the raw sky field to native volumetric fog around the active camera.
func update_cloud_interior(
	camera: Camera3D, sky_material: ShaderMaterial, environment: Environment,
	rig_origin: Vector3, volumetric_view: bool,
) -> void:
	if _enabled() and camera != null and camera.environment != null:
		environment = camera.environment
	if (
		not volumetric_view or not _enabled() or settings.cloud_interior_fog_strength <= 0.0
		or camera == null or environment == null or not environment.volumetric_fog_enabled
		or sky_material == null or sky_material.shader == null
		or RenderingServer.get_current_rendering_method() != &"forward_plus"
	):
		_hide_cloud_interior()
		return

	var base: Variant = _cloud_field_parameter(sky_material, &"cloud_base_km")
	var thickness: Variant = _cloud_field_parameter(sky_material, &"cloud_thickness_km")
	var coverage: Variant = _cloud_field_parameter(sky_material, &"cloud_coverage")
	if (
		not (base is float and thickness is float and coverage is float)
		or thickness <= 0.0
	):
		_hide_cloud_interior()
		return

	var fog_length := minf(environment.volumetric_fog_length, camera.far)
	var view_extent := camera.get_camera_projection().get_viewport_half_extents()
	if camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
		view_extent *= fog_length / maxf(camera.near, 0.001)
	# Preserve the calibrated margin around the frustum for temporal fog reprojection.
	var reach := maxf(Vector3(view_extent.x, view_extent.y, fog_length).length(), fog_length * 1.875)
	var observer := camera.global_position
	var relative_km := (observer - rig_origin) * 0.001
	var horizontal_km := Vector2(relative_km.x, relative_km.z).length()
	# Bound the same curvature term as altitude_at() over the volume's visible reach.
	var reach_km := reach * 0.001
	var lower_radius := maxf(horizontal_km - reach_km, 0.0)
	var upper_radius := horizontal_km + reach_km
	var lower_altitude := relative_km.y - reach_km + lower_radius * lower_radius / 12742.0
	var upper_altitude := relative_km.y + reach_km + upper_radius * upper_radius / 12742.0
	if (
		upper_altitude <= base or lower_altitude >= base + thickness
		or (coverage <= 0.0 and not _radial_cloud_reaches(sky_material, Vector2(relative_km.x, relative_km.z), reach_km))
	):
		_hide_cloud_interior()
		return

	for parameter in CLOUD_FIELD_TEXTURES:
		if not _cloud_field_parameter(sky_material, parameter) is Texture:
			_hide_cloud_interior()
			return

	if _cloud_interior_volume == null:
		var material := ShaderMaterial.new()
		material.shader = CLOUD_INTERIOR_SHADER
		_cloud_interior_volume = FogVolume.new()
		_cloud_interior_volume.name = "CloudInteriorFog"
		_cloud_interior_volume.top_level = true
		_cloud_interior_volume.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
		_cloud_interior_volume.material = material
		add_child(_cloud_interior_volume, false, Node.INTERNAL_MODE_BACK)

	var fog_material := _cloud_interior_volume.material as ShaderMaterial
	for parameter in CLOUD_FIELD_TEXTURES:
		_set_fog_parameter(fog_material, parameter, _cloud_field_parameter(sky_material, parameter))
	for parameter in CLOUD_FIELD_PARAMETERS:
		_set_fog_parameter(fog_material, parameter, _cloud_field_parameter(sky_material, parameter))
	_set_fog_parameter(fog_material, &"cloud_rig_origin_m", rig_origin)
	_set_fog_parameter(fog_material, &"cloud_interior_strength", clampf(settings.cloud_interior_fog_strength, 0.0, 1.0))

	var size := Vector3.ONE * (reach * 2.0)
	if _cloud_interior_volume.size != size:
		_cloud_interior_volume.size = size
	_cloud_interior_volume.global_position = observer
	_cloud_interior_volume.show()


func _hide_cloud_interior() -> void:
	if _cloud_interior_volume != null:
		_cloud_interior_volume.hide()


func _radial_cloud_reaches(material: ShaderMaterial, point_km: Vector2, reach_km: float) -> bool:
	var count: Variant = material.get_shader_parameter(&"radial_cloud_cell_count")
	if not count is int or count <= 0:
		return false
	var cells: Variant = material.get_shader_parameter(&"radial_cloud_cells")
	var values: Variant = material.get_shader_parameter(&"radial_cloud_cell_values")
	if not (cells is PackedVector4Array and values is PackedVector4Array):
		return false
	for index in mini(count, mini(cells.size(), values.size())):
		var cell: Vector4 = cells[index]
		var coverage: Vector4 = values[index]
		var radius := cell.z + reach_km
		if (
			cell.z > 0.0 and coverage.x > 0.0 and coverage.y > 0.0
			and point_km.distance_squared_to(Vector2(cell.x, cell.y)) <= radius * radius
		):
			return true
	return false


func _cloud_field_parameter(material: ShaderMaterial, parameter: StringName) -> Variant:
	var value: Variant = material.get_shader_parameter(parameter)
	if value == null:
		value = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), parameter)
	return value


func _set_fog_parameter(material: ShaderMaterial, parameter: StringName, value: Variant) -> void:
	if material.get_shader_parameter(parameter) != value:
		material.set_shader_parameter(parameter, value)


func _enabled() -> bool:
	return settings != null and settings.enabled
