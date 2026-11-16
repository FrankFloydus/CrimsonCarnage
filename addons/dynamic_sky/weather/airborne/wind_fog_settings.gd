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
	## Uses additive, depth-bounded wind fog in snowfall and the lit volume in other weather.
	SOURCE_SNOW,
	## Uses depth-bounded fog in snow and dust, with separate drifting dust cards and spots.
	SOURCE_SNOW_AND_DUST,
}

## Chooses the local fog path and, in Source Snow and Dust, enables the finite dust particle field.
@export var mode: Mode = Mode.VOLUMETRIC:
	set(value):
		if mode == value:
			return
		mode = value
		notify_property_list_changed()
		emit_changed()

@export_group("Weather")
## Overall multiplier for screen-space wind fog. Zero disables its contribution.
@export_range(0.0, 2.0, 0.01) var intensity_scale: float = 1.0:
	set(value):
		if intensity_scale == value:
			return
		intensity_scale = value
		emit_changed()

## Legacy Post Process wind fog amount in rain.
@export_range(0.0, 1.0, 0.001) var rain_amount: float = 0.1372:
	set(value):
		if rain_amount == value:
			return
		rain_amount = value
		emit_changed()

## Legacy Post Process wind fog amount in strong wind and heavy rain.
@export_range(0.0, 1.0, 0.001) var storm_amount: float = 0.3967:
	set(value):
		if storm_amount == value:
			return
		storm_amount = value
		emit_changed()

## Legacy Post Process wind fog amount in windblown snow.
@export_range(0.0, 1.0, 0.001) var blizzard_amount: float = 0.56:
	set(value):
		if blizzard_amount == value:
			return
		blizzard_amount = value
		emit_changed()

## Depth-integrated wind fog amount in a full dust storm.
@export_range(0.0, 1.0, 0.001) var dust_amount: float = 0.70:
	set(value):
		if dust_amount == value:
			return
		dust_amount = value
		emit_changed()

## Matches daylight sky and distance-fog scattering in heavy dust when using Sky Atmosphere.
@export var calibrate_daylight_dust: bool = false:
	set(value):
		if calibrate_daylight_dust == value:
			return
		calibrate_daylight_dust = value
		emit_changed()

## Maximum Legacy Post Process haze from strong dry wind.
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

## Legacy extinction per meter. Source fog scales additive scattering relative to the 0.12 default.
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


func _validate_property(property: Dictionary) -> void:
	match property.name:
		&"rain_amount", &"storm_amount", &"blizzard_amount", &"dry_wind_amount":
			if mode != Mode.POST_PROCESS:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		&"dust_amount":
			if mode != Mode.POST_PROCESS and mode != Mode.SOURCE_SNOW_AND_DUST:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		&"calibrate_daylight_dust":
			if mode != Mode.SOURCE_SNOW_AND_DUST:
				property.usage &= ~PROPERTY_USAGE_EDITOR
		&"intensity_scale", &"trace_distance_meters", &"sample_step_meters", &"noise_scale_meters", &"extinction_per_meter", &"density_variation":
			if mode == Mode.VOLUMETRIC or mode == Mode.DISABLED:
				property.usage &= ~PROPERTY_USAGE_EDITOR
