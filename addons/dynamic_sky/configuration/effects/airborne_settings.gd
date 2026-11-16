@tool
class_name DynamicSkyAirborneSettings
extends Resource
## Editable local airborne weather tuning, applied to the rig's AirborneWeather component.

@export_group("Weather Density")
## Peak near-ground mist density in heavy rain.
@export_range(0.0, 0.12, 0.001) var rain_density: float = 0.019:
	set(value):
		if rain_density == value:
			return
		rain_density = value
		emit_changed()

## Peak near-ground mist density from blowing snow.
@export_range(0.0, 0.12, 0.001) var snow_density: float = 0.033:
	set(value):
		if snow_density == value:
			return
		snow_density = value
		emit_changed()

## Peak near-ground haze density from moving sand and dust.
@export_range(0.0, 0.16, 0.001) var dust_density: float = 0.052:
	set(value):
		if dust_density == value:
			return
		dust_density = value
		emit_changed()

## Scattered ambient sky energy in airborne dust. Higher values soften dark dust pockets.
@export_range(0.0, 0.6, 0.01) var dust_ambient_scattering: float = 0.26:
	set(value):
		if dust_ambient_scattering == value:
			return
		dust_ambient_scattering = value
		emit_changed()

## Maximum low haze stirred up by strong dry wind.
@export_range(0.0, 0.04, 0.001) var dry_wind_density: float = 0.008:
	set(value):
		if dry_wind_density == value:
			return
		dry_wind_density = value
		emit_changed()

@export_group("Dust Particles")
## Scales suspended dust, bouncing grit and gust billows independently of the fog. Zero hides all three particle layers.
@export_range(0.0, 1.0, 0.01) var dust_particle_density_scale: float = 1.0:
	set(value):
		var density := clampf(value, 0.0, 1.0)
		if dust_particle_density_scale == density:
			return
		dust_particle_density_scale = density
		emit_changed()

@export_group("Shelter")
## Surfaces on these physics layers place the haze at ground level and shelter the camera.
@export_flags_3d_physics var shelter_mask: int = 1:
	set(value):
		if shelter_mask == value:
			return
		shelter_mask = value
		emit_changed()

## Distance to check above the camera for a roof, in meters.
@export_range(0.0, 40.0, 0.1, "suffix:m") var roof_probe_height: float = 12.0:
	set(value):
		if roof_probe_height == value:
			return
		roof_probe_height = value
		emit_changed()

## Distance to search below the camera for the ground, in meters.
@export_range(0.0, 100.0, 1.0, "suffix:m") var ground_probe_depth: float = 35.0:
	set(value):
		if ground_probe_depth == value:
			return
		ground_probe_depth = value
		emit_changed()

@export_group("Weather Color")
## Neutral mist tint in rain.
@export var rain_color: Color = Color(0.76, 0.82, 0.88):
	set(value):
		if rain_color == value:
			return
		rain_color = value
		emit_changed()

## Tint of wind-driven snow under an overcast sky.
@export var snow_color: Color = Color(0.84, 0.88, 0.93):
	set(value):
		if snow_color == value:
			return
		snow_color = value
		emit_changed()

## Warm mineral tint for airborne dust.
@export var dust_color: Color = Color(0.67, 0.56, 0.43):
	set(value):
		if dust_color == value:
			return
		dust_color = value
		emit_changed()
