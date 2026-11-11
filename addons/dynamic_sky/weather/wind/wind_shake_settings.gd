@tool
class_name DynamicSkyWindShakeSettings
extends Resource
## Editable camera response to outdoor wind. The component is separately enabled.

@export_group("Motion")
## Wind speed below which the camera stays still, in meters per second.
@export_range(0.0, 50.0, 0.1, "suffix:m/s") var start_wind_speed: float = 8.0:
	set(value):
		if start_wind_speed == value:
			return
		start_wind_speed = value
		emit_changed()

## Wind speed that produces the full authored motion, in meters per second.
@export_range(0.1, 70.0, 0.1, "suffix:m/s") var full_wind_speed: float = 24.0:
	set(value):
		if full_wind_speed == value:
			return
		full_wind_speed = value
		emit_changed()

## Maximum horizontal and vertical camera offsets in meters at full wind exposure.
@export var maximum_offset_meters: Vector2 = Vector2(0.025, 0.017):
	set(value):
		if maximum_offset_meters == value:
			return
		maximum_offset_meters = value
		emit_changed()

## Frequency of the broad camera movement, in oscillations per real second.
@export_range(0.2, 12.0, 0.1, "suffix:Hz") var frequency_hz: float = 2.3:
	set(value):
		if frequency_hz == value:
			return
		frequency_hz = value
		emit_changed()

## Rate at which the camera response follows gusts and shelter changes, per second.
@export_range(0.5, 25.0, 0.1) var response_rate: float = 7.0:
	set(value):
		if response_rate == value:
			return
		response_rate = value
		emit_changed()

@export_group("Shelter")
## Physics layers that block incoming wind and shield the camera. Zero disables the probes.
@export_flags_3d_physics var shelter_mask: int = 1:
	set(value):
		if shelter_mask == value:
			return
		shelter_mask = value
		emit_changed()

## Reach of the ray looking into the airflow, in meters.
@export_range(0.5, 30.0, 0.1, "suffix:m") var upwind_probe_distance: float = 7.0:
	set(value):
		if upwind_probe_distance == value:
			return
		upwind_probe_distance = value
		emit_changed()

## Distance above the camera to search for a protecting roof, in meters.
@export_range(0.5, 25.0, 0.1, "suffix:m") var roof_probe_distance: float = 9.0:
	set(value):
		if roof_probe_distance == value:
			return
		roof_probe_distance = value
		emit_changed()

## Real seconds between shelter checks.
@export_range(0.05, 1.0, 0.01, "suffix:s") var shelter_sample_interval: float = 0.13:
	set(value):
		if shelter_sample_interval == value:
			return
		shelter_sample_interval = value
		emit_changed()
