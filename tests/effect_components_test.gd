extends SceneTree
## Exercises effect components through the same application and grant paths as an actor.

class HeldExecution extends AbilityExecution:
	func begin(_cast: AbilityCast) -> void:
		pass


class RemoveGrantOnActivation extends AbilityExecution:
	func begin(cast: AbilityCast) -> void:
		cast.get_system().effects.remove_effect(cast.grant_spec.granting_effect_handle)


var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_grant_and_inhibition()
	_test_removal_policies()
	_test_reentrant_removal_during_grant()
	_test_ability_tag_blocks()
	_test_effect_asset_tag_removal()
	print("Effect component checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_grant_and_inhibition() -> void:
	var system := _new_actor()
	var ability := _new_ability(&"temporary_ability")
	var permanent := system.grant_ability_spec(ability)
	var grant := GrantAbilityEffectComponent.new()
	grant.ability = ability
	grant.grant_level = 0
	var effect := _new_effect([grant])
	effect.ongoing_required_target_tags = PackedStringArray(["State.Enabled"])
	effect.stacking_type = GameplayEffectDefinition.StackingType.AGGREGATE_BY_TARGET
	var context := system.create_effect_context()
	var source_object := Resource.new()
	context.source_object = source_object
	var spec := system.effects.make_effect_spec(effect, context)
	spec.level = 5
	spec.set_by_caller_magnitude(&"Data.Inherited", 12.0)
	var effect_handle := system.effects.apply_effect_spec(spec)
	_check(effect_handle > 0 and system.effects.is_effect_inhibited(effect_handle)
			and system.get_granted_ability_specs().size() == 1,
			"An inhibited effect keeps its effect handle without granting abilities")
	system.tags.add_tag(&"State.Enabled.Child")
	var temporary := _find_grant(system, effect_handle)
	_check(temporary != null and temporary.definition == ability and temporary.level == 5
			and temporary.source_object == source_object,
			"The active effect grants the original ability asset with the effect's level and source object")
	_check(system.effects.apply_effect_spec(spec) == effect_handle and system.get_granted_ability_specs().size() == 2,
			"Reapplying an aggregate effect does not duplicate its grant")
	if temporary != null and system.try_activate_spec(temporary.handle):
		var cast := system.get_active_cast_for_spec(temporary.handle)
		var outgoing := cast.make_effect_spec(effect)
		_check(outgoing.get_set_by_caller_magnitude(&"Data.Inherited") == 12.0,
				"An effect-granted ability passes its copied Set By Caller data to outgoing specs")
		system.tags.remove_tag(&"State.Enabled.Child")
		_check(cast.finished and system.get_ability_spec(temporary.handle) == null
				and system.get_ability_spec(permanent) != null,
				"Inhibition cancels and revokes only the effect's own grant")
	else:
		_check(false, "The temporary grant can activate by its handle")
	system.tags.add_tag(&"State.Enabled")
	var renewed := _find_grant(system, effect_handle)
	_check(renewed != null and renewed != temporary, "Reactivation grants a fresh ability spec")
	system.effects.remove_effect(effect_handle)
	_check(_find_grant(system, effect_handle) == null and system.get_granted_ability_specs().size() == 1,
			"Removing a retained effect revokes its renewed grant and preserves the permanent copy")
	system.get_parent().free()


func _test_removal_policies() -> void:
	var system := _new_actor()
	var grant := GrantAbilityEffectComponent.new()
	grant.ability = _new_ability(&"finish_then_remove")
	grant.removal_policy = GrantAbilityEffectComponent.RemovalPolicy.REMOVE_ON_END
	var effect := _new_effect([grant])
	var handle := system.effects.apply_effect(effect, system.create_effect_context())
	var spec := _find_grant(system, handle)
	_check(spec != null and system.try_activate_spec(spec.handle), "A remove-on-end grant can start normally")
	if spec != null:
		var cast := system.get_active_cast_for_spec(spec.handle)
		system.effects.remove_effect(handle)
		_check(cast != null and not cast.finished and spec.remove_on_end
				and system.get_activation_failure_for_spec(spec.handle) == &"ability_pending_removal",
				"Removal allows the current cast to finish and closes its grant to new activations")
		if cast != null:
			cast.finish()
		_check(system.get_ability_spec(spec.handle) == null, "Finishing removes the pending grant")
	grant.removal_policy = GrantAbilityEffectComponent.RemovalPolicy.KEEP_ABILITY
	effect.ongoing_required_target_tags = PackedStringArray(["State.Enabled"])
	system.tags.add_tag(&"State.Enabled")
	handle = system.effects.apply_effect(effect, system.create_effect_context())
	spec = _find_grant(system, handle)
	system.tags.remove_tag(&"State.Enabled")
	system.tags.add_tag(&"State.Enabled")
	_check(spec != null and _find_grant(system, handle) == spec and system.get_granted_ability_specs().size() == 1,
			"A kept grant survives inhibition without a duplicate on reactivation")
	system.effects.remove_effect(handle)
	_check(spec != null and system.try_activate_spec(spec.handle), "Keep Ability preserves the grant after effect removal")
	system.get_parent().free()


func _test_reentrant_removal_during_grant() -> void:
	var system := _new_actor()
	var rule := AttributeGameplayEventRule.new()
	rule.attribute = CombatAttributes.Id.CARRIED_WEIGHT
	rule.threshold_attribute = CombatAttributes.Id.CARRY_CAPACITY
	rule.entered_event = &"Event.Test.AboveCapacity"
	rule.exited_event = &"Event.Test.WithinCapacity"
	system.attributes.gameplay_event_rules = [rule]
	system.attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT,
			system.attributes.get_value(CombatAttributes.Id.CARRY_CAPACITY) + 1.0)
	var ability := _new_ability(&"remove_own_grant")
	ability.activation_event_tag = rule.entered_event
	ability.execution = RemoveGrantOnActivation.new()
	var grant := GrantAbilityEffectComponent.new()
	grant.ability = ability
	var effect := _new_effect([grant])
	_check(system.effects.apply_effect(effect, system.create_effect_context()) == 0
			and system.get_granted_ability_specs().is_empty() and system.get_active_cast(ability.ability_id) == null,
			"A grant that removes its effect synchronously leaves neither an ability nor a cast behind")
	system.get_parent().free()


func _test_ability_tag_blocks() -> void:
	var system := _new_actor()
	var attack := _new_ability(&"attack")
	attack.ability_tags = PackedStringArray(["Ability.Test.Attack.Light"])
	var grant := system.grant_ability_spec(attack)
	var block := BlockAbilitiesEffectComponent.new()
	block.blocked_ability_tags = PackedStringArray(["Ability.Test.Attack"])
	var first := _new_effect([block])
	first.ongoing_required_target_tags = PackedStringArray(["State.Enabled"])
	var second := _new_effect([block])
	_check(system.try_activate_spec(grant), "The tagged ability can start before the effect is applied")
	system.tags.add_tag(&"State.Enabled")
	var first_handle := system.effects.apply_effect(first, system.create_effect_context())
	var second_handle := system.effects.apply_effect(second, system.create_effect_context())
	_check(system.get_active_cast_for_spec(grant) != null, "A block prevents new activations and leaves existing casts active")
	system.get_active_cast_for_spec(grant).finish()
	_check(system.get_activation_failure_for_spec(grant) == &"blocked_by_ability_tags",
			"Active effects block matching descendant ability asset tags")
	system.tags.remove_tag(&"State.Enabled")
	_check(system.effects.is_effect_inhibited(first_handle)
			and system.get_activation_failure_for_spec(grant) == &"blocked_by_ability_tags",
			"Inhibiting one block preserves the other owner's contribution")
	system.effects.remove_effect(second_handle)
	_check(system.try_activate_spec(grant), "Removing the last active block allows another cast")
	system.get_parent().free()


func _test_effect_asset_tag_removal() -> void:
	var system := _new_actor()
	var tagged := _new_effect([])
	tagged.asset_tags = PackedStringArray(["Effect.Test.Removable.Child"])
	tagged.stacking_type = GameplayEffectDefinition.StackingType.AGGREGATE_BY_TARGET
	var first := system.effects.apply_effect(tagged, system.create_effect_context())
	system.effects.apply_effect(tagged, system.create_effect_context())
	var owns_tag := _new_effect([])
	owns_tag.granted_tags = tagged.asset_tags.duplicate()
	var second := system.effects.apply_effect(owns_tag, system.create_effect_context())
	var removal := RemoveEffectsEffectComponent.new()
	removal.effect_asset_tags = PackedStringArray(["Effect.Test.Removable"])
	var cleanser := _new_effect([removal])
	cleanser.asset_tags = tagged.asset_tags.duplicate()
	var third := system.effects.apply_effect(cleanser, system.create_effect_context())
	_check(not system.effects.has_retained_effect(first), "A matching asset-tag query removes the entire stack")
	_check(system.effects.has_retained_effect(second), "A matching granted actor tag alone does not select an effect")
	_check(system.effects.has_retained_effect(third), "The component excludes its own effect definition from removal")
	system.get_parent().free()


func _new_actor() -> AbilitySystem:
	var actor := Node.new()
	actor.process_mode = Node.PROCESS_MODE_DISABLED
	var attributes := ActorAttributes.new()
	var system := AbilitySystem.new()
	system.attributes = attributes
	actor.add_child(attributes)
	actor.add_child(system)
	root.add_child(actor)
	return system


func _new_ability(id: StringName) -> AbilityDefinition:
	var ability := AbilityDefinition.new()
	ability.ability_id = id
	ability.execution = HeldExecution.new()
	return ability


func _new_effect(components: Array[GameplayEffectComponent]) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.timing = GameplayEffectDefinition.Timing.INFINITE
	effect.components = components
	return effect


func _find_grant(system: AbilitySystem, effect_handle: int) -> GameplayAbilitySpec:
	for spec in system.get_granted_ability_specs():
		if spec.granting_effect_handle == effect_handle:
			return spec
	return null


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
