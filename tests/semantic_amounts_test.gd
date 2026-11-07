extends SceneTree
## Covers authored magnitude bases and committed healing and resource changes.

const HEALTH := CombatAttributes.Id.HEALTH
const MANA := CombatAttributes.Id.MANA
const STAMINA := CombatAttributes.Id.STAMINA

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var owner := Node3D.new()
	var attributes := ActorAttributes.new()
	attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 100.0)
	attributes.set_base_value(CombatAttributes.Id.MAX_MANA, 200.0)
	attributes.set_base_value(CombatAttributes.Id.MAX_STAMINA, 50.0)
	attributes.restore_resources()
	var system := AbilitySystem.new()
	system.attributes = attributes
	owner.add_child(attributes)
	owner.add_child(system)
	root.add_child(owner)
	_test_amount_authoring_fields()
	_test_captured_basis(attributes)
	_test_spend(attributes)
	_test_outcome_basis(attributes)
	_test_owned_amounts()
	_test_healing(system)
	_test_damage_execution(system)
	_test_damage_profile(system)
	owner.free()
	print("Semantic amount and recovery checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_amount_authoring_fields() -> void:
	var amount := AmountDefinition.new()
	var dependencies := {
		AmountDefinition.Source.FIXED: [&"fixed_amount"],
		AmountDefinition.Source.STAT_PERCENT: [&"percentage", &"actor", &"stat", &"timing"],
		AmountDefinition.Source.RESOURCE_PERCENT: [
			&"percentage", &"actor", &"resource", &"resource_basis", &"timing",
		],
		AmountDefinition.Source.LEVEL_CURVE: [&"percentage", &"actor", &"timing", &"curve_input", &"curve"],
		AmountDefinition.Source.OUTCOME_PERCENT: [&"percentage", &"outcome_basis"],
		AmountDefinition.Source.SPEND_PERCENT: [&"percentage", &"resource", &"curve"],
		AmountDefinition.Source.ACCUMULATOR_PERCENT: [&"percentage"],
		AmountDefinition.Source.STACK_PROGRESSION: [&"percentage", &"curve"],
		AmountDefinition.Source.UNIQUE_TARGET_COUNT: [&"amount_per_target"],
	}
	for input: AmountDefinition.Source in dependencies:
		amount.source = input
		_check_amount_fields(amount, dependencies[input])

	var refreshes := [0]
	amount.property_list_changed.connect(func() -> void: refreshes[0] += 1)
	amount.source = AmountDefinition.Source.LEVEL_CURVE
	amount.curve_input = AmountDefinition.CurveInput.ABILITY_RANK
	amount.clamp_enabled = true
	_check(refreshes[0] == 3, "Amount selectors and the clamp toggle refresh the Inspector")
	_check_amount_fields(amount, [&"percentage", &"curve_input", &"curve", &"minimum", &"maximum"])

	amount.actor = AmountDefinition.ActorRole.TARGET
	amount.timing = AmountDefinition.Timing.SNAPSHOT
	amount.minimum = 4.0
	amount.clamp_enabled = false
	var copy := amount.duplicate() as AmountDefinition
	_check(copy.actor == AmountDefinition.ActorRole.TARGET \
			and copy.timing == AmountDefinition.Timing.SNAPSHOT and copy.minimum == 4.0,
			"Hidden actor, timing, and clamp inputs remain stored when the Resource is copied")


func _check_amount_fields(amount: AmountDefinition, dependencies: Array) -> void:
	var visible: Array[StringName] = []
	var expected: Array[StringName] = [&"source", &"unit", &"clamp_enabled"]
	expected.append_array(dependencies)
	var fields: Array[StringName] = [
		&"source", &"unit", &"fixed_amount", &"percentage", &"actor", &"stat", &"resource",
		&"resource_basis", &"outcome_basis", &"timing", &"curve_input", &"curve",
		&"amount_per_target", &"clamp_enabled", &"minimum", &"maximum",
	]
	var stored_count := 0
	for property: Dictionary in amount.get_property_list():
		var field: StringName = property.name
		if field not in fields:
			continue
		var usage: int = property.usage
		if usage & PROPERTY_USAGE_EDITOR:
			visible.append(field)
		if usage & PROPERTY_USAGE_STORAGE:
			stored_count += 1
		if field == &"stat" and amount.source == AmountDefinition.Source.STAT_PERCENT:
			_check(property.hint == PROPERTY_HINT_ENUM \
					and property.hint_string == CombatAttributes.inspector_hint(false),
					"Stat Percent keeps the active combat stat picker")
	visible.sort()
	expected.sort()
	_check(visible == expected and stored_count == fields.size(),
			"Visible fields match Amount Source %s and all inputs remain stored (expected %s, got %s)"
			% [AmountDefinition.Source.keys()[amount.source], expected, visible])


func _test_captured_basis(attributes: ActorAttributes) -> void:
	var context := AmountEvaluationContext.new()
	context.source = attributes
	context.snapshot = context.capture()
	attributes.set_base_value(CombatAttributes.Id.MAX_MANA, 400.0)
	var amount := AmountDefinition.new()
	amount.source = AmountDefinition.Source.RESOURCE_PERCENT
	amount.percentage = 1.0
	amount.timing = AmountDefinition.Timing.SNAPSHOT
	_near(amount.evaluate(context), 2.0, "Snapshot keeps the original maximum Mana")
	amount.timing = AmountDefinition.Timing.LIVE
	_near(amount.evaluate(context), 4.0, "Live maximum Mana uses the changed capacity")
	amount.resource_basis = AmountDefinition.ResourceBasis.MISSING
	_near(amount.evaluate(context), 2.0, "Capacity growth does not refill the pool")
	amount.unit = AmountDefinition.Unit.SECONDS
	_check(amount.get_validation_error(AmountDefinition.Unit.POINTS) == &"incompatible_amount_unit",
			"An action can reject a mismatched magnitude unit")


func _test_spend(attributes: ActorAttributes) -> void:
	var rejected: Dictionary[int, float] = {MANA: 50.0, STAMINA: 51.0}
	_check(ResourceService.commit_spend(attributes, rejected) == null, "Unaffordable combined spend is rejected")
	_near(attributes.get_value(MANA), 200.0, "Rejected combined spend leaves Mana intact")
	_near(attributes.get_value(STAMINA), 50.0, "Rejected combined spend leaves Stamina intact")
	var seen_mana: Array[float] = []
	var on_spend := func(id: int, _previous: float, _current: float) -> void:
		if id == STAMINA:
			seen_mana.append(attributes.get_value(MANA))
	attributes.attribute_changed.connect(on_spend)
	var costs: Dictionary[int, float] = {MANA: 50.0, STAMINA: 7.0}
	var receipt := ResourceService.commit_spend(attributes, costs)
	attributes.attribute_changed.disconnect(on_spend)
	_check(receipt != null, "Affordable combined spend returns a receipt")
	if receipt == null:
		return
	_check(seen_mana == [150.0], "The first pool observer sees all committed spends")
	_check(receipt.get_amounts().is_read_only(), "Committed receipt is read-only")
	attributes.set_base_value(MANA, 390.0)
	var context := AmountEvaluationContext.new()
	context.spend_receipt = receipt
	var amount := AmountDefinition.new()
	amount.source = AmountDefinition.Source.SPEND_PERCENT
	amount.percentage = 20.0
	_near(amount.evaluate(context), 10.0, "Spend amount reads the receipt after the pool changed")
	var recovered := ResourceService.resolve_and_commit(ResourceRequest.new(attributes, 30.0))
	_near(recovered.actual_delta, 10.0, "Ordinary Mana recovery clamps to capacity")
	var drained := ResourceService.resolve_and_commit(ResourceRequest.new(
			attributes, -15.0, AmountDefinition.Pool.MANA, ResourceRequest.Reason.DRAIN))
	_near(drained.actual_delta, -15.0, "Signed Mana drains report their committed delta")


func _test_outcome_basis(attributes: ActorAttributes) -> void:
	var attribution := CombatOutcomeContext.create(attributes)
	var context := AmountEvaluationContext.new()
	context.outcome = CombatOutcome.new(attribution, {
		"type": &"damage", "raw_magnitude": 100.0, "resolved_amount": 65.0, "health_damage": 6.0,
	})
	var amount := AmountDefinition.new()
	amount.source = AmountDefinition.Source.OUTCOME_PERCENT
	amount.percentage = 10.0
	_near(amount.evaluate(context), 0.6, "Lifesteal basis reads actual overkill-clamped Health loss")
	amount.outcome_basis = AmountDefinition.OutcomeBasis.RAW_DAMAGE
	_near(amount.evaluate(context), 10.0, "Raw and actual Health damage are separate bases")
	amount.outcome_basis = AmountDefinition.OutcomeBasis.OVERHEAL
	_check(is_nan(amount.evaluate(context)), "A damage outcome has no healing amount")
	amount.source = AmountDefinition.Source.UNIQUE_TARGET_COUNT
	amount.unit = AmountDefinition.Unit.COUNT
	amount.percentage = 100.0
	_check(is_nan(amount.evaluate(context)), "A first contact cannot provide a batch count")
	context.outcome = CombatOutcome.new(attribution, {"type": &"batch_complete", "unique_target_count": 4})
	_near(amount.evaluate(context), 4.0, "A complete batch can provide its unique target count")


func _test_owned_amounts() -> void:
	var context := AmountEvaluationContext.new()
	context.accumulator = 40.0
	context.rank = 4
	context.stack_count = 2
	var amount := AmountDefinition.new()
	amount.source = AmountDefinition.Source.ACCUMULATOR_PERCENT
	amount.percentage = 50.0
	amount.clamp_enabled = true
	amount.maximum = 12.0
	_near(amount.evaluate(context), 12.0, "Owned accumulated amount scales and clamps")
	var curve := Curve.new()
	curve.max_domain = 4.0
	curve.max_value = 20.0
	curve.add_point(Vector2(0.0, 0.0))
	curve.add_point(Vector2(2.0, 4.0))
	curve.add_point(Vector2(4.0, 16.0))
	amount.curve = curve
	amount.percentage = 100.0
	amount.clamp_enabled = false
	amount.source = AmountDefinition.Source.LEVEL_CURVE
	amount.curve_input = AmountDefinition.CurveInput.ABILITY_RANK
	_near(amount.evaluate(context), 16.0, "An authored curve samples the exact ability rank")
	amount.source = AmountDefinition.Source.STACK_PROGRESSION
	_near(amount.evaluate(context), 4.0, "A separate stack curve uses the active effect stack count")


func _test_healing(system: AbilitySystem) -> void:
	var attributes := system.attributes
	var received := HealingReceivedEffectComponent.new()
	received.multiplier = 0.5
	var effect := GameplayEffectDefinition.new()
	effect.timing = GameplayEffectDefinition.Timing.INFINITE
	effect.components.append(received)
	var handle := system.apply_effect_spec_to_self(system.make_outgoing_spec(effect))
	_check(handle > 0, "Healing-received behavior is retained on its effect handle")
	attributes.set_base_value(HEALTH, 96.0)
	var profile := HealingProfile.new()
	profile.source_percent = 200.0
	var result := HealingResolver.resolve_and_commit(HealingRequest.new(attributes, 10.0, profile))
	var event := result.get_event()
	_near(event.source_scaled_healing, 20.0, "The healing profile scales the source once")
	_near(event.scaled_healing, 10.0, "Healing-received scales the offered amount")
	_near(event.actual_restoration, 4.0, "Healing is bounded by missing Health")
	_near(event.overheal, 6.0, "Overheal is independent of incoming healing reduction")

	var absorb := HealingAbsorptionEffectComponent.new()
	absorb.capacity = 5.0
	var barrier := GameplayEffectDefinition.new()
	barrier.timing = GameplayEffectDefinition.Timing.INFINITE
	barrier.components.append(absorb)
	var barrier_handle := system.apply_effect_spec_to_self(system.make_outgoing_spec(barrier))
	_check(barrier_handle > 0, "A retained healing absorption effect owns its budget")
	attributes.set_base_value(HEALTH, 96.0)
	var absorbed := HealingResolver.resolve_and_commit(HealingRequest.new(attributes, 10.0, profile))
	_near(absorbed.get_event().absorbed_healing, 5.0, "Healing absorption consumes the scaled offer")
	_near(absorbed.get_event().actual_restoration, 4.0, "Only unabsorbed healing reaches the pool")
	_near(absorbed.get_event().overheal, 1.0, "Absorbed healing is never counted as overheal")
	_check(not system.effects.has_retained_effect(barrier_handle),
			"The depleted healing barrier removes its own retained handle")

	var snapshot := HealingRequest.new(attributes, -15.0, profile)
	snapshot.mode = HealingRequest.Mode.SNAPSHOT_RESTORE
	var restored := HealingResolver.resolve_and_commit(snapshot)
	_near(restored.get_event().actual_health_delta, -15.0, "Snapshot restores a lower Health without damage")
	_check(not restored.get_event().proc_eligible, "Snapshot restoration opts out of healing reactions")
	attributes.set_base_value(HEALTH, 0.0)
	var rejected := HealingResolver.resolve_and_commit(HealingRequest.new(attributes, 20.0))
	_check(not rejected.committed, "An ordinary heal cannot revive a dead actor")
	_near(attributes.get_value(HEALTH), 0.0, "Dead recipient has no committed restoration")
	system.remove_active_effect(handle)


func _test_damage_execution(system: AbilitySystem) -> void:
	system.attributes.set_base_value(HEALTH, 100.0)
	system.attributes.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 25.0)
	var amount := AmountDefinition.new()
	amount.fixed_amount = 20.0
	var calculation := GameplayEffectDamageExecution.new()
	calculation.amount = amount
	var effect := GameplayEffectDefinition.new()
	effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	effect.executions.append(calculation)
	var handle := system.apply_effect_spec_to_self(system.make_outgoing_spec(effect))
	_check(handle > 0, "Damage with an authored semantic amount applies through Gameplay Effects")
	_near(system.attributes.get_value(HEALTH), 85.0, "The semantic amount enters the normal resistance calculation")
	_near(calculation.amount.fixed_amount, 20.0, "Applying damage leaves the shared amount definition unchanged")


func _test_damage_profile(system: AbilitySystem) -> void:
	var attributes := system.attributes
	attributes.set_base_value(CombatAttributes.Id.COLD_RESISTANCE, 20.0)
	var effect := GameplayEffectDefinition.new()
	effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	var calculation := GameplayEffectDamageExecution.new()
	calculation.amount = AmountDefinition.fixed(100.0)
	effect.executions.append(calculation)
	var context := system.create_effect_context()
	_near(CombatMath.resolve_effect(effect, context, attributes), 75.0,
			"A payload without a profile uses its single Combat 2.0 school resistance")
	attributes.set_base_value(CombatAttributes.Id.SPELL_PENETRATION, 25.0)
	var periodic := system.create_effect_context(PackedStringArray(["Ability.Spell"]))
	periodic.outcome_context = periodic.outcome_context.with_timing(CombatOutcomeContext.Timing.PERIODIC)
	_near(CombatMath.resolve_effect(effect, periodic, attributes), 75.0,
			"An instant carrier of copied periodic damage does not gain direct Spell Penetration")
	_check(effect.get_payload_context_tags(periodic).has("Damage.Periodic"),
			"Copied periodic damage retains the canonical periodic tag")

	var fire := DamageResistanceStage.new()
	var cold := DamageResistanceStage.new()
	cold.attribute = CombatAttributes.Id.COLD_RESISTANCE
	var profile := DamageProfile.new()
	profile.resource_name = "Elemental Resistance and Nonlethal"
	profile.defense_selection = DamageProfile.DefenseSelection.EXPLICIT
	profile.resistance_stages = [fire, cold]
	profile.nonlethal = true
	effect.damage_profile = profile
	var resolved := CombatMath.resolve_effect_result(effect, context, attributes)
	_near(resolved.magnitude, 60.0, "Independent 25% and 20% defenses multiply in order")
	_check(resolved.resistance_stages.size() == 2, "The resolver records both explicit defenses")
	attributes.set_base_value(HEALTH, 8.0)
	system.apply_effect_spec_to_self(system.make_outgoing_spec(effect, context))
	_near(attributes.get_value(HEALTH), 1.0, "A nonlethal profile caps actual loss after mitigation")
	profile.resistance_stages = [fire, fire]
	_check(effect.get_validation_error() == &"duplicate_damage_resistance_stage",
			"The profile rejects applying one resistance stat twice")


func _near(actual: float, expected: float, message: String) -> void:
	_check(is_equal_approx(actual, expected), "%s (expected %s, got %s)" % [message, expected, actual])


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
