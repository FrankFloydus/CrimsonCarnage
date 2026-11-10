@tool
class_name FirstPersonLookSettings
extends Resource
## Editable mouse aiming and Quake-style lateral camera tilt data.

## Rotation in degrees per unscaled mouse pixel, independent of frame rate and window stretch.
@export_range(0.001, 1.0, 0.001, "or_greater") var mouse_sensitivity: float = 0.12
## Maximum upward and downward pitch, in degrees; kept below vertical to prevent flipping.
@export_range(1.0, 89.9, 0.1) var pitch_limit: float = 89.0
## Maximum camera roll in degrees at full lateral speed. Zero disables lateral tilt.
@export_range(0.0, 15.0, 0.1) var maximum_tilt: float = 3.0:
	set(value):
		maximum_tilt = value
		notify_property_list_changed()
## Lateral speed in meters per second that produces the maximum camera roll.
@export_range(0.1, 30.0, 0.1, "or_greater") var full_tilt_speed: float = 6.0
## Camera roll convergence rate per second. Larger values make the tilt respond faster.
@export_range(0.1, 30.0, 0.1, "or_greater") var tilt_response: float = 10.0
## Stair camera spring response time, in seconds. Zero immediately disables height compensation.
@export_range(0.0, 1.0, 0.01) var stair_smoothing_time: float = 0.1


func _validate_property(property: Dictionary) -> void:
	if property.name == &"full_tilt_speed" and maximum_tilt == 0.0:
		property.usage &= ~PROPERTY_USAGE_EDITOR
