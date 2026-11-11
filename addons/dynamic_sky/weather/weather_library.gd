@tool
class_name DynamicSkyWeatherLibrary
extends Resource
## Stores reusable authored weather presets for sky rigs and their selection interfaces.

## Ordered weather presets available to scenes that use this library.
@export var presets: Array[DynamicSkyWeather] = []
