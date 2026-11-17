class_name WeaponGaitMotion
extends Resource
## One authored start, pivot, or stop offset for the first-person weapon gait.

## Length of the authored offset in seconds. A shorter duration makes the start, pivot, or stop gesture
## quicker.
@export_range(0.05, 1.0, 0.01, "suffix:s") var duration: float = 0.3
## Weight of the authored pose over time from 0 to 1. Positive values apply the pose and negative values
## reverse it.
## Use zero at both ends for a smooth return to carry. An unassigned curve skips this motion.
@export var envelope: Curve
## Grip offset in meters at full curve weight. For starts and stops, positive X goes to the right of
## travel, positive Y lifts, and negative Z follows travel.
## For pivots, use camera-local axes for a right turn. The rig mirrors X for a left turn.
@export var position: Vector3
## Pitch, yaw, and roll in degrees on X, Y, and Z at full curve weight. Start and stop rotations follow
## the travel frame.
## Author pivots for a right turn. The rig mirrors yaw and roll for a left turn.
@export var rotation_degrees: Vector3
## Extra depth separation in meters at full pivot weight. A positive value brings the right grip closer
## and pushes the left grip away on a right turn. A left turn swaps the hands.
@export var pivot_hand_depth: float = 0.0
## Sideways grip shift in meters toward the loaded foot when a stop pose starts. Increase it to emphasize
## the braking plant.
@export_range(0.0, 0.04, 0.001, "suffix:m") var stop_weight_shift: float = 0.0
