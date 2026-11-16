@tool
class_name DynamicSkyRadialStorm
extends DynamicSkyWeatherZone
## A moving world-horizontal weather footprint with independent physical and visual fade weights.

## Distance in world meters from the center to the zero-influence boundary. Node scale does not change it.
@export_range(0.01, 40000.0, 1.0, "or_greater", "suffix:m") var outer_radius: float = 4000.0:
	set(value):
		outer_radius = value
		update_configuration_warnings()

## Inner radius divided by outer radius. Full local weather continues through the first 20% of the transition band.
@export_range(0.0, 1.0, 0.01) var inner_radius_fraction: float = 0.4:
	set(value):
		inner_radius_fraction = clampf(value, 0.0, 1.0) if is_finite(value) else 0.4

## Initial influence of a placed storm. Runtime fades update the same weight.
@export_range(0.0, 1.0, 0.001) var storm_alpha: float = 1.0:
	set(value):
		storm_alpha = clampf(value, 0.0, 1.0) if is_finite(value) else 0.0

@export_group("Distant Visuals")
## Renders the distant precipitation shaft and obscured flashes in Volumetric cloud mode.
@export var distant_visuals_enabled: bool = true
## Multiplies the optical thickness of the storm's distant fog and precipitation.
@export_range(0.0, 2.0, 0.01) var distant_fog_strength: float = 1.0
## Fade band for distant visuals beyond the outer radius, in meters.
@export_range(100.0, 40000.0, 10.0, "or_greater", "suffix:m") var distant_fade_range: float = 20000.0
## Scale of the fog and precipitation structure inside the authored storm footprint.
@export_range(0.1, 3.0, 0.01) var distant_fog_scale: float = 1.0
## Rate multiplier for cell animation and advection by resolved wind.
@export_range(0.0, 5.0, 0.01) var distant_fog_motion: float = 1.0
## Mean obscured flash events per second at full thunder strength.
@export_range(0.0, 4.0, 0.01, "suffix:events/s") var obscured_lightning_rate: float = 0.7
## Multiplies localized cloud glow and illumination inside the distant shaft.
@export_range(0.0, 3.0, 0.01) var obscured_lightning_intensity: float = 1.0

@export_group("Distant Thunder")
## Plays the storm's continuous distant thunder independently of individual flashes.
@export var thunder_enabled: bool = true
## A looping WAV uses both spatial voices. A synchronized recording can supply two mono WAVs.
## Separate channels must have matching sample rates, duration, and forward loop markers.
@export var thunder_stream: AudioStream
## Maximum audible distance from the storm's cloud base, in meters.
@export_range(100.0, 40000.0, 10.0, "or_greater", "suffix:m") var thunder_range: float = 25000.0
## Linear gain at the storm center with full weather and thunder strength.
@export_range(0.0, 1.0, 0.01) var thunder_gain: float = 0.4

@export_group("Material State")
## Blends the independent material target over weather-aware surfaces in the storm footprint.
@export var apply_material_state: bool = true
## Uses the authored target below instead of following the current weather profile.
@export var use_custom_material_state: bool = false:
	set(value):
		use_custom_material_state = value
		notify_property_list_changed()
## Custom material wetness, snow coverage, and dust coverage, in that order. Fractions range from zero to one.
@export var material_state := Vector3(1.0, 0.0, 0.0):
	set(value):
		material_state = value.clamp(Vector3.ZERO, Vector3.ONE) if value.is_finite() else Vector3.ZERO


var _fade_speed: float
var _move_start: Vector3
var _move_end: Vector3
var _move_elapsed: float
var _move_seconds: float
var _scheduled_fade_out: float = -1.0
var _fade_out_delay: float


func _ready() -> void:
	_update_processing()


func _process(delta: float) -> void:
	_advance_animation(delta)


func _validate_property(property: Dictionary) -> void:
	if property.name == &"material_state" and not use_custom_material_state:
		property.usage &= ~PROPERTY_USAGE_EDITOR
	if property.name in [&"region_mode", &"region", &"spline_path", &"spline_height_range", &"falloff"]:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if weather == null:
		warnings.append("Assign a weather profile to the radial storm.")
	if not is_finite(outer_radius) or outer_radius <= 0.0:
		warnings.append("Set the storm outer radius above zero.")
	return warnings


## Resolves independent material coverage from the profile or the actor's custom target.
func get_material_state() -> Vector3:
	if use_custom_material_state:
		return material_state
	if weather == null:
		return Vector3.ZERO
	if weather.has_meta(&"source_material_state"):
		var source: Variant = weather.get_meta(&"source_material_state")
		if source is Vector3 and source.is_finite():
			return source.clamp(Vector3.ZERO, Vector3.ONE)
	return Vector3(weather.rain, minf(weather.snow, weather.snow_coverage_limit), weather.dust)


## Returns the horizontal radius of the full-weight region in world meters.
func get_full_weather_radius() -> float:
	return outer_radius * lerpf(1.0, inner_radius_fraction, 0.8)


## Returns the current physical weight of an active storm, before applying positional falloff.
func get_effective_alpha() -> float:
	if not is_inside_tree() or is_queued_for_deletion() or not enabled or weather == null:
		return 0.0
	return storm_alpha if is_finite(outer_radius) and outer_radius > 0.0 else 0.0


## Returns the local weather weight at a world position. Vertical offset is irrelevant.
func get_weather_weight(world_position: Vector3) -> float:
	var alpha := get_effective_alpha()
	if alpha == 0.0:
		return 0.0
	var offset := world_position - global_position
	var distance := Vector2(offset.x, offset.z).length()
	if not is_finite(distance) or distance >= outer_radius:
		return 0.0
	var full_radius := get_full_weather_radius()
	var edge := 1.0 if distance <= full_radius else (outer_radius - distance) / (outer_radius - full_radius)
	return alpha * pow(edge, 1.4)


## Delays strong precipitation at a dry edge and clears it quickly when leaving a storm.
func get_precipitation_weight(
	weight: float, from: Dictionary[StringName, Variant], target: Dictionary[StringName, Variant],
) -> float:
	var previous := maxf(from[&"rain"], from[&"snow"])
	var next := maxf(target[&"rain"], target[&"snow"])
	var clouds := minf(from[&"cloud_coverage"], target[&"cloud_coverage"])
	var contrast := clampf(absf(next - previous) / 0.3, 0.0, 1.0)
	var exponent := lerpf(1.0, lerpf(8.0, 1.0, clouds), contrast)
	if previous < next:
		return pow(weight, exponent)
	return 1.0 - pow(1.0 - weight, exponent)


## Returns the particle fade weight, which starts after the physical influence reaches one half.
func get_visual_alpha() -> float:
	return maxf(2.0 * get_effective_alpha() - 1.0, 0.0)


## Returns the storm profile's thunder strength before local weather blending.
func get_thunder_strength() -> float:
	if weather == null:
		return 0.0
	if weather.has_meta(&"source_thunder_lightning"):
		return clampf(float(weather.get_meta(&"source_thunder_lightning")) / 10.0, 0.0, 1.0)
	return clampf(maxf(weather.lightning_rate / 11.0, weather.sheet_lightning_rate / 3.5), 0.0, 1.0)


## Starts a localized distant flash at a world position within this storm.
func trigger_obscured_flash_at(world_position: Vector3, strength: float = 1.0) -> bool:
	var visual := get_node_or_null(^"DistantVisual")
	return visual != null and bool(visual.call(&"flash_at", world_position, strength))


## Starts a linear fade from zero. A nonpositive duration activates the storm immediately.
func fade_in(seconds: float) -> void:
	if not is_finite(seconds):
		return
	if seconds <= 0.0:
		storm_alpha = 1.0
		_fade_speed = 0.0
	else:
		storm_alpha = 0.0
		_fade_speed = 1.0 / seconds
	_update_processing()


## Fades from the current weight and frees the storm at zero. A nonpositive duration queues immediate removal.
func fade_out(seconds: float) -> void:
	if not is_finite(seconds):
		return
	_scheduled_fade_out = -1.0
	_begin_fade_out(seconds)
	_update_processing()


## Travels linearly to a world position, retaining the current height. A nonnegative fade duration schedules removal.
func move_over_time(world_target: Vector3, seconds: float, fade_out_seconds: float = -1.0) -> void:
	if not world_target.is_finite() or not is_finite(seconds) or not is_finite(fade_out_seconds):
		return
	_move_start = global_position
	_move_end = Vector3(world_target.x, global_position.y, world_target.z)
	_move_elapsed = 0.0
	_move_seconds = maxf(seconds, 0.0)
	_scheduled_fade_out = fade_out_seconds
	if _move_seconds == 0.0:
		global_position = _move_end
		if fade_out_seconds >= 0.0:
			fade_out(fade_out_seconds)
	else:
		_fade_out_delay = maxf(1.0, _move_seconds - maxf(fade_out_seconds, 0.0))
	_update_processing()


## Stops travel and fades, retaining the current position and influence.
func cancel_animation() -> void:
	_move_seconds = 0.0
	_fade_speed = 0.0
	_scheduled_fade_out = -1.0
	_update_processing()


func _advance_animation(delta: float) -> void:
	if _move_seconds > 0.0:
		_move_elapsed = minf(_move_elapsed + delta, _move_seconds)
		global_position = _move_start.lerp(_move_end, _move_elapsed / _move_seconds)
		if _move_elapsed >= _move_seconds:
			_move_seconds = 0.0

	if _scheduled_fade_out >= 0.0:
		var before_fade := minf(delta, _fade_out_delay)
		_advance_fade(before_fade)
		_fade_out_delay -= before_fade
		if _fade_out_delay <= 0.0:
			_begin_fade_out(_scheduled_fade_out)
			_scheduled_fade_out = -1.0
			_advance_fade(delta - before_fade)
	else:
		_advance_fade(delta)
	_update_processing()


func _begin_fade_out(seconds: float) -> void:
	if seconds <= 0.0:
		storm_alpha = 0.0
		_fade_speed = 0.0
		queue_free()
	else:
		_fade_speed = -1.0 / seconds


func _advance_fade(delta: float) -> void:
	if _fade_speed == 0.0:
		return
	storm_alpha = storm_alpha + delta * _fade_speed
	if _fade_speed < 0.0 and storm_alpha == 0.0:
		_fade_speed = 0.0
		queue_free()
	elif _fade_speed > 0.0 and storm_alpha == 1.0:
		_fade_speed = 0.0


func _update_processing() -> void:
	set_process(
		not Engine.is_editor_hint()
		and not is_queued_for_deletion()
		and (_fade_speed != 0.0 or _move_seconds > 0.0 or _scheduled_fade_out >= 0.0)
	)
