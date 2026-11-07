@tool
class_name AdditionalEffectsComponent
extends GameplayEffectComponent
## Applies additional effects to the same target on successful application.

## Effects applied after this effect succeeds. They keep the original source and grant level.
@export var on_application_effects: Array[GameplayEffectDefinition] = []


func _validate_property(property: Dictionary) -> void:
	if property.name == &"on_application_effects":
		property.usage |= PROPERTY_USAGE_NEVER_DUPLICATE


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	for effect in on_application_effects:
		if effect == null or effect == definition:
			return &"Effect.InvalidAdditionalEffect"
	return &""


func on_applied(runtime: GameplayEffectRuntime, spec: GameplayEffectSpec) -> void:
	for definition in on_application_effects:
		var child := runtime.make_effect_spec(definition, spec.context)
		if child != null:
			child.level = spec.level
			runtime.apply_effect_spec(child)
