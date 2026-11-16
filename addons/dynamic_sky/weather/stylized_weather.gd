@tool
class_name DynamicSkyStylizedWeather
extends DynamicSkyWeather
## Weather targets with an authored sky and lighting palette for Stylized mode.

@export_group("Sky Palette")
## Daytime sky color directly overhead.
@export var sky_zenith_tint: Color = Color(0.24, 0.40, 0.55):
	set(value):
		sky_zenith_tint = value
		emit_changed()

## Daytime sky color on the horizon.
@export var sky_horizon_tint: Color = Color(0.66, 0.73, 0.75):
	set(value):
		sky_horizon_tint = value
		emit_changed()

## Color directly overhead after dusk. The horizon approaches the nighttime fog color.
@export var night_sky_tint: Color = Color(0.07, 0.10, 0.19):
	set(value):
		night_sky_tint = value
		emit_changed()

## Color of the twilight sky towards the Sun.
@export var twilight_tint: Color = Color(0.95, 0.53, 0.30):
	set(value):
		twilight_tint = value
		emit_changed()

## Color of the darker parts of the cloud field in daylight.
@export var cloud_shade_tint: Color = Color(0.33, 0.39, 0.47):
	set(value):
		cloud_shade_tint = value
		emit_changed()

## Color of the brighter parts of the cloud field in daylight.
@export var cloud_light_tint: Color = Color(0.83, 0.87, 0.90):
	set(value):
		cloud_light_tint = value
		emit_changed()

## Brightness of the existing aurora curtains after dusk for this preset.
@export_range(0.0, 3.0, 0.01) var aurora_strength: float = 0.0:
	set(value):
		aurora_strength = clampf(value, 0.0, 3.0)
		emit_changed()

@export_group("Fog and Light")
## Daytime distance fog color, also used where the sky meets distant terrain.
@export var day_fog_tint: Color = Color(0.54, 0.65, 0.70):
	set(value):
		day_fog_tint = value
		emit_changed()

## Distance fog color after dusk.
@export var night_fog_tint: Color = Color(0.12, 0.17, 0.26):
	set(value):
		night_fog_tint = value
		emit_changed()

## Tint applied to the existing daytime and twilight Sun light.
@export var sunlight_tint: Color = Color(1.0, 0.93, 0.80):
	set(value):
		sunlight_tint = value
		emit_changed()

## Tint applied to the Moon light after dusk.
@export var moonlight_tint: Color = Color(0.52, 0.68, 0.93):
	set(value):
		moonlight_tint = value
		emit_changed()

## Direct sunlight multiplier. A low value keeps fog and overcast weather diffuse.
@export_range(0.0, 2.0, 0.01) var sunlight_strength: float = 1.0:
	set(value):
		sunlight_strength = clampf(value, 0.0, 2.0)
		emit_changed()

@export_group("Stylized Particles")
## Coarse particle size for this weather, relative to the stylized emitter's defaults.
@export_range(0.1, 2.0, 0.01) var particle_scale: float = 1.0:
	set(value):
		particle_scale = clampf(value, 0.1, 2.0)
		emit_changed()

## Particle opacity for this weather, relative to the stylized emitter's defaults.
@export_range(0.0, 1.5, 0.01) var particle_opacity_scale: float = 1.0:
	set(value):
		particle_opacity_scale = clampf(value, 0.0, 1.5)
		emit_changed()


func sample() -> Dictionary[StringName, Variant]:
	var channels := super()
	channels[&"sky_zenith_tint"] = sky_zenith_tint
	channels[&"sky_horizon_tint"] = sky_horizon_tint
	channels[&"night_sky_tint"] = night_sky_tint
	channels[&"twilight_tint"] = twilight_tint
	channels[&"cloud_shade_tint"] = cloud_shade_tint
	channels[&"cloud_light_tint"] = cloud_light_tint
	channels[&"aurora_strength"] = aurora_strength
	channels[&"day_fog_tint"] = day_fog_tint
	channels[&"night_fog_tint"] = night_fog_tint
	channels[&"sunlight_tint"] = sunlight_tint
	channels[&"moonlight_tint"] = moonlight_tint
	channels[&"sunlight_strength"] = sunlight_strength
	channels[&"particle_scale"] = particle_scale
	channels[&"particle_opacity_scale"] = particle_opacity_scale
	return channels
