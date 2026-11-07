@tool
class_name ChanceToApplyEffectComponent
extends GameplayEffectComponent
## Rolls once when a spec is applied. Eligibility previews remain deterministic.

## Chance that this effect applies, expressed from 0% to 100%.
@export_range(0.0, 100.0, 0.1) var chance_percent: float = 100.0


func get_validation_error(_definition: GameplayEffectDefinition) -> StringName:
	if not is_finite(chance_percent) or chance_percent < 0.0 or chance_percent > 100.0:
		return &"Effect.InvalidApplicationChance"
	return &""


func can_apply(runtime: GameplayEffectRuntime, _spec: GameplayEffectSpec) -> bool:
	return runtime.roll_application_chance(chance_percent / 100.0)
