@tool
class_name ImmunityEffectComponent
extends GameplayEffectComponent
## Blocks incoming specs with matching effect asset tags for this effect's active lifetime.

## Any matching incoming Effect Asset Tag is blocked. Parent tags match their descendants.
@export var blocked_asset_tags: PackedStringArray = PackedStringArray()


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if definition.timing == GameplayEffectDefinition.Timing.INSTANT or blocked_asset_tags.is_empty():
		return &"Effect.InvalidImmunity"
	return &""


func on_active(runtime: GameplayEffectRuntime, spec: GameplayEffectSpec, _handle: int) -> Callable:
	var runtime_ref: WeakRef = weakref(runtime)
	var definition := spec.definition
	var queries := blocked_asset_tags.duplicate()
	var filter := func(incoming: GameplayEffectSpec) -> bool:
		if incoming.definition == definition:
			return true
		for query in queries:
			if AttributeModifier._has_match(incoming.settings.asset_tags, query):
				return false
		return true
	runtime.add_application_filter(filter)
	return func() -> void:
		var owner := runtime_ref.get_ref() as GameplayEffectRuntime
		if owner != null:
			owner.remove_application_filter(filter)
