@tool
class_name DynamicSkyWeatherExposure
extends Node3D
## Filters observer weather while keeping the global weather and surface accumulation independent.

const VOLUMETRIC_CLOUD_MODE := 0
const WEATHER_CHANNELS: Array[StringName] = [
	&"rain", &"snow", &"dust", &"fog_density", &"fog_amount", &"lightning_rate", &"sheet_lightning_rate",
]

## Sole authoring resource for cloud-height and water-surface exposure.
@export var settings: DynamicSkyExposureSettings

var _runtime_seconds: float = 0.0


func _ready() -> void:
	_runtime_seconds = 0.0


func _process(delta: float) -> void:
	_runtime_seconds += delta


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


func _enabled() -> bool:
	return settings != null and settings.enabled
