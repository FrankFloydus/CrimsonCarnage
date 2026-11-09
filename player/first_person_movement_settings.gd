@tool
class_name FirstPersonMovementSettings
extends Resource
## Editable normal speed, gait multipliers and locomotion physics.

@export_group("Movement Baseline")
## Normal running speed in meters per second before gait multipliers. Zero disables horizontal movement.
@export_range(0.0, 30.0, 0.1, "or_greater") var normal_run_speed: float = 4.0:
	set(value):
		normal_run_speed = value
		notify_property_list_changed()

@export_group("Movement Multipliers")
## Fraction of normal running speed while the walk modifier is held.
## Also multiplies crouched speed for crouch walking. Zero prevents movement in those gaits.
@export_range(0.0, 5.0, 0.05, "or_greater") var walk_speed_multiplier: float = 0.5
## Multiplier of normal running speed while sprint is selected.
@export_range(0.0, 5.0, 0.05, "or_greater") var sprint_speed_multiplier: float = 1.5
## Fraction of normal running speed while crouched. Crouch walking also applies the walk multiplier.
@export_range(0.0, 5.0, 0.05, "or_greater") var crouch_speed_multiplier: float = 0.6

@export_group("Acceleration")
## Horizontal acceleration while grounded, in meters per second squared.
@export_range(0.1, 100.0, 0.1, "or_greater") var ground_acceleration: float = 30.0
## Horizontal braking with no movement input while grounded, in meters per second squared.
@export_range(0.1, 100.0, 0.1, "or_greater") var ground_deceleration: float = 40.0
## Horizontal acceleration with movement input in the air, in meters per second squared.
@export_range(0.0, 100.0, 0.1, "or_greater") var air_acceleration: float = 9.0
## Horizontal braking with no movement input in the air, in meters per second squared.
@export_range(0.0, 100.0, 0.1, "or_greater") var air_deceleration: float = 2.0

@export_group("Jump and Gravity")
## Downward acceleration, in meters per second squared; independent of project physics gravity.
@export_range(0.1, 100.0, 0.1, "or_greater") var gravity: float = 24.0
## Standing jump apex above takeoff, in meters.
@export_range(0.1, 10.0, 0.05, "or_greater") var jump_height: float = 1.5
## Crouched jump apex above takeoff, in meters, with or without the walk modifier.
@export_range(0.1, 10.0, 0.05, "or_greater") var crouch_jump_height: float = 0.75
## Seconds after leaving a floor during which a jump may still begin. Zero disables this grace.
@export_range(0.0, 0.5, 0.01) var coyote_time: float = 0.12

@export_group("Terrain")
## Maximum stair riser height, in meters. Zero disables automatic stair ascent.
@export_range(0.0, 1.0, 0.01, "or_greater") var max_step_height: float = 0.3
## Maximum walkable floor and stair tread angle, in degrees from horizontal.
@export_range(0.0, 89.0, 0.1) var max_slope_angle: float = 45.0


func _validate_property(property: Dictionary) -> void:
	if (normal_run_speed <= 0.0 or not is_finite(normal_run_speed)) and property.name in [
		&"walk_speed_multiplier", &"sprint_speed_multiplier", &"crouch_speed_multiplier",
	]:
		property.usage &= ~PROPERTY_USAGE_EDITOR
