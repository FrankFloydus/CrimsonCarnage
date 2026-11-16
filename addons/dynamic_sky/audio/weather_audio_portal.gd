class_name DynamicSkyWeatherAudioPortal
extends Marker3D
## Lets outdoor weather sound through a visible opening near the listener.

const GROUP := &"dynamic_sky_weather_audio_portals"

## Enables audio leakage through this opening.
@export var enabled: bool = true

## Maximum listener distance from the opening in meters. Zero disables leakage.
@export_range(0.0, 100.0, 0.25, "or_greater", "suffix:m") var sample_range: float = 20.0

## Exponent of the distance fade. Larger values confine the effect closer to the opening.
@export_range(0.0, 8.0, 0.05, "or_greater") var distance_falloff_exponent: float = 2.0

## Strength of rain and snow leakage through the opening, from zero to one.
@export_range(0.0, 1.0, 0.01) var global_openness: float = 0.0

## Wind and dust leakage toward the incoming wind.
## In cardinal mode, the opening also contributes to the matching Rain and Wind sectors.
@export_range(0.0, 1.0, 0.01) var directional_openness: float = 0.55


func _enter_tree() -> void:
	add_to_group(GROUP)


## Returns the global and directional openness before visibility and direction checks.
func openness_at(distance: float) -> Vector2:
	if not enabled or distance >= sample_range:
		return Vector2.ZERO
	var weight := pow(1.0 - distance / sample_range, distance_falloff_exponent)
	return Vector2(global_openness, directional_openness) * weight
