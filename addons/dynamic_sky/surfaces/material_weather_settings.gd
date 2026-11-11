@tool
class_name DynamicSkyMaterialWeatherSettings
extends Resource
## Response shared by compatible custom shaders discovered by the DynamicSky root.

## Automatically drives geometry whose shader includes the Dynamic Sky weather layer.
@export var enabled: bool = true:
	set(value):
		enabled = value
		emit_changed()

## Fraction of precipitation reaching automatically managed surfaces.
@export_range(0.0, 1.0, 0.01) var exposure: float = 1.0:
	set(value):
		exposure = clampf(value, 0.0, 1.0)
		emit_changed()

## Seconds of full rain required to saturate a dry surface.
@export_range(0.1, 600.0, 0.1, "suffix:s") var wetting_seconds: float = 12.0:
	set(value):
		wetting_seconds = maxf(value, 0.1)
		emit_changed()

## Seconds required to dry a saturated surface in temperate clear weather.
@export_range(0.1, 1200.0, 0.1, "suffix:s") var drying_seconds: float = 65.0:
	set(value):
		drying_seconds = maxf(value, 0.1)
		emit_changed()

## Seconds of full snowfall required to cover a surface below freezing.
@export_range(0.1, 600.0, 0.1, "suffix:s") var snow_seconds: float = 22.0:
	set(value):
		snow_seconds = maxf(value, 0.1)
		emit_changed()

## Seconds for full snow cover to melt at eight degrees Celsius without rain.
@export_range(0.1, 1200.0, 0.1, "suffix:s") var thaw_seconds: float = 120.0:
	set(value):
		thaw_seconds = maxf(value, 0.1)
		emit_changed()

## Seconds of full dust intensity required to coat a surface.
@export_range(0.1, 600.0, 0.1, "suffix:s") var dust_seconds: float = 19.0:
	set(value):
		dust_seconds = maxf(value, 0.1)
		emit_changed()

## Seconds of full rain required to wash away a complete dust coating.
@export_range(0.1, 1200.0, 0.1, "suffix:s") var wash_seconds: float = 16.0:
	set(value):
		wash_seconds = maxf(value, 0.1)
		emit_changed()
