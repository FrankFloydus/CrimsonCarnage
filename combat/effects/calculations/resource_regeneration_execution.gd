class_name ResourceRegenerationExecution
extends GameplayEffectExecution
## Converts live recovery rates into current-pool modifiers once per effect period.

const STAMINA_RECOVERY_BLOCKED: StringName = &"State.Stamina.RecoveryBlocked"


func execute(spec: GameplayEffectSpec, target: ActorAttributes, target_tags: GameplayTagSet) -> Array[AttributeModifier]:
	var outputs: Array[AttributeModifier] = []
	if target.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return outputs
	for pool: int in CombatAttributes.current_ids():
		if pool == CombatAttributes.Id.STAMINA and target_tags != null \
				and target_tags.has_tag(STAMINA_RECOVERY_BLOCKED):
			continue
		var rate := target.get_value(CombatAttributes.regeneration_for(pool))
		var missing := target.get_value(CombatAttributes.maximum_for(pool)) - target.get_value(pool)
		var recovered := minf(rate * spec.period, missing)
		if is_finite(recovered) and recovered > 0.0:
			var output := AttributeModifier.new()
			output.attribute = pool as CombatAttributes.Id
			output.value = recovered
			outputs.append(output)
	return outputs
