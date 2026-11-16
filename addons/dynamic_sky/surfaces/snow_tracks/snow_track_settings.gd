@tool
class_name DynamicSkySnowTrackSettings
extends Resource
## Physical snow layer and sampling density for an opted-in track receiver.

## Uncompressed height at full accumulation, in meters above the substrate.
@export_range(0.02, 0.50, 0.005, "suffix:m") var snow_depth_meters: float = 0.14:
	set(value):
		snow_depth_meters = clampf(value, 0.02, 0.50)
		emit_changed()

## Fraction of the local snow depth removed by a full-pressure mark.
@export_range(0.0, 0.95, 0.01) var compression: float = 0.80:
	set(value):
		compression = clampf(value, 0.0, 0.95)
		emit_changed()

## Maximum height of snow displaced toward the edge of a full-pressure mark, in meters.
@export_range(0.0, 0.08, 0.001, "suffix:m") var rim_height_meters: float = 0.022:
	set(value):
		rim_height_meters = clampf(value, 0.0, 0.08)
		emit_changed()

## Fraction of the track slope used for lighting. This leaves the snow displacement and contact depth unchanged.
@export_range(0.0, 1.0, 0.01) var normal_strength: float = 1.0:
	set(value):
		normal_strength = clampf(value, 0.0, 1.0)
		emit_changed()

## Restores full track relief in the lighting as the main camera approaches a grazing angle.
## A Normal Strength of zero keeps track normals flat at all angles.
@export var retain_grazing_relief: bool = false:
	set(value):
		retain_grazing_relief = value
		emit_changed()

## Desired horizontal sample spacing in meters. The field uses at most 512 samples on each axis.
@export_range(0.015, 0.10, 0.005, "suffix:m") var texel_size_meters: float = 0.025:
	set(value):
		texel_size_meters = clampf(value, 0.015, 0.10)
		emit_changed()
