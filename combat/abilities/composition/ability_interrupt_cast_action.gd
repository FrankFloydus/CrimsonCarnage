class_name AbilityInterruptCastAction
extends AbilityActionDefinition
## Attempts to stop each selected actor's eligible cast and lock its school on success.

## Duration of the interrupted school lockout in seconds. Zero performs only the interrupt.
@export_range(0.0, 60.0, 0.1, "or_greater") var lockout_duration: float = 0.0


func get_validation_error() -> StringName:
	return &"" if is_finite(lockout_duration) and lockout_duration >= 0.0 \
			else &"invalid_school_lockout_duration"


func execute(_context: AbilityPhaseContext, targets: AbilityTargetSet) -> int:
	var interrupted := 0
	for contact: AbilityTargetContact in targets.contacts:
		var target := contact.get_target()
		if target != null and target.interrupt_cast(lockout_duration).is_success():
			interrupted += 1
	return interrupted
