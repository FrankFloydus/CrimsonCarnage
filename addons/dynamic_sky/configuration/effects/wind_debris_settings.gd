@tool
class_name DynamicSkyWindDebrisSettings
extends Resource
## Editable loose vegetation debris tuning, applied to the rig's WindDebris component.

## Enables loose vegetation debris. Dust particles and airborne mist have separate controls.
@export var enabled: bool = false:
	set(value):
		if enabled == value:
			return
		enabled = value
		emit_changed()

@export_group("Emission")
## Wind speed below which debris does not spawn, in meters per second.
@export_range(0.0, 40.0, 0.1, "suffix:m/s") var start_wind_speed: float = 7.5:
	set(value):
		if start_wind_speed == value:
			return
		start_wind_speed = value
		emit_changed()

## Wind speed for full authored emission, in meters per second.
@export_range(1.0, 60.0, 0.1, "suffix:m/s") var full_wind_speed: float = 16.5:
	set(value):
		if full_wind_speed == value:
			return
		full_wind_speed = value
		emit_changed()

## Uses the saved GPU heightfield to reject sheltered spawns and settle debris on surfaces.
@export var surface_collision_enabled: bool = true:
	set(value):
		if surface_collision_enabled == value:
			return
		surface_collision_enabled = value
		emit_changed()

@export_group("Shelter")
## Physics layers that shelter the observer from nearby wind debris. Zero skips the ray tests.
@export_flags_3d_physics var shelter_mask: int = 1:
	set(value):
		if shelter_mask == value:
			return
		shelter_mask = value
		emit_changed()

## Vertical reach of the roof exposure probes, in meters.
@export_range(0.5, 25.0, 0.1, "suffix:m") var roof_probe_distance: float = 9.0:
	set(value):
		if roof_probe_distance == value:
			return
		roof_probe_distance = value
		emit_changed()

## Horizontal reach of the probes looking into the wind, in meters.
@export_range(0.5, 25.0, 0.1, "suffix:m") var upwind_probe_distance: float = 6.0:
	set(value):
		if upwind_probe_distance == value:
			return
		upwind_probe_distance = value
		emit_changed()

## Real seconds between sets of shelter probes.
@export_range(0.05, 1.0, 0.01, "suffix:s") var shelter_sample_interval: float = 0.13:
	set(value):
		if shelter_sample_interval == value:
			return
		shelter_sample_interval = value
		emit_changed()
