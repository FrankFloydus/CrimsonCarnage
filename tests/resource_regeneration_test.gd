extends SceneTree
## Periodic regeneration effect behavior, ownership, limits and callback safety.

const ATTRIBUTE_FIXTURE = preload("res://tests/attribute_fixture.gd")

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_defaults_and_primary_independence()
	_test_modifier_order_and_removal()
	_test_recovery_after_spending_and_damage()
	_test_frame_partition_independence()
	_test_capacity_and_no_overflow_banking()
	_test_no_recovery_while_dead()
	_test_invalid_time_steps()
	_test_reentrant_recovery()
	_test_death_during_recovery()
	_test_modifier_changes_during_recovery()
	_test_capacity_changes_during_recovery()
	_test_overlapping_stamina_recovery_blocks()
	_test_small_change_signals()
	await _test_automatic_asc_recovery()
	print("Resource regeneration checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_defaults_and_primary_independence() -> void:
	var actor := _actor()
	_close(actor.get_value(CombatAttributes.Id.HEALTH_REGEN), 0.0, "Health recovery requires investment")
	_close(actor.get_value(CombatAttributes.Id.STAMINA_REGEN), 10.0, "Starting Stamina recovery is ten points per second")
	_close(actor.get_value(CombatAttributes.Id.MANA_REGEN), 5.0, "Starting Mana recovery is five points per second")
	_check(CombatAttributes.regeneration_for(CombatAttributes.Id.HEALTH) == CombatAttributes.Id.HEALTH_REGEN,
			"Health maps to its own stable regeneration identity")
	_check(CombatAttributes.regeneration_for(CombatAttributes.Id.STAMINA) == CombatAttributes.Id.STAMINA_REGEN,
			"Stamina maps to its own regeneration identity")
	_check(CombatAttributes.regeneration_for(CombatAttributes.Id.MANA) == CombatAttributes.Id.MANA_REGEN,
			"Mana maps to its own regeneration identity")
	_check(CombatAttributes.regeneration_for(CombatAttributes.Id.STRENGTH) == CombatAttributes.Id.NONE,
			"A primary attribute is not a recoverable pool")
	for value: float in [0.0, 10.0, 128.0, 1000.0]:
		actor.level = 60
		for primary: int in [CombatAttributes.Id.STRENGTH, CombatAttributes.Id.DEXTERITY,
				CombatAttributes.Id.INTELLECT, CombatAttributes.Id.VITALITY]:
			actor.set_base_value(primary, value)
		_close(actor.get_value(CombatAttributes.Id.HEALTH_REGEN), 0.0, "Primaries do not grant Health recovery")
		_close(actor.get_value(CombatAttributes.Id.STAMINA_REGEN), 10.0, "Vitality and level do not grant Stamina recovery")
		_close(actor.get_value(CombatAttributes.Id.MANA_REGEN), 5.0, "Intellect and level do not grant Mana recovery")
	for id: int in [CombatAttributes.Id.HEALTH_REGEN, CombatAttributes.Id.STAMINA_REGEN, CombatAttributes.Id.MANA_REGEN]:
		actor.set_base_value(id, 1000000000.0)
		_close(actor.get_value(id), 1000000000.0, "Regeneration has no upper cap")
		actor.set_base_value(id, -100.0)
		_close(actor.get_value(id), 0.0, "Regeneration has a zero minimum")
	actor.free()


func _test_modifier_order_and_removal() -> void:
	var actor := _actor()
	var runtime := _runtime(actor)
	var health_flat := _modifier(CombatAttributes.Id.HEALTH_REGEN, 6.0)
	var modifiers: Array[AttributeModifier] = [
		health_flat,
		_modifier(CombatAttributes.Id.HEALTH_REGEN, 40.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(CombatAttributes.Id.HEALTH_REGEN, 25.0, AttributeModifier.Operation.MORE_PERCENT),
		_modifier(CombatAttributes.Id.MANA_REGEN, 3.0),
		_modifier(CombatAttributes.Id.MANA_REGEN, 40.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(CombatAttributes.Id.STAMINA_REGEN, 5.0),
		_modifier(CombatAttributes.Id.STAMINA_REGEN, 20.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(CombatAttributes.Id.STAMINA_REGEN, 30.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(CombatAttributes.Id.STAMINA_REGEN, 20.0, AttributeModifier.Operation.MORE_PERCENT),
	]
	actor.set_modifiers(&"regen_gear", modifiers)
	_close(actor.get_value(CombatAttributes.Id.HEALTH_REGEN), 10.5, "Health flat, increased and More use the shared calculation")
	_close(actor.get_value(CombatAttributes.Id.MANA_REGEN), 11.2, "Mana flat bonuses join the base before increased")
	_close(actor.get_value(CombatAttributes.Id.STAMINA_REGEN), 27.0, "Stamina increased bonuses combine before More")
	health_flat.value = 10000.0
	_close(actor.get_value(CombatAttributes.Id.HEALTH_REGEN), 10.5, "Authored resources cannot mutate registered recovery")
	actor.set_base_value(CombatAttributes.Id.HEALTH, 100.0)
	actor.set_base_value(CombatAttributes.Id.STAMINA, 0.0)
	actor.set_base_value(CombatAttributes.Id.MANA, 0.0)
	runtime.advance(2.0)
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 121.0, "Health regeneration restores the correct absolute amount")
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 54.0, "Stamina regeneration uses its own rate")
	_close(actor.get_value(CombatAttributes.Id.MANA), 22.4, "Mana regeneration uses its own rate")
	actor.remove_modifiers(&"regen_gear")
	_close(actor.get_value(CombatAttributes.Id.HEALTH_REGEN), 0.0, "Removing Health recovery investment restores zero")
	_close(actor.get_value(CombatAttributes.Id.STAMINA_REGEN), 10.0, "Removing gear preserves base Stamina recovery")
	_close(actor.get_value(CombatAttributes.Id.MANA_REGEN), 5.0, "Removing gear preserves base Mana recovery")
	actor.set_modifiers(&"suppressed", [
		_modifier(CombatAttributes.Id.MANA_REGEN, -100.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(CombatAttributes.Id.STAMINA_REGEN, -200.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 22.4, "Suppressed recovery cannot drain Mana")
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 54.0, "A negative More factor cannot invert recovery")
	actor.free()


func _test_recovery_after_spending_and_damage() -> void:
	var actor := _actor()
	var runtime := _runtime(actor)
	actor.apply_damage(20.0)
	actor.modify_current(CombatAttributes.Id.STAMINA, -40.0)
	actor.modify_current(CombatAttributes.Id.MANA, -40.0)
	runtime.advance(0.1)
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 180.0, "Default Health does not regenerate")
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 61.0, "Stamina starts recovering immediately after spending")
	_close(actor.get_value(CombatAttributes.Id.MANA), 60.5, "Mana starts recovering immediately after spending")
	for step in 10:
		actor.modify_current(CombatAttributes.Id.STAMINA, -2.0)
		actor.modify_current(CombatAttributes.Id.MANA, -2.0)
		actor.apply_damage(1.0)
		runtime.advance(0.1)
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 51.0, "Repeated spending cannot restart a recovery delay")
	_close(actor.get_value(CombatAttributes.Id.MANA), 45.5, "Repeated damage and casting costs do not suppress Mana recovery")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 170.0, "Recovery introduces no free Health restoration")
	actor.free()


func _test_frame_partition_independence() -> void:
	for steps: int in [1, 10, 60, 240]:
		var actor := _actor()
		var runtime := _runtime(actor)
		actor.set_base_value(CombatAttributes.Id.HEALTH_REGEN, 4.0)
		actor.set_base_value(CombatAttributes.Id.HEALTH, 100.0)
		actor.set_base_value(CombatAttributes.Id.STAMINA, 0.0)
		actor.set_base_value(CombatAttributes.Id.MANA, 0.0)
		for step in steps:
			runtime.advance(2.0 / steps)
		_close(actor.get_value(CombatAttributes.Id.HEALTH), 108.0, "Health recovery is independent of frame partition")
		_close(actor.get_value(CombatAttributes.Id.STAMINA), 20.0, "Stamina recovery is independent of frame partition")
		_close(actor.get_value(CombatAttributes.Id.MANA), 10.0, "Mana recovery is independent of frame partition")
		actor.free()


func _test_capacity_and_no_overflow_banking() -> void:
	var actor := _actor()
	var runtime := _runtime(actor)
	actor.set_base_value(CombatAttributes.Id.HEALTH_REGEN, 2.0)
	runtime.advance(1.0)
	actor.modify_current(CombatAttributes.Id.MANA, -20.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 80.0, "Unused recovery cannot be banked at full capacity")
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 85.0, "Only elapsed time after spending contributes recovery")
	actor.set_base_value(CombatAttributes.Id.MAX_MANA, 200.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 85.0, "Increasing capacity never refills Mana")
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 90.0, "Larger capacity does not increase the recovery rate")
	runtime.advance(25.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 200.0, "Recovery stops at the current maximum")
	actor.set_base_value(CombatAttributes.Id.MAX_MANA, 50.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 50.0, "Losing maximum capacity clamps the current pool")
	actor.set_base_value(CombatAttributes.Id.MAX_MANA, 100.0)
	actor.set_base_value(CombatAttributes.Id.MANA, 0.0)
	actor.set_base_value(CombatAttributes.Id.MANA_REGEN, 1.0e308)
	var long_period := _runtime(actor, 2.0)
	long_period.advance(2.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 100.0, "A huge finite recovery step clamps overflow safely")
	actor.free()


func _test_no_recovery_while_dead() -> void:
	var actor := _actor()
	var runtime := _runtime(actor)
	actor.set_base_value(CombatAttributes.Id.HEALTH_REGEN, 1000000.0)
	actor.set_base_value(CombatAttributes.Id.STAMINA, 20.0)
	actor.set_base_value(CombatAttributes.Id.MANA, 20.0)
	actor.apply_damage(1000000.0)
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 0.0, "Health regeneration never resurrects an actor")
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 20.0, "Dead actors do not regenerate Stamina")
	_close(actor.get_value(CombatAttributes.Id.MANA), 20.0, "Dead actors do not regenerate Mana")
	actor.restore_resources()
	actor.modify_current(CombatAttributes.Id.MANA, -20.0)
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 85.0, "An explicit reset permits future recovery without a banked interval")
	actor.free()


func _test_invalid_time_steps() -> void:
	var actor := _actor()
	var runtime := _runtime(actor)
	actor.set_base_value(CombatAttributes.Id.HEALTH_REGEN, 2.0)
	actor.apply_damage(50.0)
	actor.modify_current(CombatAttributes.Id.STAMINA, -50.0)
	actor.modify_current(CombatAttributes.Id.MANA, -50.0)
	for delta: float in [0.0, -1.0, INF, -INF, NAN]:
		runtime.advance(delta)
		_close(actor.get_value(CombatAttributes.Id.HEALTH), 150.0, "Invalid elapsed time changes no Health")
		_close(actor.get_value(CombatAttributes.Id.STAMINA), 50.0, "Invalid elapsed time changes no Stamina")
		_close(actor.get_value(CombatAttributes.Id.MANA), 50.0, "Invalid elapsed time changes no Mana")
	actor.free()


func _test_reentrant_recovery() -> void:
	var actor := _actor()
	var runtime := _runtime(actor, 0.5)
	actor.set_base_value(CombatAttributes.Id.STAMINA, 20.0)
	actor.set_base_value(CombatAttributes.Id.MANA, 20.0)
	var observations: Array[Vector3] = []
	actor.attribute_changed.connect(func(id: int, previous: float, value: float) -> void:
		observations.append(Vector3(id, previous, value))
		runtime.advance(100.0))
	runtime.advance(0.5)
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 25.0, "A change listener cannot recursively advance Stamina")
	_close(actor.get_value(CombatAttributes.Id.MANA), 22.5, "A change listener cannot recursively advance Mana")
	_check(observations.size() == 2, "Each changed pool emits one event for the accepted interval")
	if observations.size() == 2:
		_close(observations[0].y, 20.0, "The first event carries the actual previous pool value")
		_close(observations[0].z, 25.0, "The first event carries the actual recovered pool value")
		_close(observations[1].y, 20.0, "The second event carries its own previous value")
		_close(observations[1].z, 22.5, "The second event carries its own recovered value")
	actor.free()


func _test_death_during_recovery() -> void:
	var actor := _actor()
	var runtime := _runtime(actor)
	actor.set_base_value(CombatAttributes.Id.HEALTH_REGEN, 2.0)
	actor.set_base_value(CombatAttributes.Id.HEALTH, 100.0)
	actor.set_base_value(CombatAttributes.Id.STAMINA, 20.0)
	actor.set_base_value(CombatAttributes.Id.MANA, 20.0)
	actor.attribute_changed.connect(func(id: int, previous: float, value: float) -> void:
		if id == CombatAttributes.Id.HEALTH and value > previous:
			actor.apply_damage(10000.0))
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 0.0, "A callback may kill an actor during recovery")
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 21.0, "The current recovery period commits before death callbacks")
	_close(actor.get_value(CombatAttributes.Id.MANA), 20.5, "Death suppresses recovery on every later period")
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 0.0, "The recovery guard is released without reviving the actor")
	actor.free()


func _test_modifier_changes_during_recovery() -> void:
	var actor := _actor()
	var runtime := _runtime(actor)
	actor.set_base_value(CombatAttributes.Id.STAMINA, 20.0)
	actor.set_base_value(CombatAttributes.Id.MANA, 20.0)
	actor.attribute_changed.connect(func(id: int, _previous: float, _value: float) -> void:
		if id == CombatAttributes.Id.STAMINA:
			actor.set_modifiers(&"stop_mana", [
				_modifier(CombatAttributes.Id.MANA_REGEN, -100.0, AttributeModifier.Operation.ADD_PERCENT)]))
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 30.0, "Earlier pool recovery still commits")
	_close(actor.get_value(CombatAttributes.Id.MANA), 20.5, "A change listener updates the rate for the next execution")
	actor.set_base_value(CombatAttributes.Id.STAMINA, 100.0)
	actor.remove_modifiers(&"stop_mana")
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 25.5, "Removing suppression restores only its owned contribution")
	actor.free()


func _test_capacity_changes_during_recovery() -> void:
	var actor := _actor()
	var runtime := _runtime(actor)
	actor.set_base_value(CombatAttributes.Id.STAMINA, 20.0)
	actor.set_base_value(CombatAttributes.Id.MANA, 80.0)
	actor.attribute_changed.connect(func(id: int, _previous: float, _value: float) -> void:
		if id == CombatAttributes.Id.STAMINA:
			actor.set_base_value(CombatAttributes.Id.MAX_MANA, 50.0))
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 50.0, "A callback's capacity reduction is respected before recovery")
	actor.set_base_value(CombatAttributes.Id.STAMINA, 100.0)
	actor.set_base_value(CombatAttributes.Id.MAX_MANA, 100.0)
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.MANA), 55.0, "Capacity restoration neither refills nor banks regeneration")
	actor.free()


func _test_small_change_signals() -> void:
	var actor := _actor()
	var runtime := _runtime(actor, 1.0 / 60.0)
	actor.set_base_value(CombatAttributes.Id.MAX_STAMINA, 100000000.0)
	actor.set_base_value(CombatAttributes.Id.STAMINA, 99999999.0)
	var amounts: Array[float] = []
	actor.attribute_changed.connect(func(id: int, previous: float, value: float) -> void:
		if id == CombatAttributes.Id.STAMINA:
			amounts.append(value - previous))
	runtime.advance(1.0 / 60.0)
	_check(amounts.size() == 1, "Small real changes on a large pool still emit a resource signal")
	if amounts.size() == 1:
		_close(amounts[0], 1.0 / 6.0, "The signal preserves fractional recovery instead of presentation rounding")
	runtime.advance(1.0)
	amounts.clear()
	runtime.advance(1.0)
	_check(amounts.is_empty(), "A full resource does not emit redundant recovery signals")
	actor.free()


func _test_overlapping_stamina_recovery_blocks() -> void:
	var actor := _actor()
	var tags := GameplayTagSet.new()
	var block_tag := &"State.Stamina.RecoveryBlocked"
	var runtime := _runtime(actor, 1.0, tags)
	actor.set_base_value(CombatAttributes.Id.HEALTH_REGEN, 3.0)
	actor.set_base_value(CombatAttributes.Id.STAMINA_REGEN, 10.0)
	actor.set_base_value(CombatAttributes.Id.MANA_REGEN, 5.0)
	actor.set_base_value(CombatAttributes.Id.HEALTH, 40.0)
	actor.set_base_value(CombatAttributes.Id.STAMINA, 40.0)
	actor.set_base_value(CombatAttributes.Id.MANA, 40.0)
	tags.add_tag(block_tag)
	tags.add_tag(block_tag)
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 40.0, "The recovery block pauses Stamina")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 43.0, "The recovery block allows Health recovery")
	_close(actor.get_value(CombatAttributes.Id.MANA), 45.0, "The recovery block allows Mana recovery")
	tags.remove_tag(block_tag)
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 40.0, "One remaining tag owner still blocks recovery")
	tags.remove_tag(block_tag)
	runtime.advance(1.0)
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 50.0, "The final removal resumes recovery without banking it")
	actor.free()


func _test_automatic_asc_recovery() -> void:
	var holder := Node.new()
	var actor := ActorAttributes.new()
	var system := AbilitySystem.new()
	system.attributes = actor
	ATTRIBUTE_FIXTURE.configure(system)
	holder.add_child(actor)
	holder.add_child(system)
	root.add_child(holder)
	var startup_handles := system.effects.get_retained_effects().keys()
	_check(system.effects.active_count(&"Effect.DefaultAttributes") == 0
			and system.effects.active_count(&"Effect.AttributeDerivations") == 1
			and system.effects.active_count(&"Effect.ResourceRegeneration") == 1,
			"Startup executes the default effect and retains exactly one instance of each ongoing effect")
	var transient := GameplayEffectDefinition.new()
	transient.kind = GameplayEffectDefinition.Kind.MODIFIERS
	transient.timing = GameplayEffectDefinition.Timing.INFINITE
	transient.granted_tags = PackedStringArray(["State.Fixture.Transient"])
	var transient_handle := system.effects.apply_effect(transient, system.create_effect_context())
	_check(system.effects.has_retained_effect(transient_handle), "The actor receives the transient effect")
	system.clear_transient_effects()
	_check(system.effects.get_retained_effects().keys() == startup_handles
			and not system.tags.has_tag(&"State.Fixture.Transient"),
			"A gameplay reset removes the transient effect and preserves the original startup handles")
	actor.apply_damage(20.0)
	actor.set_base_value(CombatAttributes.Id.STAMINA, 0.0)
	actor.set_base_value(CombatAttributes.Id.MANA, 0.0)
	for frame in 12:
		await process_frame
	system.set_process(false)
	_check(actor.get_value(CombatAttributes.Id.STAMINA) > 0.0, "The ASC advances periodic Stamina recovery")
	_check(actor.get_value(CombatAttributes.Id.MANA) > 0.0, "The ASC advances periodic Mana recovery")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 180.0, "The periodic effect preserves zero-rate Health recovery")
	var mana := actor.get_value(CombatAttributes.Id.MANA)
	actor.set_base_value(CombatAttributes.Id.INTELLECT, 25.0)
	_close(actor.get_value(CombatAttributes.Id.MAX_MANA), 175.0, "The retained derivation updates from live Intellect")
	_close(actor.get_value(CombatAttributes.Id.MANA), mana, "Raising derived maximum Mana does not refill the pool")
	holder.free()


func _actor() -> ActorAttributes:
	return ATTRIBUTE_FIXTURE.new_attributes()


func _runtime(actor: ActorAttributes, period: float = ATTRIBUTE_FIXTURE.REGENERATION_PERIOD,
		tags: GameplayTagSet = null) -> GameplayEffectRuntime:
	var runtime := GameplayEffectRuntime.new(actor, tags)
	_check(ATTRIBUTE_FIXTURE.attach_regeneration(runtime, actor, period) > 0,
			"The periodic regeneration fixture is accepted")
	return runtime


func _modifier(id: int, amount: float,
		operation: AttributeModifier.Operation = AttributeModifier.Operation.ADD) -> AttributeModifier:
	var modifier := AttributeModifier.new()
	modifier.attribute = id
	modifier.value = amount
	modifier.operation = operation
	return modifier


func _close(actual: float, expected: float, label: String) -> void:
	_check(absf(actual - expected) <= 0.000001, "%s: %.9f expected %.9f" % [label, actual, expected])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
