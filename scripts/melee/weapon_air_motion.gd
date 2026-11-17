class_name WeaponAirMotion
extends Resource
## One takeoff or landing pose played on both first-person weapons.

## Seconds from the first to the last point on the curves. On a 0.4 s takeoff, a peak at 0.25 on the
## graph plays about 0.1 s after leaving the ground. The last takeoff value holds until ground contact.
@export_range(0.12, 1.0, 0.01, "suffix:s") var duration: float = 0.3
## The graph runs from the trigger at 0 to the end of Duration at 1. Curve height multiplies Position.
## A height of 0.5 with Position Y at -0.02 m gives a 1 cm dip before impact scaling or blending.
## Zero adds no offset. Negative heights reverse it. Leave Envelope unassigned to skip this motion.
@export var envelope: Curve
## Curve height multiplies Rotation Degrees. Time runs from the trigger at 0 to the end of Duration
## at 1. Move the peak right to make the blades follow the grips a beat later.
## Leave Rotation Envelope unassigned to use Envelope for both movement and rotation.
@export var rotation_envelope: Curve
## Camera-local grip offset in meters when the curve reaches 1. Negative Y dips both grips.
## Negative X pulls both toward the center because the left mirrors X. Positive Z pulls them closer.
@export var position: Vector3
## Pitch, yaw, and roll in degrees on X, Y, and Z when the rotation curve reaches 1.
## Use X for a small pitch around the grip. The left mirrors yaw and roll, which can angle both
## blades inward.
@export var rotation_degrees: Vector3
