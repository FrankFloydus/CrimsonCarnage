extends SceneTree
## Runs a designer-authored transfer phase through targeted activation and actual damage commitment.

const HEALTH := CombatAttributes.Id.HEALTH
const SHIELD_ID := 204
const ELIGIBLE := &"State.Test.Eligible"
const TRANSFER_ACTION := preload("res://combat/abilities/composition/ability_transfer_effect_action.gd")

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	var arena := Node3D.new()
	root.add_child(arena)
	var caster := _actor(arena)
	var donor := _actor(arena)
	donor.tags.add_tag(ELIGIBLE)
	var wrong := _shield()
	wrong.effect_id = 205
	wrong.asset_tags = PackedStringArray(["Effect.Beneficial"])
	wrong.components = []
	wrong.granted_tags = PackedStringArray(["State.Test.NonMagicalShield"])
	var wrong_handle := donor.effects.apply_effect(wrong, donor.create_effect_context())
	var eligible := _shield()
	var shield_handle := donor.effects.apply_effect(eligible, donor.create_effect_context())
	var second_handle := donor.effects.apply_effect(eligible, donor.create_effect_context())
	donor.effects.apply_effect(_damage(30.0), caster.create_effect_context())
	_check(wrong_handle > 0 and shield_handle > 0 and second_handle > 0
		and donor.attributes.get_value(HEALTH) == donor.attributes.get_value(CombatAttributes.Id.MAX_HEALTH),
		"Fixture damage depletes part of the first eligible pool without changing Health")
	var transfer := TRANSFER_ACTION.new()
	transfer.required_asset_tags = PackedStringArray(["Effect.Beneficial", "Effect.Magical"])
	transfer.duration_cap = 3.0
	var recipe := _recipe(transfer)
	_check(caster.grant_ability(recipe), "The transfer action can be granted as a composed recipe")
	_check(_activate(caster, donor, recipe) and donor.effects.has_retained_effect(shield_handle)
		and caster.effects.active_count(SHIELD_ID) == 0,
		"Destination rejection preserves the selected source effect")
	caster.tags.add_tag(ELIGIBLE)
	_check(_activate(caster, donor, recipe) and not donor.effects.has_retained_effect(shield_handle)
		and donor.effects.has_retained_effect(wrong_handle) and donor.effects.has_retained_effect(second_handle)
		and caster.effects.active_count(SHIELD_ID) == 1,
		"One matching transferable effect moves, preserving other and nonmatching effects")
	var handles := caster.effects.get_retained_effects().keys()
	_check(handles.size() == 1 and is_equal_approx(caster.effects.get_remaining(handles[0]), 3.0),
		"The transfer caps the remaining duration")
	var before := caster.attributes.get_value(HEALTH)
	caster.effects.apply_effect(_damage(25.0), donor.create_effect_context())
	_check(is_equal_approx(caster.attributes.get_value(HEALTH), before - 5.0),
		"Transfer keeps the depleted pool instead of restoring its authored capacity")
	caster.advance(3.0)
	_check(caster.effects.active_count(SHIELD_ID) == 0, "The transferred effect expires at the capped deadline")
	arena.free()
	print("Ability transfer checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _actor(arena: Node3D) -> AbilitySystem:
	var body := Node3D.new()
	var attributes := preload("res://tests/attribute_fixture.gd").new_attributes()
	var actor := AbilitySystem.new()
	actor.attributes = attributes
	body.add_child(attributes)
	body.add_child(actor)
	arena.add_child(body)
	actor.set_process(false)
	actor.set_physics_process(false)
	return actor


func _shield() -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.effect_id = SHIELD_ID
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.duration = 10.0
	effect.transferable = true
	effect.asset_tags = PackedStringArray(["Effect.Beneficial.Armor", "Effect.Magical"])
	effect.required_target_tags = PackedStringArray([String(ELIGIBLE)])
	var absorb := DamageDefenseEffectComponent.new()
	absorb.capacity = 50.0
	absorb.remove_when_depleted = false
	effect.components = [absorb]
	return effect


func _damage(points: float) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	var calculation := GameplayEffectDamageExecution.new()
	calculation.amount = AmountDefinition.fixed(points)
	effect.executions = [calculation]
	return effect


func _recipe(action: AbilityActionDefinition) -> AbilityDefinition:
	var phase := AbilityPhaseDefinition.new()
	phase.actions = [action]
	var execution := PhasedAbilityExecution.new()
	execution.targeting = AbilityTargetingDefinition.new()
	execution.targeting.shape = AbilityTargetingDefinition.Shape.SINGLE
	execution.delivery = AbilityDeliveryDefinition.new()
	execution.phases = [phase]
	var ability := AbilityDefinition.new()
	ability.ability_id = 206
	ability.execution = execution
	return ability


func _activate(caster: AbilitySystem, target: AbilitySystem, recipe: AbilityDefinition) -> bool:
	if not caster.try_activate_target(recipe.ability_id, target):
		return false
	var cast := caster.get_active_cast(recipe.ability_id)
	if cast == null:
		return false
	recipe.execution.physics_advance(cast, 1.0 / 60.0)
	return cast.finished and cast.released


func _check(passed: bool, message: String) -> void:
	_checks += 1
	if not passed:
		_failures += 1
		push_error(message)
