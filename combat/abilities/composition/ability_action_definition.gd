class_name AbilityActionDefinition
extends Resource
## Reusable action verb. All per-execution state belongs to the passed context.


func get_validation_error() -> StringName:
	return &"unimplemented_action"


## Validates a cast-start action against its actor before activation commits.
func get_activation_error(_system: AbilitySystem) -> StringName:
	return &""


## Returns the number of successful operations, zero for no match or -1 for failure.
func execute(_context: AbilityPhaseContext, _targets: AbilityTargetSet) -> int:
	return -1


## Authored effect payloads referenced for preview and source validation.
func get_effect_payload() -> Array[GameplayEffectDefinition]:
	return []
