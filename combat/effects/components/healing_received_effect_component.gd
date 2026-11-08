@tool
class_name HealingReceivedEffectComponent
extends GameplayEffectComponent
## Modifies ordinary incoming healing for the retained effect's active lifetime.

## Fraction of offered ordinary healing received. 0.75 permits 75% before overheal.
@export_range(0.0, 10.0, 0.01, "or_greater") var multiplier: float = 1.0


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if definition.timing == GameplayEffectDefinition.Timing.INSTANT \
			or not is_finite(multiplier) or multiplier < 0.0:
		return &"Effect.InvalidHealingReceived"
	return &""
