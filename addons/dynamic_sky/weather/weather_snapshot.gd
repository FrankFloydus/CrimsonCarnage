@tool
class_name DynamicSkySnapshot
extends Resource
## Captures the global sky and weather state for an explicit save or restore.

## Local clock hour in the range [0, 24).
@export_range(0.0, 24.0, 0.01, "suffix:h") var time_of_day: float = 14.0

## Calendar days elapsed from the rig's configured starting date.
@export var day_offset: int = 0

## Real seconds for a full day. Zero leaves the clock paused.
@export_range(0.0, 3600.0, 1.0, "or_greater", "suffix:s") var day_length_seconds: float = 0.0

## Whether runtime resumes following the computer clock after restore.
@export var use_system_time: bool = false

## Shader-space offset accumulated by cloud movement.
@export var cloud_offset: Vector2 = Vector2.ZERO

## Phase of the local wind gust pattern, in radians.
@export var wind_phase: float = 0.0

## Lingering rainbow moisture before sunlight, clouds, and observer visibility masks.
@export_range(0.0, 2.0, 0.01) var rainbow_moisture: float = 0.0

## Cloud rendering mode selected on the rig.
@export var cloud_mode: int = 0

## Sky color rendering mode selected on the rig.
@export var color_mode: int = 0

## Half-resolution Balanced or full-resolution High volumetric sampling.
@export_enum("Balanced", "High") var volumetric_quality: int = 0

## Global weather channels visible at the instant of capture.
@export var current_weather: DynamicSkyWeather

## Weather channels at the start of a running transition. Empty when idle.
@export var transition_from: DynamicSkyWeather

## Weather channels at the end of a running transition. Empty when idle.
@export var transition_to: DynamicSkyWeather

## Real seconds already spent in the running transition.
@export_range(0.0, 3600.0, 0.01, "or_greater", "suffix:s") var transition_elapsed: float = 0.0

## Total real seconds of the running transition. Zero indicates no transition.
@export_range(0.0, 3600.0, 0.01, "or_greater", "suffix:s") var transition_seconds: float = 0.0
