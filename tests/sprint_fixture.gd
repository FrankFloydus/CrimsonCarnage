extends RefCounted
## Installs private numeric tuning while preserving the actor's saved Sprint and Exhaustion wiring.

const STAMINA_PER_CHARGE: float = 2.0
const CHARGE_INTERVAL: float = 0.1
const EXHAUSTION_DURATION: float = 1.0

## Call before the actor enters the tree and registers its grants.
static func configure(system: AbilitySystem) -> void:
	var grants: Array[AbilityDefinition] = system.granted_abilities.duplicate()
	for index in grants.size():
		var definition := grants[index]
		if definition == null:
			continue
		if definition.ability_id == &"sprint" and definition.execution is PhasedAbilityExecution:
			var copy := definition.duplicate_deep(Resource.DEEP_DUPLICATE_ALL) as AbilityDefinition
			var execution := copy.execution as PhasedAbilityExecution
			var sprint := execution.phases[0].actions[0] as PlayerSprintAction
			if sprint != null and sprint.upkeep_effect != null:
				sprint.upkeep_effect.period = CHARGE_INTERVAL
				for calculation: GameplayEffectExecution in sprint.upkeep_effect.executions:
					if calculation is SprintStaminaUpkeepCalculation:
						calculation.stamina_per_interval = STAMINA_PER_CHARGE
			grants[index] = copy
		elif definition.ability_id == &"stamina_exhaustion" \
				and definition.execution is PhasedAbilityExecution:
			var copy := definition.duplicate_deep(Resource.DEEP_DUPLICATE_ALL) as AbilityDefinition
			var execution := copy.execution as PhasedAbilityExecution
			var apply := execution.phases[0].actions[0] as AbilityApplyEffectsAction
			if apply != null and not apply.effects.is_empty():
				apply.effects[0].duration = EXHAUSTION_DURATION
			grants[index] = copy
	system.granted_abilities = grants
