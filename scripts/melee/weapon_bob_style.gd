class_name WeaponBobStyle
extends Resource
## Authored variation on the first-person weapon gait.

const DEFAULT_WRIST_DELAY := 0.11
const GaitMotionResource := preload("res://scripts/melee/weapon_gait_motion.gd")

## Scales how many steps fit into a meter of travel. Increase it for shorter, quicker steps at the same
## speed.
@export_range(0.25, 2.0, 0.01) var cadence_scale: float = 1.0
## Scales the grip's sideways shift on X, rise and dip on Y, and forward and back swing on Z. Lower Y for
## a shallower step without narrowing the sway.
@export var travel_scale: Vector3 = Vector3.ONE
## Scales wrist pitch on X and side-to-side roll on Y. Lower these for a steadier blade while moving.
@export var rotation_scale: Vector2 = Vector2.ONE
## Delays the wrist response by a fraction of a two-step stride. Increase it to make the blade follow the
## grip later.
@export_range(0.0, 0.25, 0.005) var wrist_delay: float = DEFAULT_WRIST_DELAY
## Grip height through one walking step from 0 to 1. Match the endpoint values and slopes for a smooth
## loop.
## Leave unassigned to use the base walking curve.
@export var walk_step: Curve
## Grip height through one running step from 0 to 1. Match the endpoint values and slopes for a smooth
## loop.
## Leave unassigned to use the base running curve.
@export var run_step: Curve

@export_group("Carry")
## Carry offset in camera-local meters. Positive X moves the right grip right, positive Y raises it, and
## positive Z brings it closer. The left grip mirrors X.
@export var carry_position: Vector3
## Carry rotation in degrees about the grip. X sets pitch, Y sets yaw, and Z sets roll. The left hand
## mirrors yaw and roll.
@export var carry_rotation_degrees: Vector3
## How far the grips pull against travel in meters during the dip of a full-speed step. Increase it to
## emphasize the planted foot.
@export_range(0.0, 0.05, 0.001, "suffix:m") var plant_travel: float = 0.0
## Shared yaw in degrees at the peak of a full-speed arm swing. Increase it for a stronger shoulder turn
## with each stride.
@export_range(0.0, 5.0, 0.1, "degrees") var shoulder_yaw: float = 0.0
## Scales the movement spring's response and settle times. Increase it to make the grips take longer to
## follow acceleration and settle under braking.
@export_range(0.5, 3.0, 0.05) var movement_response_scale: float = 1.0

@export_group("Transitions")
## Adds a pose when grounded travel starts after a pause. Use it to give the first step a distinct grip
## shift.
@export var start_motion: GaitMotionResource
## Adds a pose on a sharp grounded turn. Author a right turn and the rig mirrors it for a left turn.
@export var pivot_motion: GaitMotionResource
## Adds a brief pose as ground travel comes to a stop. Reduce its position and rotation for a subtler
## settling kick. Near-opposite reversals also play this pose.
@export var stop_motion: GaitMotionResource
