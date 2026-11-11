@tool
class_name DynamicSkyRainbowSettings
extends Resource
## Authors primary and secondary rainbows and their response to lingering moisture.

## Enables the anti-solar rainbow effect. Disabled by default, matching the source feature.
@export var enabled: bool = false:
	set(value):
		enabled = value
		emit_changed()

## Peak rainbow radiance before sunlight, spectral alpha, and sky exposure are applied.
@export_range(0.0, 1.0, 0.01) var max_strength: float = 0.2:
	set(value):
		max_strength = clampf(value, 0.0, 1.0)
		emit_changed()

## Contribution from normalized rain, reaching its full weight at rain amount 0.4.
@export_range(0.0, 1.0, 0.01) var strength_from_rain: float = 0.5:
	set(value):
		strength_from_rain = clampf(value, 0.0, 1.0)
		emit_changed()

## Contribution from normalized source fog, ramping between fog amounts 0.3 and 0.7.
@export_range(0.0, 1.0, 0.01) var strength_from_fog: float = 0.5:
	set(value):
		strength_from_fog = clampf(value, 0.0, 1.0)
		emit_changed()

## Minimum moisture strength in dry weather. Sunlight and visibility masks still apply.
@export_range(0.0, 1.0, 0.01) var strength_in_any_weather: float = 0.0:
	set(value):
		strength_in_any_weather = clampf(value, 0.0, 1.0)
		emit_changed()

## Real seconds for full moisture strength to disappear after rain and fog stop.
@export_range(0.0, 500.0, 1.0, "suffix:s") var persistence_seconds: float = 100.0:
	set(value):
		persistence_seconds = clampf(value, 0.0, 500.0)
		emit_changed()

## Primary red-edge angle from the anti-solar direction, in degrees.
@export_range(35.0, 48.0, 0.1, "degrees") var primary_angle_degrees: float = 42.0:
	set(value):
		primary_angle_degrees = clampf(value, 35.0, 48.0)
		emit_changed()

## Angular distance from the primary's inner blue band to its outer red band.
@export_range(0.5, 6.0, 0.1, "degrees") var primary_width_degrees: float = 2.0:
	set(value):
		primary_width_degrees = clampf(value, 0.5, 6.0)
		emit_changed()

## Brightness of the wider, color-reversed secondary bow relative to the primary.
@export_range(0.0, 1.0, 0.01) var secondary_strength: float = 0.28:
	set(value):
		secondary_strength = clampf(value, 0.0, 1.0)
		emit_changed()

## Secondary red-edge angle from the anti-solar direction, in degrees.
@export_range(47.0, 60.0, 0.1, "degrees") var secondary_angle_degrees: float = 51.0:
	set(value):
		secondary_angle_degrees = clampf(value, 47.0, 60.0)
		emit_changed()

## Angular distance from the secondary's inner red band to its outer blue band.
@export_range(0.5, 8.0, 0.1, "degrees") var secondary_width_degrees: float = 2.5:
	set(value):
		secondary_width_degrees = clampf(value, 0.5, 8.0)
		emit_changed()

## Fraction of the effect removed above the cloud layer. Zero allows it at every altitude.
@export_range(0.0, 1.0, 0.01) var mask_above_clouds: float = 1.0:
	set(value):
		mask_above_clouds = clampf(value, 0.0, 1.0)
		emit_changed()

## Fraction of the effect removed below the active water surface.
@export_range(0.0, 1.0, 0.01) var mask_below_water: float = 1.0:
	set(value):
		mask_below_water = clampf(value, 0.0, 1.0)
		emit_changed()


## Returns target moisture strength. Rain and fog use normalized source weather amounts.
func weather_target(rain: float, fog_amount: float) -> float:
	if not enabled:
		return 0.0
	var rain_strength := clampf((rain - 0.004) / 0.396, 0.0, 1.0) * strength_from_rain
	var fog_strength := clampf((fog_amount - 0.3) / 0.4, 0.0, 1.0) * strength_from_fog
	return maxf(strength_in_any_weather, rain_strength + fog_strength)


## Moves moisture toward its target at one unit per second, with the authored dry fade.
func advance_strength(current: float, target: float, delta: float) -> float:
	if not enabled:
		return 0.0
	var speed := 1.0
	if target < current:
		if persistence_seconds <= 0.0:
			return maxf(target, 0.0)
		speed = 1.0 / persistence_seconds
	return move_toward(current, maxf(target, 0.0), maxf(delta, 0.0) * speed)


## Samples the source's overcast visibility ramp from normalized cloud coverage.
## Volumetric mode uses the same density rescaling as the reference cloud material.
func cloud_transmission(cloud_coverage: float, volumetric: bool) -> float:
	var density := clampf(cloud_coverage, 0.0, 1.0) * 3.0
	if volumetric:
		var clear_bias := lerpf(0.2, 0.0, clampf(density / 0.2, 0.0, 1.0))
		density = clampf((density - clear_bias) * 1.15, -0.2, 3.0)
	return 1.0 - clampf((density - 1.4) * 2.0, 0.0, 1.0)


## Binds settings and runtime moisture to a sky material without applying sky exposure.
## Sun intensity is a ratio to the rig's authored clear-noon energy. Space disables the effect.
func apply_to(
	material: ShaderMaterial,
	moisture: float,
	sun_intensity_ratio: float = 1.0,
	cloud_visibility: float = 1.0,
	above_clouds: float = 0.0,
	underwater: float = 0.0,
	space_mode: bool = false,
) -> void:
	if material == null:
		return
	var exposure := (1.0 - clampf(above_clouds, 0.0, 1.0) * mask_above_clouds)
	exposure *= 1.0 - clampf(underwater, 0.0, 1.0) * mask_below_water
	material.set_shader_parameter(&"rainbow_enabled", enabled and not space_mode)
	# Source default Sun energy 5 / material divisor 20 gives a clear-noon factor of 0.25.
	material.set_shader_parameter(
		&"rainbow_strength", maxf(moisture, 0.0) * max_strength * maxf(sun_intensity_ratio, 0.0) * 0.25
	)
	material.set_shader_parameter(&"rainbow_cloud_transmission", clampf(cloud_visibility, 0.0, 1.0))
	material.set_shader_parameter(&"rainbow_exposure", exposure)
	material.set_shader_parameter(&"rainbow_primary_angle_degrees", primary_angle_degrees)
	material.set_shader_parameter(&"rainbow_primary_width_degrees", primary_width_degrees)
	material.set_shader_parameter(&"rainbow_secondary_strength", secondary_strength)
	material.set_shader_parameter(&"rainbow_secondary_angle_degrees", secondary_angle_degrees)
	material.set_shader_parameter(&"rainbow_secondary_width_degrees", secondary_width_degrees)
