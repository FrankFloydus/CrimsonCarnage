extends RefCounted
## Resolves civil wall time and reports forward clock crossings for its owning sky.

const HOURS_PER_DAY: float = 24.0
const SECONDS_PER_DAY: int = 86400
const SUN_SAMPLE_HOURS: float = 1.0 / 12.0
const MAX_WALL_STEP_HOURS: float = 1.0 / 12.0
const ROOT_ITERATIONS: int = 18

var _astronomy: DynamicSkyAstronomy
var _local_origin_day: int = 0
var _has_local_origin: bool = false
var _started: bool = false
var _previous_hour: float = 0.0
var _furthest_hour: float = 0.0


## Samples UTC plus Astronomy's fixed offset, or the operating system's local zone.
## The optional timestamp and local offset in minutes allow deterministic checks.
## Without Astronomy, the first sampled local date becomes day offset zero.
func system_sample(
	astronomy: DynamicSkyAstronomy = null,
	unix_seconds: float = NAN,
	local_offset_minutes: float = NAN,
) -> Dictionary:
	if is_nan(unix_seconds):
		unix_seconds = Time.get_unix_time_from_system()
	if not is_finite(unix_seconds):
		return {}
	var offset_minutes := local_offset_minutes
	if astronomy != null:
		offset_minutes = astronomy.utc_offset_hours * 60.0
	elif is_nan(offset_minutes):
		offset_minutes = float(Time.get_time_zone_from_system().bias)
	if not is_finite(offset_minutes):
		return {}

	var civil_seconds := unix_seconds + offset_minutes * 60.0
	var civil_day := floori(civil_seconds / float(SECONDS_PER_DAY))
	if astronomy == null and not _has_local_origin:
		_local_origin_day = civil_day
		_has_local_origin = true
	var day_offset := civil_day - _origin_day(astronomy)
	var hour := (civil_seconds - civil_day * SECONDS_PER_DAY) / 3600.0
	return {
		&"hour": hour,
		&"day_offset": day_offset,
		&"date": _date_at_day(civil_day),
	}


## Rebaselines after a manual edit, restore, source change, or editor preview.
## The first subsequent advance reports only crossings after this sample.
func reset(day_offset: int, hour: float, astronomy: DynamicSkyAstronomy = null) -> void:
	_astronomy = astronomy
	_origin_day(astronomy)
	_previous_hour = float(day_offset) * HOURS_PER_DAY + hour
	_furthest_hour = _previous_hour
	_started = is_finite(_previous_hour)


## Returns ordered hourly, midnight, date_changed, sunrise, and sunset records.
## The Sun callback accepts an absolute civil hour and returns its world-up component.
## Wall-clock jumps over five minutes rebaseline, and backward steps never replay events.
func advance(
	day_offset: int,
	hour: float,
	sun_height_at: Callable = Callable(),
	wall_clock: bool = false,
) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var current_hour := float(day_offset) * HOURS_PER_DAY + hour
	if not is_finite(current_hour):
		return events
	if not _started:
		reset(day_offset, hour, _astronomy)
		return events
	var elapsed := current_hour - _previous_hour
	_previous_hour = current_hour
	if elapsed <= 0.0:
		return events
	if wall_clock and elapsed > MAX_WALL_STEP_HOURS:
		_furthest_hour = maxf(_furthest_hour, current_hour)
		return events

	var cursor := _furthest_hour
	_furthest_hour = maxf(_furthest_hour, current_hour)
	if cursor >= current_hour:
		return events
	var sun_height := float(sun_height_at.call(cursor)) if sun_height_at.is_valid() else NAN
	while cursor < current_hour:
		var next_sample := (floorf(cursor / SUN_SAMPLE_HOURS) + 1.0) * SUN_SAMPLE_HOURS
		next_sample = minf(current_hour, maxf(next_sample, cursor + 0.00000001))
		if sun_height_at.is_valid():
			var next_height := float(sun_height_at.call(next_sample))
			if is_finite(sun_height) and is_finite(next_height):
				if sun_height < 0.0 and next_height >= 0.0:
					events.append(_event(&"sunrise", _sun_crossing(cursor, next_sample, sun_height_at)))
				elif sun_height > 0.0 and next_height <= 0.0:
					events.append(_event(&"sunset", _sun_crossing(cursor, next_sample, sun_height_at)))
			sun_height = next_height
		var boundary_hour := floori(next_sample + 0.00000001)
		if boundary_hour > floori(cursor + 0.00000001):
			if posmod(boundary_hour, 24) == 0:
				events.append(_event(&"midnight", float(boundary_hour)))
				events.append(_event(&"date_changed", float(boundary_hour)))
			events.append(_event(&"hourly", float(boundary_hour)))
		cursor = next_sample
	return events


## Returns the configured starting date plus a whole number of civil days.
func civil_date(day_offset: int = 0) -> Dictionary:
	return _date_at_day(_origin_day(_astronomy) + day_offset)


func _event(type: StringName, absolute_hour: float) -> Dictionary:
	var day_offset := floori(absolute_hour / HOURS_PER_DAY)
	return {
		&"type": type,
		&"absolute_hour": absolute_hour,
		&"hour": fposmod(absolute_hour, HOURS_PER_DAY),
		&"day_offset": day_offset,
		&"date": civil_date(day_offset),
	}


func _sun_crossing(start: float, end: float, sample: Callable) -> float:
	var start_height := float(sample.call(start))
	for _iteration in ROOT_ITERATIONS:
		var middle := (start + end) * 0.5
		var middle_height := float(sample.call(middle))
		if (middle_height >= 0.0) == (start_height >= 0.0):
			start = middle
		else:
			end = middle
	return (start + end) * 0.5


func _origin_day(astronomy: DynamicSkyAstronomy) -> int:
	if astronomy != null:
		var midnight := Time.get_unix_time_from_datetime_dict(astronomy.get_civil_date())
		return floori(float(midnight) / SECONDS_PER_DAY)
	if not _has_local_origin:
		var date := Time.get_date_dict_from_system()
		_local_origin_day = floori(float(Time.get_unix_time_from_datetime_dict(date)) / SECONDS_PER_DAY)
		_has_local_origin = true
	return _local_origin_day


func _date_at_day(civil_day: int) -> Dictionary:
	var date := Time.get_date_dict_from_unix_time(civil_day * SECONDS_PER_DAY)
	return {&"year": date.year, &"month": date.month, &"day": date.day}
