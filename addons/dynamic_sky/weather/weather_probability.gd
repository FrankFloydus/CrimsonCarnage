@tool
class_name DynamicSkyWeatherProbability
extends Resource
## Seasonal weights for one weather profile in a climate.

## Profile selected when this entry is drawn.
@export var weather: DynamicSkyWeather

## Relative chance in spring, summer, autumn, and winter, in that order.
@export var seasonal_weights: Vector4 = Vector4.ONE


func weight_for(season: int) -> float:
	return maxf(seasonal_weights[clampi(season, 0, 3)], 0.0)
