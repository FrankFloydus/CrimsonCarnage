extends Resource
## Directional look poses for the right hand and shared sway driven by locomotion.

const BobStyleResource := preload("res://scripts/melee/weapon_bob_style.gd")
const AirMotionResource := preload("res://scripts/melee/weapon_air_motion.gd")

## Amount of sway added per degree of applied mouse turn. Zero disables sway input.
@export_range(0.0, 0.2, 0.001) var turn_gain: float = 0.065
## Rate per second at which the look sway target returns to neutral after mouse movement.
@export_range(1.0, 30.0, 0.1) var recenter_rate: float = 13.0
## Spring response time in seconds for the grips to follow the look sway target.
@export_range(0.02, 0.2, 0.005, "suffix:s") var look_response_time: float = 0.065

@export_group("Turn in Place", "turn_in_place_")
## Extra spring response time for the long swords during a quick grounded turn at rest.
## Zero gives both sword lengths the general look response.
@export_range(0.0, 0.15, 0.005, "suffix:s") var turn_in_place_extra_response: float = 0.060
## Yaw speed in degrees per second for the full extra response. It starts blending at half this speed.
@export_range(60.0, 720.0, 5.0, "suffix:°/s") var turn_in_place_full_yaw_rate: float = 240.0

@export_group("Inward")
## Camera-local grip translation in meters when the right hand trails toward screen center.
@export var inward_position: Vector3
## Camera-aligned pitch, yaw, and roll in degrees about the grip for the inward pose.
@export var inward_rotation: Vector3

@export_group("Outward")
## Camera-local grip translation in meters when the right hand trails toward the screen edge.
@export var outward_position: Vector3
## Camera-aligned pitch, yaw, and roll in degrees about the grip for the outward pose.
@export var outward_rotation: Vector3

@export_group("Up")
## Camera-local grip translation in meters when the view turns downward.
@export var up_position: Vector3
## Camera-aligned pitch, yaw, and roll in degrees about the grip for the raised pose.
@export var up_rotation: Vector3

@export_group("Down")
## Camera-local grip translation in meters when the view turns upward.
@export var down_position: Vector3
## Camera-aligned pitch, yaw, and roll in degrees about the grip for the lowered pose.
@export var down_rotation: Vector3

@export_group("Locomotion", "movement_")
## Horizontal acceleration in meters per second squared that targets full grip travel.
@export_range(1.0, 100.0, 0.5, "suffix:m/s²") var movement_full_acceleration: float = 35.0
## Horizontal speed in meters per second for full locomotion lean and weapon bob.
@export_range(0.1, 30.0, 0.1, "suffix:m/s") var movement_full_speed: float = 6.0
## Spring response time in seconds for locomotion offsets. Larger values allow longer settling.
@export_range(0.02, 0.35, 0.005, "suffix:s") var movement_response_time: float = 0.12
## Spring response time in seconds as the player brakes to a stop and the weapons return to idle.
@export_range(0.02, 0.5, 0.005, "suffix:s") var movement_settle_time: float = 0.19
## Maximum sideways grip travel in meters when accelerating or braking.
@export_range(0.0, 0.05, 0.001, "suffix:m") var movement_lateral_travel: float = 0.012
## Maximum forward or backward grip travel in meters when accelerating or braking.
@export_range(0.0, 0.05, 0.001, "suffix:m") var movement_depth_travel: float = 0.020
## Maximum blade roll, in degrees about each grip, into sideways travel.
@export_range(0.0, 5.0, 0.1, "suffix:°") var movement_lateral_lean: float = 2.0
## Maximum blade pitch, in degrees about each grip, into forward or backward travel.
@export_range(0.0, 5.0, 0.1, "suffix:°") var movement_forward_lean: float = 1.6

@export_group("Directional Carry", "directional_carry_")
## Supported travel speed in meters per second at which the directional carry reaches full weight.
@export_range(0.1, 8.0, 0.1, "suffix:m/s") var directional_carry_full_speed: float = 2.0
## Right grip offset in meters while moving forward. The left grip mirrors X.
@export var directional_carry_forward_position: Vector3
## Right blade pitch, yaw, and roll in degrees while moving forward. The left mirrors yaw and roll.
@export var directional_carry_forward_rotation: Vector3
## Right grip offset in meters while moving backward. The left grip mirrors X.
@export var directional_carry_backward_position: Vector3
## Right blade pitch, yaw, and roll in degrees while moving backward. The left mirrors yaw and roll.
@export var directional_carry_backward_rotation: Vector3
## Grip offset in meters on the side leading a strafe. Author for a rightward strafe.
@export var directional_carry_leading_position: Vector3
## Blade pitch, yaw, and roll in degrees on the side leading a strafe. Author for the right hand.
@export var directional_carry_leading_rotation: Vector3
## Grip offset in meters on the side trailing a strafe. Author for the right hand on a leftward strafe.
@export var directional_carry_trailing_position: Vector3
## Blade pitch, yaw, and roll in degrees on the side trailing a strafe. Author for the right hand.
@export var directional_carry_trailing_rotation: Vector3

@export_group("Wall Tuck", "wall_tuck_")
## Distance in meters beyond the grip or blade used to notice a wall. Zero disables wall tuck.
@export_range(0.0, 0.6, 0.01, "suffix:m") var wall_tuck_distance: float = 0.18
## Extra notice distance per meter of visible blade above the grip.
@export_range(0.0, 0.6, 0.01) var wall_tuck_reach_scale: float = 0.26
## Maximum camera-space depth in meters that the grip retreats along its line to the eye.
@export_range(0.0, 0.08, 0.001, "suffix:m") var wall_tuck_depth: float = 0.042
## Vertical trim in meters during the tuck. Positive raises the grip to keep the guard in frame.
@export_range(-0.03, 0.03, 0.001, "suffix:m") var wall_tuck_height: float = 0.006
## Time in seconds for the grip to complete most of its return once the wall is clear.
@export_range(0.05, 1.0, 0.01, "suffix:s") var wall_tuck_recovery_time: float = 0.30

@export_group("Bob", "bob_")
## Selected weapon gait. Its scales and optional curves build on the base bob settings below.
@export var bob_style: BobStyleResource
## Horizontal distance in meters per step at walking speeds. Each stride contains two steps.
@export_range(0.2, 3.0, 0.01, "suffix:m") var bob_walk_step_length: float = 0.92
## Horizontal distance in meters per step at Locomotion's Full Speed.
@export_range(0.3, 4.0, 0.01, "suffix:m") var bob_run_step_length: float = 1.95
## Vertical grip displacement in meters at full speed for a step curve value of one.
@export_range(0.0, 0.04, 0.001, "suffix:m") var bob_vertical_travel: float = 0.008
## Peak shared sideways grip shift in meters during a full-speed strafe.
@export_range(0.0, 0.02, 0.001, "suffix:m") var bob_lateral_travel: float = 0.004
## Peak fore-and-aft travel in meters per grip during a full-speed forward or backward stride.
@export_range(0.0, 0.04, 0.001, "suffix:m") var bob_depth_travel: float = 0.014
## Maximum blade pitch in degrees as the grips carry and recover through a full-speed stride.
@export_range(0.0, 3.0, 0.05, "suffix:°") var bob_pitch: float = 0.85
## Maximum blade roll in degrees as weight shifts from side to side during a full-speed strafe.
@export_range(0.0, 3.0, 0.05, "suffix:°") var bob_roll: float = 0.65
## Vertical weight transfer over one walking step. Match both endpoint heights and tangents to loop.
@export var bob_walk_step: Curve
## Vertical weight transfer over one running step. Match both endpoint heights and tangents to loop.
@export var bob_run_step: Curve

@export_group("Idle Breathing", "breath_")
## Signed grip motion over one breath. Match the endpoint values and tangents for a smooth loop.
## Leave empty to disable breathing.
@export var breath_curve: Curve
## Time for a full inhale and exhale, in seconds.
@export_range(1.0, 10.0, 0.1, "suffix:s") var breath_period: float = 4.6
## Camera-local grip travel in meters when the curve reaches one. The left hand mirrors X.
@export var breath_position: Vector3 = Vector3(0.0, 0.0012, -0.0032)
## Blade pitch in degrees about the grip when the delayed curve reaches one.
@export_range(-1.0, 1.0, 0.01, "suffix:°") var breath_pitch: float = -0.17
## Time in seconds before the blade follows the grip.
@export_range(0.0, 1.0, 0.01, "suffix:s") var breath_wrist_delay: float = 0.20
## Time in seconds for the breath to return as the player settles after movement or a slash.
@export_range(0.05, 1.0, 0.01, "suffix:s") var breath_fade_in: float = 0.40
## Time in seconds to fade breathing when movement or a slash starts.
@export_range(0.05, 1.0, 0.01, "suffix:s") var breath_fade_out: float = 0.14

@export_group("Jump and Landing")
## Grip motion played when Movement accepts a jump. Its final pose holds until contact.
## Leave empty to disable the jump pose.
@export var takeoff_motion: AirMotionResource
## Grip compression and recovery played on touchdown. Leave empty to disable landing motion.
@export var landing_motion: AirMotionResource
## Downward speed at or below which a ground contact produces no weapon compression.
@export_range(0.0, 10.0, 0.1, "suffix:m/s") var landing_min_speed: float = 2.0
## Downward speed that reaches maximum landing compression. Keep above Landing Min Speed.
@export_range(0.1, 30.0, 0.1, "suffix:m/s") var landing_full_speed: float = 15.0
