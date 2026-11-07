@tool
class_name GameplayEffectDamageExecution
extends GameplayEffectExecution
## Resolves instant or periodic Health damage using the combat formula and the effect spec.


func is_damage_execution() -> bool:
	return true


func calculate_damage(spec: GameplayEffectSpec, target: ActorAttributes) -> Dictionary:
	return CombatMath.resolve_effect_result(spec.settings, spec.context, target)
