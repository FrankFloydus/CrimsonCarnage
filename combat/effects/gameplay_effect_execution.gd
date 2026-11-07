@tool
class_name GameplayEffectExecution
extends Resource
## Calculates the attribute changes for an instant or periodic Gameplay Effect.


func execute(
		_spec: GameplayEffectSpec, _target: ActorAttributes, _target_tags: GameplayTagSet
) -> Array[AttributeModifier]:
	return []


func is_damage_execution() -> bool:
	return false


## Supplies optional damage details for resolved Health loss and combat feedback.
func calculate_damage(_spec: GameplayEffectSpec, _target: ActorAttributes) -> Dictionary:
	return {}
