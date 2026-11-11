@tool
class_name DynamicSkyWeather
extends Resource
## Editable targets for one weather condition.

## Cloud coverage, from a clear sky to a continuous cloud layer.
@export_range(0.0, 1.0, 0.01) var cloud_coverage: float = 0.0:
	set(value):
		cloud_coverage = clampf(value, 0.0, 1.0)
		emit_changed()

## Exponential distance fog density. Zero disables distance fog.
@export_range(0.0, 0.1, 0.0001, "or_greater") var fog_density: float = 0.0:
	set(value):
		fog_density = maxf(value, 0.0)
		emit_changed()

## Normalized weather fog strength for atmospheric effects, from zero to source Fog 10.
## Independent of physical exponential fog density; it does not change distance visibility.
@export_range(0.0, 1.0, 0.01) var fog_amount: float = 0.0:
	set(value):
		fog_amount = clampf(value, 0.0, 1.0)
		emit_changed()

## Rain emission as a fraction of the saved rain emitter's maximum.
@export_range(0.0, 1.0, 0.01) var rain: float = 0.0:
	set(value):
		rain = clampf(value, 0.0, 1.0)
		emit_changed()

## Snow emission as a fraction of the saved snow emitter's maximum.
@export_range(0.0, 1.0, 0.01) var snow: float = 0.0:
	set(value):
		snow = clampf(value, 0.0, 1.0)
		emit_changed()

## Coverage this weather can build on a bare surface. Existing snow melts through temperature.
@export_range(0.0, 1.0, 0.01) var snow_coverage_limit: float = 1.0:
	set(value):
		snow_coverage_limit = clampf(value, 0.0, 1.0)
		emit_changed()

## Airborne dust concentration as a fraction of the dust emitter's maximum.
@export_range(0.0, 1.0, 0.01) var dust: float = 0.0:
	set(value):
		dust = clampf(value, 0.0, 1.0)
		emit_changed()

## Horizontal wind in meters per second along world X and Z.
@export var wind: Vector2 = Vector2.ZERO:
	set(value):
		wind = value
		emit_changed()

## Amount of local variation around the horizontal wind velocity.
@export_range(0.0, 1.0, 0.01) var gustiness: float = 0.0:
	set(value):
		gustiness = clampf(value, 0.0, 1.0)
		emit_changed()

## Mean number of automatic lightning events with a visible channel per real minute.
@export_range(0.0, 12.0, 0.1) var lightning_rate: float = 0.0:
	set(value):
		lightning_rate = clampf(value, 0.0, 12.0)
		emit_changed()

## Mean number of obscured cloud flashes with delayed thunder per real minute.
@export_range(0.0, 12.0, 0.1) var sheet_lightning_rate: float = 0.0:
	set(value):
		sheet_lightning_rate = clampf(value, 0.0, 12.0)
		emit_changed()

## Air-temperature change from the clear-condition cycle, in degrees Celsius.
@export_range(-70.0, 70.0, 0.1, "suffix:°C") var temperature_offset: float = 0.0:
	set(value):
		temperature_offset = clampf(value, -70.0, 70.0)
		emit_changed()


func sample() -> Dictionary[StringName, Variant]:
	return {
		&"cloud_coverage": cloud_coverage,
		&"fog_density": fog_density,
		&"fog_amount": fog_amount,
		&"rain": rain,
		&"snow": snow,
		&"snow_coverage_limit": snow_coverage_limit,
		&"dust": dust,
		&"wind": wind,
		&"gustiness": gustiness,
		&"lightning_rate": lightning_rate,
		&"sheet_lightning_rate": sheet_lightning_rate,
		&"temperature_offset": temperature_offset,
	}
