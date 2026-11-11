@tool
class_name DynamicSkyWindFogSettings
extends Resource
## Selects the near-camera wind fog and authors its depth-aware ray integration.

## Rendering path for the local weather haze.
enum Mode {
	## Uses the existing lit, moving FogVolume in Forward+.
	VOLUMETRIC,
	## Integrates moving world-space fog along the visible scene rays.
	POST_PROCESS,
	## Disables the local haze. Distant environment fog remains independently authored.
	DISABLED,
}

## Chooses volumetric or post-process local wind fog.
@export var mode: Mode = Mode.VOLUMETRIC:
	set(value):
		if mode == value:
			return
		mode = value
		emit_changed()

@export_group("Weather")
## Overall multiplier for post-process fog. Zero disables this pass.
@export_range(0.0, 2.0, 0.01) var intensity_scale: float = 1.0:
	set(value):
		if intensity_scale == value:
			return
		intensity_scale = value
		emit_changed()

## Source-scale post-process wind fog amount in rain.
@export_range(0.0, 1.0, 0.001) var rain_amount: float = 0.1372:
	set(value):
		if rain_amount == value:
			return
		rain_amount = value
		emit_changed()

## Source-scale amount in strong wind and heavy rain.
@export_range(0.0, 1.0, 0.001) var storm_amount: float = 0.3967:
	set(value):
		if storm_amount == value:
			return
		storm_amount = value
		emit_changed()

## Source-scale amount in windblown snow.
@export_range(0.0, 1.0, 0.001) var blizzard_amount: float = 0.56:
	set(value):
		if blizzard_amount == value:
			return
		blizzard_amount = value
		emit_changed()

## Source-scale amount in a full dust storm.
@export_range(0.0, 1.0, 0.001) var dust_amount: float = 0.70:
	set(value):
		if dust_amount == value:
			return
		dust_amount = value
		emit_changed()

## Maximum post-process haze from strong dry wind.
@export_range(0.0, 1.0, 0.001) var dry_wind_amount: float = 0.09:
	set(value):
		if dry_wind_amount == value:
			return
		dry_wind_amount = value
		emit_changed()

@export_group("Ray Integration")
## Maximum distance from the camera for integrated fog, in meters.
@export_range(2.0, 40.0, 0.1, "suffix:m") var trace_distance_meters: float = 18.0:
	set(value):
		if trace_distance_meters == value:
			return
		trace_distance_meters = value
		emit_changed()

## Distance between density samples. Smaller values preserve more detail, at greater GPU cost.
@export_range(0.4, 4.0, 0.1, "suffix:m") var sample_step_meters: float = 1.2:
	set(value):
		if sample_step_meters == value:
			return
		sample_step_meters = value
		emit_changed()

## World-space size of broad fog structures, in meters.
@export_range(2.0, 100.0, 0.5, "suffix:m") var noise_scale_meters: float = 20.0:
	set(value):
		if noise_scale_meters == value:
			return
		noise_scale_meters = value
		emit_changed()

## Extinction per meter at full density and full weather amount.
@export_range(0.0, 0.3, 0.001) var extinction_per_meter: float = 0.12:
	set(value):
		if extinction_per_meter == value:
			return
		extinction_per_meter = value
		emit_changed()

## Strength of the moving density pockets. Zero gives uniform fog.
@export_range(0.0, 1.0, 0.01) var density_variation: float = 0.83:
	set(value):
		if density_variation == value:
			return
		density_variation = value
		emit_changed()
