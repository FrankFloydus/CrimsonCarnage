class_name WeaponAirMotion
extends Resource
## One takeoff or landing pose played on both first-person weapons.

## Time in seconds to play the envelope. Takeoff holds the last pose until contact.
@export_range(0.12, 1.0, 0.01, "suffix:s") var duration: float = 0.3
## Signed grip translation over normalized time. Also drives rotation without a separate curve.
## Start at zero. End at zero to return to the carry pose during flight or after landing.
@export var envelope: Curve
## Optional normalized curve for rotation. Use it to let the blade follow the grip with a delay.
## Leave empty to use the grip envelope for both.
@export var rotation_envelope: Curve
## Camera-local grip offset in meters at full strength. The left hand mirrors X.
@export var position: Vector3
## Pitch, yaw, and roll in degrees at full strength. The left hand mirrors yaw and roll.
@export var rotation_degrees: Vector3
