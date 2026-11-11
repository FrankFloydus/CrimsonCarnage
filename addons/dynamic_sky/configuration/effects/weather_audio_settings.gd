@tool
class_name DynamicSkyWeatherAudioSettings
extends Resource
## Authored spatial weather mix, cover sampling, and thunder propagation settings.

## Physics layers that block the path from outdoor sound to the listener. Zero ignores shelter.
@export_flags_3d_physics var occlusion_mask: int = 1:
	set(value):
		occlusion_mask = value
		emit_changed()

## How far roof and upwind rays search for shelter, in meters.
@export_range(1.0, 100.0, 0.5, "suffix:m") var cover_probe_distance: float = 24.0:
	set(value):
		cover_probe_distance = value
		emit_changed()

## Spacing of neighboring cover rays, in meters. Larger values soften the transition at edges.
@export_range(0.1, 3.0, 0.05, "suffix:m") var cover_probe_spread: float = 0.55:
	set(value):
		cover_probe_spread = value
		emit_changed()

## Real seconds between cover samples.
@export_range(0.05, 1.0, 0.01, "suffix:s") var cover_sample_interval: float = 0.12:
	set(value):
		cover_sample_interval = value
		emit_changed()

## Real seconds for weather and shelter changes to settle in the mix.
@export_range(0.05, 2.0, 0.01, "suffix:s") var mix_response_seconds: float = 0.32:
	set(value):
		mix_response_seconds = value
		emit_changed()

## Wind speed in meters per second at which the wind layer reaches its authored volume.
@export_range(1.0, 60.0, 0.5, "suffix:m/s") var full_wind_speed: float = 12.0:
	set(value):
		full_wind_speed = value
		emit_changed()

## Sound propagation speed in meters per second. Used to delay thunder after a strike.
@export_range(200.0, 450.0, 1.0, "suffix:m/s") var speed_of_sound: float = 343.0:
	set(value):
		speed_of_sound = value
		emit_changed()

## Maximum distance from which thunder can be heard, in meters.
@export_range(50.0, 10000.0, 10.0, "or_greater", "suffix:m") var thunder_range: float = 6400.0:
	set(value):
		thunder_range = value
		emit_changed()


func _init() -> void:
	resource_local_to_scene = true
