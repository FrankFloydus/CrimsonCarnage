extends RefCounted
## Advances one rig's optional timer and starts the existing radial actor lifecycle.

const Settings = preload("res://addons/dynamic_sky/weather/radial_storm_spawning.gd")
const RadialStorm = preload("res://addons/dynamic_sky/weather/radial_storm.gd")
const STORM_SCENE := preload("res://addons/dynamic_sky/weather/radial_storm.tscn")
const MINIMUM_WAIT: float = 0.1
const SECONDS_PER_DAY: int = 86400
const GREGORIAN_WINTER_SOLSTICE_OFFSET: float = -11.0

var _settings: Settings
var _configured_seed: int
var _random_state: int
var _remaining: float
var _active_storm: RadialStorm


## Cancels the timer. A previously spawned storm continues to move and fade.
func stop() -> void:
	_settings = null
	_remaining = 0.0


## Advances the timer by game seconds. True means the owner should provide a spawn context.
func advance(delta: float, settings: Settings) -> bool:
	if settings == null or not settings.enabled:
		stop()
		return false
	if _settings != settings or _configured_seed != settings.random_seed:
		_settings = settings
		_configured_seed = settings.random_seed
		_random_state = _configured_seed & 0xffffffff if _configured_seed >= 0 else randi_range(0, 10000)
		_remaining = maxf(MINIMUM_WAIT, _sample_range(settings.wait_seconds) * maxf(settings.first_wait_multiplier, 0.0))

	_remaining = maxf(_remaining - delta, 0.0)
	return (
		_remaining <= 0.000001
		and (not is_instance_valid(_active_storm) or _active_storm.is_queued_for_deletion())
	)


## Selects a route and starts the existing saved radial actor.
func spawn(rig: Node3D, control_point: Vector3, downwind: Vector2, season: int) -> RadialStorm:
	var settings := _settings
	# Unreal +Z yaw becomes negative Godot Y yaw under the comparison coordinate conversion.
	var direction := downwind.normalized() if not downwind.is_zero_approx() else Vector2.DOWN
	var heading_variation := deg_to_rad((_random_fraction() - 0.5) * settings.direction_variation)
	var upwind := Vector3(-direction.x, 0.0, -direction.y).rotated(Vector3.UP, -heading_variation)
	var azimuth := _random_fraction() * TAU
	var offset := Vector3.FORWARD.rotated(Vector3.UP, -azimuth) * maxf(settings.route_offset, 0.0)
	var origin := control_point + offset
	var lifetime := maxf(MINIMUM_WAIT, _sample_range(settings.lifetime_seconds))
	var profile := _sample_weather(settings.probabilities, season)
	_remaining = maxf(MINIMUM_WAIT, lifetime + _sample_range(settings.wait_seconds))
	if profile == null:
		return null

	var storm := STORM_SCENE.instantiate() as RadialStorm
	storm.weather = profile
	storm.outer_radius = maxf(settings.outer_radius, 0.01)
	storm.inner_radius_fraction = settings.inner_radius_fraction
	var fade := lifetime * clampf(settings.fade_fraction, 0.0, 1.0) * 0.5
	storm.storm_alpha = 0.0 if fade > 0.0 else 1.0
	storm.top_level = true
	storm.position = origin + upwind * maxf(settings.travel_distances.x, 0.0)
	rig.add_child(storm)
	var end := origin - upwind * maxf(settings.travel_distances.y, 0.0)
	storm.fade_in(fade)
	storm.move_over_time(end, lifetime, fade)
	_active_storm = storm
	return storm


## Returns the nearest source season index at the rig date or manual phase.
static func get_season(settings: Settings, date: Dictionary, hour: float, latitude: float) -> int:
	var phase := settings.manual_season
	if settings.season_mode == Settings.SeasonMode.RIG_DATE and not date.is_empty():
		var year: int = date["year"]
		var year_start := Time.get_unix_time_from_datetime_dict({"year": year, "month": 1, "day": 1})
		var next_year_start := Time.get_unix_time_from_datetime_dict({"year": year + 1, "month": 1, "day": 1})
		var days_in_year := float(next_year_start - year_start) / SECONDS_PER_DAY
		var day := float(Time.get_unix_time_from_datetime_dict(date) - year_start) / SECONDS_PER_DAY
		var meteorological_shift := days_in_year / 18.0 if settings.meteorological_seasons else 0.0
		var offset := float(settings.season_day_offset) + 1.0 - GREGORIAN_WINTER_SOLSTICE_OFFSET
		var hemisphere := 3.0 if latitude > 0.0 else 5.0
		phase = (day + hour / 24.0 + offset + meteorological_shift) / (days_in_year / 4.0) + 3.5 + hemisphere
	return posmod(roundi(phase), 4)


func _sample_weather(probabilities: Array[DynamicSkyWeatherProbability], season: int) -> DynamicSkyWeather:
	var total := 0.0
	for entry in probabilities:
		if entry != null and entry.weather != null:
			total += entry.weight_for(season)
	var remaining := _random_fraction() * total
	for entry in probabilities:
		if entry == null or entry.weather == null:
			continue
		var weight := entry.weight_for(season)
		if weight <= 0.0:
			continue
		remaining -= weight
		if remaining <= 0.0:
			return entry.weather
	return null


func _sample_range(limits: Vector2) -> float:
	return lerpf(maxf(minf(limits.x, limits.y), 0.0), maxf(maxf(limits.x, limits.y), 0.0), _random_fraction())


func _random_fraction() -> float:
	# Match the 32-bit stream and high 23 fraction bits used by Unreal's FRandomStream.
	_random_state = (_random_state * 196314165 + 907633515) & 0xffffffff
	return float(_random_state >> 9) / 8388608.0
