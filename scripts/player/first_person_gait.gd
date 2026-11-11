class_name FirstPersonGait
extends RefCounted
## Per-controller gait selection from held movement modifiers and physical stance.

## Movement profile selected after resolving input and stance.
enum Gait {
	## Uses the ordinary standing run speed.
	RUN,
	## Applies the walking speed multiplier while standing.
	WALK,
	## Applies the crouch speed multiplier while physically crouched.
	CROUCH,
	## Applies the crouch-walk multiplier while crouched and holding the walk modifier.
	CROUCH_WALK,
}

## Effective gait after resolving the walk modifier and crouch stance.
var current_gait: Gait:
	get:
		return _current_gait
var _current_gait: Gait = Gait.RUN


## Resolves once before movement using the current walk modifier and physical stance.
func advance(
		walk_held: bool,
		is_crouching: bool
) -> void:
	if is_crouching:
		_current_gait = Gait.CROUCH_WALK if walk_held else Gait.CROUCH
	elif walk_held:
		_current_gait = Gait.WALK
	else:
		_current_gait = Gait.RUN
