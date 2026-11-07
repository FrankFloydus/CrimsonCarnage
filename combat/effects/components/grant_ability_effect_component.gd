@tool
class_name GrantAbilityEffectComponent
extends GameplayEffectComponent
## Grants one ordinary ability spec while an effect is active.

## Determines what happens to the effect's granted ability when the effect stops contributing.
enum RemovalPolicy {
	## Cancels any running use and revokes the grant immediately.
	CANCEL_IMMEDIATELY,
	## Prevents new activations and revokes the grant when its current cast ends.
	REMOVE_ON_END,
	## Leaves the ability grant in place after this effect ends.
	KEEP_ABILITY,
}

## Shared ability to grant on the effect target while this retained effect is active.
@export var ability: AbilityDefinition
## Level of the granted ability. Zero uses the level on the applied effect spec.
@export_range(0, 100, 1, "or_greater") var grant_level: int = 1
## How this effect's ability grant is handled when the effect is removed or inhibited.
@export var removal_policy: RemovalPolicy = RemovalPolicy.CANCEL_IMMEDIATELY


func _validate_property(property: Dictionary) -> void:
	if property.name == &"ability":
		property.usage |= PROPERTY_USAGE_NEVER_DUPLICATE


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if definition.timing == GameplayEffectDefinition.Timing.INSTANT:
		return &"Effect.AbilityGrantRequiresLifetime"
	if ability == null or ability.ability_id.is_empty() or ability.execution == null or grant_level < 0:
		return &"Effect.InvalidAbilityGrant"
	if removal_policy not in RemovalPolicy.values():
		return &"Effect.InvalidAbilityRemovalPolicy"
	return &""


func can_apply(runtime: GameplayEffectRuntime, _spec: GameplayEffectSpec) -> bool:
	return runtime.get_target_ability_system() != null


func on_active(runtime: GameplayEffectRuntime, spec: GameplayEffectSpec, handle: int) -> Callable:
	var target := runtime.get_target_ability_system()
	if target == null:
		return Callable()
	for granted: GameplayAbilitySpec in target.get_granted_ability_specs():
		if granted.granting_effect_handle == handle and granted.definition == ability:
			return Callable()
	var level := grant_level if grant_level > 0 else maxi(1, int(spec.level))
	var grant := target.grant_ability_spec(ability, level, spec.context.source_object,
			handle, spec.get_set_by_caller_magnitudes())
	if grant <= 0:
		return Callable()
	match removal_policy:
		RemovalPolicy.CANCEL_IMMEDIATELY:
			return target.revoke_ability_spec.bind(grant)
		RemovalPolicy.REMOVE_ON_END:
			return target.remove_ability_spec_on_end.bind(grant)
	return Callable()
