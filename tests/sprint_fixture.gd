extends RefCounted
## Installs private numeric tuning while preserving the actor's saved Sprint and Exhaustion wiring.

const STAMINA_PER_CHARGE: float = 2.0
const CHARGE_INTERVAL: float = 0.1
const EXHAUSTION_DURATION: float = 1.0

const SprintExecution = preload("res://player/abilities/sprint_execution.gd")


## Call before the actor enters the tree and registers its grants.
static func configure(system: AbilitySystem) -> void:
	var grants: Array[AbilityDefinition] = system.granted_abilities.duplicate()
	for index in grants.size():
		var definition := grants[index]
		if definition == null:
			continue
		if definition.ability_id == &"sprint" and definition.execution is SprintExecution:
			var copy := definition.duplicate() as AbilityDefinition
			var execution := definition.execution.duplicate() as SprintExecution
			if execution.upkeep_effect != null:
				execution.upkeep_effect = execution.upkeep_effect.duplicate_deep(
						Resource.DEEP_DUPLICATE_ALL) as GameplayEffectDefinition
				execution.upkeep_effect.period = CHARGE_INTERVAL
				for calculation: GameplayEffectExecution in execution.upkeep_effect.executions:
					if calculation is SprintStaminaUpkeepCalculation:
						calculation.stamina_per_interval = STAMINA_PER_CHARGE
			copy.execution = execution
			grants[index] = copy
		elif definition.ability_id == &"stamina_exhaustion" \
				and definition.execution is TimedSelfEffectExecution:
			var copy := definition.duplicate() as AbilityDefinition
			var execution := definition.execution.duplicate() as TimedSelfEffectExecution
			if execution.effect != null:
				execution.effect = execution.effect.duplicate() as GameplayEffectDefinition
				execution.effect.duration = EXHAUSTION_DURATION
			copy.execution = execution
			grants[index] = copy
	system.granted_abilities = grants
