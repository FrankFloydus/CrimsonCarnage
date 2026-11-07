class_name AbilityFinishAction
extends AbilityActionDefinition
## Finishes or cancels the activation through its ordinary cleanup path.

## Emits cancellation instead of successful completion when this action runs.
@export var cancel_cast: bool = false


func get_validation_error() -> StringName:
	return &""


func execute(context: AbilityPhaseContext, _targets: AbilityTargetSet) -> int:
	if context.cast.finished:
		return 0
	if cancel_cast:
		context.cast.cancel()
	else:
		context.cast.finish()
	return 1
