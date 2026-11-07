class_name BlockAbilitiesEffectComponent
extends GameplayEffectComponent
## Contributes a counted block against matching ability asset tags.

## Abilities with any of these tags or a descendant cannot activate while this effect contributes.
@export var blocked_ability_tags: PackedStringArray = PackedStringArray()


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	return &"Effect.AbilityBlockRequiresLifetime" if definition.timing == GameplayEffectDefinition.Timing.INSTANT else &""


func can_apply(runtime: GameplayEffectRuntime, _spec: GameplayEffectSpec) -> bool:
	return runtime.get_target_ability_system() != null


func on_active(runtime: GameplayEffectRuntime, _spec: GameplayEffectSpec, _handle: int) -> Callable:
	var target := runtime.get_target_ability_system()
	if target == null or blocked_ability_tags.is_empty():
		return Callable()
	var contribution := blocked_ability_tags.duplicate()
	target.block_abilities_by_tags(contribution)
	return target.unblock_abilities_by_tags.bind(contribution)
