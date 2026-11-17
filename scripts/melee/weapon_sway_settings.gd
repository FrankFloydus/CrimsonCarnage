extends Resource
## Controls how mounted weapons respond to aiming, movement, wall proximity, and changes in footing.

const BobStyleResource := preload("res://scripts/melee/weapon_bob_style.gd")
const AirMotionResource := preload("res://scripts/melee/weapon_air_motion.gd")

## Look sway added per degree of mouse-driven aim. Lower it if small aim corrections move the blades too
## far. Zero disables look-driven sway.
@export_range(0.0, 0.2, 0.001) var turn_gain: float = 0.065
## How quickly the look sway target recenters after a turn. Raise it if the weapons keep drifting after
## you stop the mouse.
@export_range(1.0, 30.0, 0.1) var recenter_rate: float = 13.0
## How long the weapons take to follow a change in aim, in seconds. Raise it for more lag on a quick
## flick, or lower it for a tighter response.
@export_range(0.02, 0.2, 0.005, "suffix:s") var look_response_time: float = 0.065

@export_group("Turn in Place", "turn_in_place_")
## Extra time for long-sword yaw to follow a quick horizontal turn while grounded and nearly still. Raise
## it for more weight on standing flicks. At zero, yaw uses Look Response Time.
@export_range(0.0, 0.15, 0.005, "suffix:s") var turn_in_place_extra_response: float = 0.060
## Turn speed in degrees per second for the full extra yaw lag. The effect starts at half this speed.
## Raise it to reserve the lag for fast flicks.
@export_range(60.0, 720.0, 5.0, "suffix:°/s") var turn_in_place_full_yaw_rate: float = 240.0

@export_group("Inward")
## Full grip offset in camera-local meters when the right hand trails toward the center on a right turn.
## Negative X brings it closer to the crosshair. The left hand mirrors X and the turn direction.
@export var inward_position: Vector3
## Pitch (X), yaw (Y), and roll (Z) in degrees around the grip for the inward turn. Tune Y to turn the
## blade across the view without moving the grip. The left hand mirrors Y and Z.
@export var inward_rotation: Vector3

@export_group("Outward")
## Full grip offset in camera-local meters when the right hand trails outward on a left turn. Positive X
## moves it toward the screen edge. The left hand mirrors X and the turn direction.
@export var outward_position: Vector3
## Pitch (X), yaw (Y), and roll (Z) in degrees around the grip for the outward turn. Reduce the yaw if
## the blade swings too far toward the edge. The left hand mirrors Y and Z.
@export var outward_rotation: Vector3

@export_group("Up")
## Full grip offset in camera-local meters when you aim down and the weapons trail upward. Positive Y
## lifts the guards. The left hand mirrors X.
@export var up_position: Vector3
## Rotation in degrees around the grip while aiming down. Use X to change how far the blade tips rise
## without lifting the guards. The left hand mirrors Y and Z.
@export var up_rotation: Vector3

@export_group("Down")
## Full grip offset in camera-local meters when you aim up and the weapons trail downward. Negative Y
## lowers the guards to clear the view. The left hand mirrors X.
@export var down_position: Vector3
## Rotation in degrees around the grip while aiming up. Use X to change how far the blade tips dip. The
## left hand mirrors Y and Z.
@export var down_rotation: Vector3

@export_group("Locomotion", "movement_")
## Horizontal acceleration in m/s² needed to ask for full grip lag. Raise it if small speed changes
## already produce most of the available travel.
@export_range(1.0, 100.0, 0.5, "suffix:m/s²") var movement_full_acceleration: float = 35.0
## Horizontal speed in m/s for full blade lean and step bob. Match normal running speed if you want the
## full gait at a run.
@export_range(0.1, 30.0, 0.1, "suffix:m/s") var movement_full_speed: float = 6.0
## Spring time in seconds for grip lag, lean, directional carry, and bob. Raise it for more lag after
## starting or changing direction.
@export_range(0.02, 0.35, 0.005, "suffix:s") var movement_response_time: float = 0.12
## Spring timing in seconds as you slow below half Full Speed. Raise it for a slower return to idle. For
## a smaller extra kick at the end, edit Bob → Style → Transitions → Stop Motion.
@export_range(0.02, 0.5, 0.005, "suffix:s") var movement_settle_time: float = 0.19
## Maximum sideways grip lag in meters from acceleration or braking. Lower it if starting or stopping a
## strafe pulls the guards too far across the screen.
@export_range(0.0, 0.05, 0.001, "suffix:m") var movement_lateral_travel: float = 0.012
## Maximum fore-and-aft grip lag in meters from acceleration or braking. Lower it if tapping W or S pulls
## the swords too far toward or away from the camera.
@export_range(0.0, 0.05, 0.001, "suffix:m") var movement_depth_travel: float = 0.020
## Maximum blade roll in degrees during a strafe. Lower it if the blades tilt too far while you hold A or
## D.
@export_range(0.0, 5.0, 0.1, "suffix:°") var movement_lateral_lean: float = 2.0
## Maximum blade pitch in degrees while traveling forward or back. Lower it if the blade tips pitch too
## far during steady movement.
@export_range(0.0, 5.0, 0.1, "suffix:°") var movement_forward_lean: float = 3.4

@export_group("Directional Carry", "directional_carry_")
## Ground speed in m/s for the full directional carry pose. Lower it if the stance should settle into its
## travel pose even at a slow walk.
@export_range(0.1, 8.0, 0.1, "suffix:m/s") var directional_carry_full_speed: float = 2.0
## Grip offset in camera-local meters at full forward carry. Negative Z pushes the guards farther from
## the eye. The left hand mirrors X.
@export var directional_carry_forward_position: Vector3
## Blade rotation in degrees at full forward carry. Use X for a steady blade pitch while moving forward.
## The left hand mirrors yaw and roll.
@export var directional_carry_forward_rotation: Vector3
## Grip offset in camera-local meters at full backward carry. Positive Z draws the guards closer to the
## eye when backing away. The left hand mirrors X.
@export var directional_carry_backward_position: Vector3
## Blade rotation in degrees at full backward carry. Use X to adjust where the tips rest while backing
## away. The left hand mirrors yaw and roll.
@export var directional_carry_backward_rotation: Vector3
## Grip offset in camera-local meters for the hand on the side you strafe toward. Author it for the right
## hand moving right. Negative Z pushes the leading guard farther from the eye.
@export var directional_carry_leading_position: Vector3
## Blade rotation in degrees for the hand on the side you strafe toward. Author it for the right hand
## moving right. Use roll (Z) to tilt the leading blade into the stance.
@export var directional_carry_leading_rotation: Vector3
## Grip offset in camera-local meters for the hand on the opposite side of the strafe. Author it for the
## right hand moving left. Positive Z draws the trailing guard closer to the eye.
@export var directional_carry_trailing_position: Vector3
## Blade rotation in degrees for the hand on the opposite side of the strafe. Author it for the right
## hand moving left. Use yaw (Y) to keep the trailing blade clear of the crosshair.
@export var directional_carry_trailing_rotation: Vector3

@export_group("Wall Tuck", "wall_tuck_")
## Base distance in meters beyond the grip or tip for starting the wall tuck. Raise it to anticipate
## walls sooner. Zero disables the proximity tuck.
@export_range(0.0, 0.6, 0.01, "suffix:m") var wall_tuck_distance: float = 0.18
## Extra tuck detection distance per meter of grip-to-tip reach. Raise it if longer blades should pull in
## earlier than short ones.
@export_range(0.0, 0.6, 0.01) var wall_tuck_reach_scale: float = 0.26
## How far the grip can retreat toward the camera at full tuck, in meters of camera depth. Lower it if
## the sword pulls too far back as you approach a wall.
@export_range(0.0, 0.08, 0.001, "suffix:m") var wall_tuck_depth: float = 0.042
## Vertical grip shift in meters at full tuck. Use a small positive value to keep the guard in frame near
## a wall.
@export_range(-0.03, 0.03, 0.001, "suffix:m") var wall_tuck_height: float = 0.006
## How quickly the proximity tuck relaxes once you back away, in seconds. Raise it to give the guard a
## softer return when stepping clear of a wall.
@export_range(0.05, 1.0, 0.01, "suffix:s") var wall_tuck_recovery_time: float = 0.30

@export_group("Bob", "bob_")
## Preset for step rhythm, carry stance, and start, pivot, and stop poses. Use Heavy Braced for a wider,
## heavier stance. Leave empty to use the base bob settings below.
@export var bob_style: BobStyleResource
## Ground distance in meters per slow step, before the style's Cadence Scale. Lower it if the weapon bob
## feels too slow while walking.
@export_range(0.2, 3.0, 0.01, "suffix:m") var bob_walk_step_length: float = 0.92
## Ground distance in meters per step at Locomotion's Full Speed, before Cadence Scale. Raise it for a
## longer running stride.
@export_range(0.3, 4.0, 0.01, "suffix:m") var bob_run_step_length: float = 1.95
## Vertical grip travel in meters for a step curve value of one at full speed. Lower it to soften the
## rise and dip of each step.
@export_range(0.0, 0.04, 0.001, "suffix:m") var bob_vertical_travel: float = 0.008
## Base sideways grip travel in meters during the stride. Lower it if the guards sweep too far across the
## screen while strafing.
@export_range(0.0, 0.02, 0.001, "suffix:m") var bob_lateral_travel: float = 0.004
## Base fore-and-aft travel in meters as the grips alternate during a stride. Lower it if running makes
## the swords pump too far in and out.
@export_range(0.0, 0.04, 0.001, "suffix:m") var bob_depth_travel: float = 0.014
## Base pitch in degrees for the blade tips' up-and-down swing during a stride. Lower it to keep the tips
## steadier while running.
@export_range(0.0, 3.0, 0.05, "suffix:°") var bob_pitch: float = 0.85
## Base roll in degrees for the alternating weight shift through each stride. Lower it if the swords rock
## too much from edge to edge.
@export_range(0.0, 3.0, 0.05, "suffix:°") var bob_roll: float = 0.65
## Default vertical curve for one walking step. Dip below zero for a foot plant and match endpoint
## heights and tangents for a smooth loop. An empty curve uses a cosine.
@export var bob_walk_step: Curve
## Default vertical curve for one running step. Use a sharper dip for a firmer foot plant. Match endpoint
## heights and tangents for a smooth loop. An empty curve follows the base Walk Step.
@export var bob_run_step: Curve

@export_group("Idle Breathing", "breath_")
## Shape of a full breath. Use a broad rise and a gradual fall for a calm idle. Match endpoint values and
## tangents for a smooth loop. Leave empty to disable breathing.
@export var breath_curve: Curve
## Duration of one inhale and exhale in seconds. Raise it for a slower idle rhythm.
@export_range(1.0, 10.0, 0.1, "suffix:s") var breath_period: float = 4.6
## Grip offset in camera-local meters when the breath curve reaches one. Keep it around a few millimeters
## for a subtle idle. The left hand mirrors X.
@export var breath_position: Vector3 = Vector3(0.0, 0.0012, -0.0032)
## Blade pitch in degrees around the grip when the delayed breath curve reaches one. Keep it near zero
## for a subtler tip tilt.
@export_range(-1.0, 1.0, 0.01, "suffix:°") var breath_pitch: float = -0.17
## Delay in seconds between the grip and the breathing pitch. Raise it to let the blade tips follow a
## little after the hands.
@export_range(0.0, 1.0, 0.01, "suffix:s") var breath_wrist_delay: float = 0.20
## Time in seconds for breathing to fade back in during grounded idle. Raise it to ease from a stop or
## swing recovery into the breathing pose.
@export_range(0.05, 1.0, 0.01, "suffix:s") var breath_fade_in: float = 0.40
## Time in seconds for breathing to fade out when you move, leave the ground, or start a slash. Lower it
## for a quicker handoff to the action.
@export_range(0.05, 1.0, 0.01, "suffix:s") var breath_fade_out: float = 0.14

@export_group("Jump and Landing")
## Weapon pose when you leave the ground moving upward. Use a brief grip dip to give takeoff some weight.
## The last sample holds until landing. Leave empty to disable it.
@export var takeoff_motion: AirMotionResource
## Weapon compression and recovery on touchdown, scaled by downward speed. Use a brief dip to sell the
## impact. Leave empty to disable it.
@export var landing_motion: AirMotionResource
## Downward speed in m/s you must exceed to get a landing pose. Raise it if small drops trigger too much
## weapon motion.
@export_range(0.0, 10.0, 0.1, "suffix:m/s") var landing_min_speed: float = 2.0
## Downward speed in m/s for full landing compression. The entire landing pose scales up from zero
## at Landing Min Speed. Lower this if a normal jump barely shows the landing curve.
@export_range(0.1, 30.0, 0.1, "suffix:m/s") var landing_full_speed: float = 15.0
