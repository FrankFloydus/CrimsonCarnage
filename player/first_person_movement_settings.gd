class_name FirstPersonMovementSettings
extends Resource
## Editable normal speed, gait multipliers and locomotion physics.

@export_group("Movement Baseline")
## Normal running speed in meters per second at 0% Movement Speed bonus (100% normal speed).
## Actor bonuses and gait multipliers apply afterward. Zero disables horizontal movement.
@export_range(0.0, 30.0, 0.1, "or_greater") var normal_run_speed: float = 4.0

@export_group("Movement Multipliers")
## Fraction of the actor's modified normal movement speed while the walk modifier is held.
## Also multiplies crouched speed for crouch walking. Zero prevents movement in those gaits.
@export_range(0.0, 5.0, 0.05, "or_greater") var walk_speed_multiplier: float = 0.5
## Multiplier of the actor's modified normal movement speed while sprint is selected and affordable.
@export_range(0.0, 5.0, 0.05, "or_greater") var sprint_speed_multiplier: float = 1.5
## Fraction of modified normal movement speed while crouched; crouch walking also uses walking.
@export_range(0.0, 5.0, 0.05, "or_greater") var crouch_speed_multiplier: float = 0.6

@export_group("Encumbrance")
## Carried weight divided by capacity at full penalty. Must exceed 1.0.
## At 2.0, carrying twice the actor's capacity reaches the speed floor and disables jumping.
@export_range(1.01, 10.0, 0.01, "or_greater") var full_penalty_ratio: float = 2.0
## Fraction of each gait's speed retained at full encumbrance, from zero to one.
## A value of 0.5 keeps half speed at and beyond the full-penalty weight.
@export_range(0.0, 1.0, 0.01) var min_speed_multiplier: float = 0.5

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
## Standing jump apex above takeoff, in meters, for walking, running, and sprinting.
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
