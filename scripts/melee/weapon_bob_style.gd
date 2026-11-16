class_name WeaponBobStyle
extends Resource
## Authored variation on the first-person weapon gait.

const DEFAULT_WRIST_DELAY := 0.11
const GaitMotionResource := preload("res://scripts/melee/weapon_gait_motion.gd")

## Multiplier for steps per meter traveled. Larger values shorten each step without changing speed.
@export_range(0.25, 2.0, 0.01) var cadence_scale: float = 1.0
## Grip travel multipliers for sideways shift (X), vertical compression (Y), and depth (Z).
@export var travel_scale: Vector3 = Vector3.ONE
## Blade pitch (X) and roll (Y) multipliers.
@export var rotation_scale: Vector2 = Vector2.ONE
## Delay between the grip swing and wrist response as a fraction of a full two-step stride.
@export_range(0.0, 0.25, 0.005) var wrist_delay: float = DEFAULT_WRIST_DELAY
## Optional walking step curve. Match both endpoint heights and tangents to loop.
@export var walk_step: Curve
## Optional running step curve. Match both endpoint heights and tangents to loop.
@export var run_step: Curve

@export_group("Carry")
## Resting grip offset in camera-local meters, authored for the right hand and mirrored left.
@export var carry_position: Vector3
## Resting blade pitch, yaw, and roll in degrees about the right grip. The left mirrors it.
@export var carry_rotation_degrees: Vector3
## Grip travel opposite the direction of movement at the deepest point of a full-speed step.
@export_range(0.0, 0.05, 0.001, "suffix:m") var plant_travel: float = 0.0
## Upper-body yaw in degrees at the widest point of the full-speed walk or run swing.
@export_range(0.0, 5.0, 0.1, "degrees") var shoulder_yaw: float = 0.0
## Scales how long the grips take to follow acceleration, changes of direction, and braking.
@export_range(0.5, 3.0, 0.05) var movement_response_scale: float = 1.0

@export_group("Transitions")
## Optional motion when the character takes a grounded first step after a stop.
@export var start_motion: GaitMotionResource
## Optional motion when the character changes grounded travel direction.
@export var pivot_motion: GaitMotionResource
## Optional motion as the character brakes or is brought to a stop.
@export var stop_motion: GaitMotionResource
