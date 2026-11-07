class_name FirstPersonGait
extends RefCounted
## Per-controller gait selection with held sprint and an exhaustion release requirement.

## Movement profile selected after resolving input, stance, and sprint eligibility.
enum Gait {
	## Uses the ordinary standing run speed.
	RUN,
	## Applies the walking speed multiplier while standing.
	WALK,
	## Applies the sprint speed multiplier while sprint is held and available.
	SPRINT,
	## Applies the crouch speed multiplier while physically crouched.
	CROUCH,
	## Combines the walking and crouch speed multipliers.
	CROUCH_WALK,
}

## Effective gait after walking, crouching, and input capture have been resolved.
var current_gait: Gait:
	get:
		return _current_gait
## Exhaustion prevents another sprint until Shift is released; recovery never clears this latch.
var sprint_requires_release: bool:
	get:
		return _sprint_requires_release

var _current_gait: Gait = Gait.RUN
var _sprint_requires_release: bool = false


## A canceled held sprint needs a new press even when physical eligibility returns.
func require_sprint_release() -> void:
	_sprint_requires_release = true


## A released keyboard request no longer blocks a new sprint.
func clear_sprint_release() -> void:
	_sprint_requires_release = false


## Resolves once before movement. Shift must stay held; walking and crouching temporarily override it.
## Only an otherwise selected, unaffordable sprint requires release before another attempt.
func advance(
		sprint_held: bool,
		walk_held: bool,
		is_crouching: bool,
		controls_active: bool = true,
		sprint_available: bool = true
) -> void:
	if not controls_active or not sprint_held:
		_sprint_requires_release = false
	elif not is_crouching and not walk_held and not sprint_available:
		_sprint_requires_release = true
	var walking := controls_active and walk_held
	if is_crouching:
		_current_gait = Gait.CROUCH_WALK if walking else Gait.CROUCH
	elif walking:
		_current_gait = Gait.WALK
	elif controls_active and sprint_held and not _sprint_requires_release and sprint_available:
		_current_gait = Gait.SPRINT
	else:
		_current_gait = Gait.RUN
