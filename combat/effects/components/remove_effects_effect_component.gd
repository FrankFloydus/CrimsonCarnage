class_name RemoveEffectsEffectComponent
extends GameplayEffectComponent
## Removes matching retained effects on each accepted application.

## Removes all stacks of effects with any of these asset tags or a descendant. Empty removes nothing.
@export var effect_asset_tags: PackedStringArray = PackedStringArray()


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	return &"Effect.PeriodicRemovalComponent" if definition.get_effective_period() > 0.0 else &""


func on_applied(runtime: GameplayEffectRuntime, spec: GameplayEffectSpec) -> void:
	runtime.remove_effects_by_asset_tags(effect_asset_tags, spec.definition)
