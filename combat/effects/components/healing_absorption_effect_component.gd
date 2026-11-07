@tool
class_name HealingAbsorptionEffectComponent
extends GameplayEffectComponent
## Owns a finite incoming-healing absorption budget for each retained application.

## Health points of ordinary healing absorbed before the effect's budget is depleted.
@export_range(0.0, 100000.0, 0.1, "or_greater") var capacity: float = 0.0
## Lower values consume this budget first. Ties follow application and component order.
@export var priority: int = 0
## Removes the retained effect after this budget reaches zero and the heal is committed.
@export var remove_when_depleted: bool = true


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if definition.timing == GameplayEffectDefinition.Timing.INSTANT \
			or not is_finite(capacity) or capacity <= 0.0:
		return &"Effect.InvalidHealingAbsorption"
	return &""
