class_name FirstPersonCrouchSettings
extends Resource
## Editable crouch input, stance dimensions, and visual transition; runtime state is per player.

## Maps crouch input to a stance request.
enum Mode {
	## A press changes the requested stance. Releasing the input leaves it selected.
	TOGGLE,
	## Holding the input requests crouching. Releasing it requests standing when clearance permits.
	ONE_SHOT,
}

## Toggle changes stance on each press; One Shot crouches while the action is held.
@export var mode: Mode = Mode.TOGGLE
## Full crouched capsule height, in meters; limited by its diameter and standing height.
@export_range(0.1, 3.0, 0.01, "or_greater") var crouched_height: float = 1.1
## Crouched eye height above the body origin, in meters; limited to the crouched capsule height.
@export_range(0.1, 3.0, 0.01, "or_greater") var crouched_eye_height: float = 0.95
## Eye-height transition duration, in seconds, with easing at both ends. Zero changes height instantly.
@export_range(0.0, 1.0, 0.01, "or_greater") var transition_time: float = 0.2
