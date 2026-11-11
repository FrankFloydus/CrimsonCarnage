@tool
class_name FirstPersonMovementSettings
extends Resource
## Editable normal speed, gait multipliers and locomotion physics.

@export_group("Movement Baseline")
## Normal running speed in meters per second before gait multipliers. Zero disables gait movement.
@export_range(0.0, 30.0, 0.1, "or_greater") var normal_run_speed: float = 6.0:
	set(value):
		normal_run_speed = value
		notify_property_list_changed()

@export_group("Movement Multipliers")
## Fraction of normal running speed while standing and holding the walk modifier.
@export_range(0.0, 5.0, 0.001, "or_greater") var walk_speed_multiplier: float = 1.0 / 3.0
## Fraction of normal running speed while crouched without the walk modifier.
@export_range(0.0, 5.0, 0.001, "or_greater") var crouch_speed_multiplier: float = 0.4
## Fraction of normal running speed while crouched and holding the walk modifier.
@export_range(0.0, 5.0, 0.001, "or_greater") var crouch_walk_speed_multiplier: float = 0.2

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

@export_group("Dash", "dash_")
## Maximum number of stored dashes. The player starts full. Zero disables dashing.
@export_range(0, 10, 1, "or_greater") var dash_max_charges: int = 2
## Seconds to recover one spent charge. Recovery continues in the air and during a dash.
@export_range(0.01, 10.0, 0.01, "or_greater", "suffix:s") var dash_recharge_time: float = 1.0
## Horizontal speed during a dash, in meters per second.
@export_range(0.1, 50.0, 0.1, "or_greater", "suffix:m/s") var dash_speed: float = 16.0
## Maximum time a dash travels before returning to normal movement.
@export_range(0.01, 1.0, 0.01, "or_greater", "suffix:s") var dash_duration: float = 0.14

@export_group("Terrain")
## Maximum stair riser height, in meters. Zero disables automatic stair ascent.
@export_range(0.0, 1.0, 0.01, "or_greater") var max_step_height: float = 0.3
## Maximum walkable floor and stair tread angle, in degrees from horizontal.
@export_range(0.0, 89.0, 0.1) var max_slope_angle: float = 45.0


func _validate_property(property: Dictionary) -> void:
	if (normal_run_speed <= 0.0 or not is_finite(normal_run_speed)) and property.name in [
		&"walk_speed_multiplier", &"crouch_speed_multiplier", &"crouch_walk_speed_multiplier",
	]:
		property.usage &= ~PROPERTY_USAGE_EDITOR
