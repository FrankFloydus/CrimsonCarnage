class_name WeaponGaitMotion
extends Resource
## One authored start, pivot, or stop offset for the first-person weapon gait.

## Time in seconds from the first pose to the return to the carry pose.
@export_range(0.05, 1.0, 0.01, "suffix:s") var duration: float = 0.3
## Signed amplitude over the motion's normalized time. Use zero at the start and end.
@export var envelope: Curve
## Grip offset in meters at full amplitude. Start and stop use axes relative to travel.
## Pivot offsets are authored for a rightward turn and mirrored for a leftward turn.
@export var position: Vector3
## Pitch, yaw, and roll degrees at full amplitude, in the same frame as Position.
@export var rotation_degrees: Vector3
## Extra right-hand depth in meters at full pivot amplitude. The opposite hand mirrors it.
@export var pivot_hand_depth: float = 0.0
## Sideways grip shift in meters toward the loaded foot at the start of braking. Used by stop motions.
@export_range(0.0, 0.04, 0.001, "suffix:m") var stop_weight_shift: float = 0.0
