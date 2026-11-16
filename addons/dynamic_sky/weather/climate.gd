@tool
class_name DynamicSkyClimate
extends Resource
## Defines when automatic weather changes and which profiles are likely in each season.

enum Schedule { REAL_SECONDS, SIMULATED_HOUR, SIMULATED_DAY }
enum Season { SPRING, SUMMER, AUTUMN, WINTER }

## Check schedule. Hour and day schedules advance with the rig's simulation clock.
@export var schedule: Schedule = Schedule.REAL_SECONDS

## Shortest interval between checks when using real seconds.
@export_range(1.0, 3600.0, 1.0, "or_greater", "suffix:s") var minimum_interval: float = 50.0

## Longest interval between checks when using real seconds.
@export_range(1.0, 3600.0, 1.0, "or_greater", "suffix:s") var maximum_interval: float = 110.0

## Real seconds to blend to the chosen weather.
@export_range(0.0, 120.0, 0.1, "or_greater", "suffix:s") var blend_seconds: float = 9.0

## Season used when a level does not supply a calendar.
@export var season: Season = Season.SUMMER

## Weather profiles and their relative seasonal likelihoods.
@export var probabilities: Array[DynamicSkyWeatherProbability]


func sample_interval(random: RandomNumberGenerator) -> float:
	var low := maxf(minimum_interval, 1.0)
	return random.randf_range(low, maxf(maximum_interval, low))


func sample_weather(season_index: int, random: RandomNumberGenerator, accepts: Callable = Callable()) -> DynamicSkyWeather:
	var total := 0.0
	for entry in probabilities:
		if entry != null and entry.weather != null and (not accepts.is_valid() or accepts.call(entry.weather)):
			total += entry.weight_for(season_index)
	if total <= 0.0:
		return null

	var remaining := random.randf() * total
	var last_weather: DynamicSkyWeather
	for entry in probabilities:
		if entry == null or entry.weather == null or (accepts.is_valid() and not accepts.call(entry.weather)):
			continue
		var weight := entry.weight_for(season_index)
		if weight == 0.0:
			continue
		last_weather = entry.weather
		remaining -= weight
		if remaining <= 0.0:
			return entry.weather
	return last_weather
