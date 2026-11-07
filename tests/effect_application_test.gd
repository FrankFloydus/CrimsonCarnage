extends SceneTree
## Exercises application policy without relying on saved gameplay tuning.

const ATTRIBUTES = preload("res://tests/attribute_fixture.gd")

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var actor := ATTRIBUTES.new_attributes()
	var tags := GameplayTagSet.new()
	var runtime := GameplayEffectRuntime.new(actor, tags)
	var context := GameplayEffectContext.capture(actor, tags)
	var restore := _instant_mana(5.0)
	var chance := ChanceToApplyEffectComponent.new()
	chance.chance_percent = 0.0
	restore.components.append(chance)
	actor.set_base_value(CombatAttributes.Id.MANA, 20.0)
	_check(runtime.can_apply_effect(restore), "A chance roll is deferred until application")
	_check(runtime.apply_effect(restore, context) == 0 and actor.get_value(CombatAttributes.Id.MANA) == 20.0,
			"A rejected chance applies no modifiers")
	chance.chance_percent = 100.0
	var secondary := _instant_mana(7.0)
	var additional := AdditionalEffectsComponent.new()
	additional.on_application_effects.append(secondary)
	restore.components.append(additional)
	_check(runtime.apply_effect(restore, context) > 0 and actor.get_value(CombatAttributes.Id.MANA) == 32.0,
			"Successful application executes the parent and its additional effect")

	var immunity := ImmunityEffectComponent.new()
	immunity.blocked_asset_tags = PackedStringArray(["Effect.Test.Recovery"])
	var shield := GameplayEffectDefinition.new()
	shield.kind = GameplayEffectDefinition.Kind.MODIFIERS
	shield.timing = GameplayEffectDefinition.Timing.INFINITE
	shield.ongoing_required_target_tags = PackedStringArray(["State.Test.Shielded"])
	shield.components.append(immunity)
	secondary.asset_tags = PackedStringArray(["Effect.Test.Recovery.Mana"])
	var handle := runtime.apply_effect(shield, context)
	_check(handle > 0 and runtime.is_effect_inhibited(handle), "A retained shield starts inhibited")
	tags.add_tag(&"State.Test.Shielded")
	_check(runtime.apply_effect(secondary, context) == 0 and actor.get_value(CombatAttributes.Id.MANA) == 32.0,
			"Immunity rejects specs with a matching effect asset tag")
	tags.remove_tag(&"State.Test.Shielded")
	_check(runtime.apply_effect(secondary, context) > 0 and actor.get_value(CombatAttributes.Id.MANA) == 39.0,
			"Inhibiting the shield releases the immunity filter")
	tags.add_tag(&"State.Test.Shielded")
	runtime.remove_effect(handle)
	_check(runtime.apply_effect(secondary, context) > 0 and actor.get_value(CombatAttributes.Id.MANA) == 46.0,
			"Removing the shield releases its reinstated immunity filter")
	actor.free()
	print("Gameplay effect application checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _instant_mana(amount: float) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.kind = GameplayEffectDefinition.Kind.MODIFIERS
	var modifier := AttributeModifier.new()
	modifier.attribute = CombatAttributes.Id.MANA
	modifier.value = amount
	effect.modifiers.append(modifier)
	return effect


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
