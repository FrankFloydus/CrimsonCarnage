class_name FirstPersonGait
extends RefCounted
## Per-controller gait selection from held movement modifiers and physical stance.

## Movement profile selected after resolving input and stance.
enum Gait {
	## Uses the ordinary standing run speed.
	RUN,
	## Applies the walking speed multiplier while standing.
	WALK,
	## Applies the sprint speed multiplier while sprint is held.
	SPRINT,
	## Applies the crouch speed multiplier while physically crouched.
	CROUCH,
	## Combines the walking and crouch speed multipliers.
	CROUCH_WALK,
}

## Effective gait after walking, crouching, and sprint have been resolved.
var current_gait: Gait:
	get:
		return _current_gait
var _current_gait: Gait = Gait.RUN


## Resolves once before movement. Shift must stay held; walking and crouching temporarily override it.
func advance(
		sprint_held: bool,
		walk_held: bool,
		is_crouching: bool
) -> void:
	if is_crouching:
		_current_gait = Gait.CROUCH_WALK if walk_held else Gait.CROUCH
	elif walk_held:
		_current_gait = Gait.WALK
	elif sprint_held:
		_current_gait = Gait.SPRINT
	else:
		_current_gait = Gait.RUN
