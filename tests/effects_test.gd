extends SceneTree
## Direct damage, owned timed modifiers and reentrant cleanup in Combat 2.0.
## Run: godot --headless --path . --script res://tests/effects_test.gd

const ATTRIBUTE_FIXTURE = preload("res://tests/attribute_fixture.gd")

var _checks: int = 0
var _failures: int = 0
var _actors: Array[ActorAttributes] = []
var _runtimes: Array[GameplayEffectRuntime] = []
var _tag_sets: Array[GameplayTagSet] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_direct_damage_and_telemetry()
	_test_owned_duration_and_independent_instances()
	_test_modifier_order_and_scopes()
	_test_immutable_application_data()
	_test_requirements_and_invalid_payloads()
	_test_authoritative_clear()
	_test_clear_during_modifier_setup()
	_test_clear_during_tag_setup()
	_test_reentrant_lifecycle_order()
	_test_reentrant_clear_notifications()
	_test_expiry_and_detached_inspection()
	_test_retained_effect_snapshots()
	for runtime in _runtimes:
		runtime.clear()
		for signal_name in [&"effect_applied", &"effect_removed", &"damage_applied", &"combat_event"]:
			for connection in runtime.get_signal_connection_list(signal_name):
				runtime.disconnect(signal_name, connection.callable)
	for tags in _tag_sets:
		for connection in tags.get_signal_connection_list(&"changed"):
			tags.disconnect(&"changed", connection.callable)
	for actor in _actors:
		actor.free()
	_runtimes.clear()
	_tag_sets.clear()
	_actors.clear()
	print("Effect checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _actor() -> ActorAttributes:
	var actor := ATTRIBUTE_FIXTURE.new_attributes()
	actor.set_base_value(CombatAttributes.Id.MAX_HEALTH, 200.0)
	actor.restore_resources()
	_actors.append(actor)
	return actor


func _runtime(actor: ActorAttributes, tags: GameplayTagSet = null) -> GameplayEffectRuntime:
	var runtime := GameplayEffectRuntime.new(actor, tags)
	_runtimes.append(runtime)
	if tags != null:
		_tag_sets.append(tags)
	return runtime


func _context(source: ActorAttributes) -> GameplayEffectContext:
	return GameplayEffectContext.capture(source, GameplayTagSet.new(),
			PackedStringArray(["Ability.Spell"]))


func _damage(amount: float) -> GameplayEffectDefinition:
	var definition := GameplayEffectDefinition.new()
	definition.effect_id = &"Effect.TestDamage"
	definition.display_name = "Test damage"
	var execution := GameplayEffectDamageExecution.new()
	execution.amount = AmountDefinition.fixed(amount)
	definition.executions = [execution]
	definition.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	return definition


func _modifier(attribute: CombatAttributes.Id, value: float,
		operation: AttributeModifier.Operation = AttributeModifier.Operation.ADD) -> AttributeModifier:
	var modifier := AttributeModifier.new()
	modifier.attribute = attribute
	modifier.value = value
	modifier.operation = operation
	return modifier


func _buff(duration: float = 2.0) -> GameplayEffectDefinition:
	var definition := GameplayEffectDefinition.new()
	definition.effect_id = &"Effect.Empowered"
	definition.display_name = "Empowered"
	definition.timing = GameplayEffectDefinition.Timing.DURATION
	definition.duration = duration
	definition.modifiers = [_modifier(CombatAttributes.Id.MAGIC_POWER, 50.0)]
	definition.granted_tags = PackedStringArray(["Buff.Empowered"])
	return definition


func _test_direct_damage_and_telemetry() -> void:
	var source := _actor()
	var target := _actor()
	source.set_base_value(CombatAttributes.Id.MAGIC_POWER, 100.0)
	var runtime := _runtime(target)
	var events: Array[Dictionary] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	var definition := _damage(30.0)
	definition.get_damage_execution().power_coefficient = 0.5
	var mana := target.get_value(CombatAttributes.Id.MANA)
	var stamina := target.get_value(CombatAttributes.Id.STAMINA)
	var handle := runtime.apply_effect(definition, _context(source))
	_check(handle > 0, "Accepted instant damage returns a positive handle")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 120.0, "Magic Power contributes to direct damage")
	_near(target.get_value(CombatAttributes.Id.MANA), mana, "Health damage does not change Mana")
	_near(target.get_value(CombatAttributes.Id.STAMINA), stamina, "Health damage does not change Stamina")
	_check(runtime.active_count() == 0 and not runtime.remove_effect(handle),
			"Instant damage does not retain a removable instance")
	_check(events.size() == 2 and events[0].type == &"effect_applied" and events[1].type == &"damage",
			"Application and damage telemetry retain delivery order")
	_near(events[1].amount, 80.0, "Telemetry reports actual removed Health")
	_near(events[1].resolved_amount, 80.0, "Telemetry also reports resolved damage")
	_check(not events[1].has("absorbed") and not events[1].has("critical"),
			"Damage telemetry contains no removed defense or critical rules")
	runtime.advance(100.0)
	_near(target.get_value(CombatAttributes.Id.HEALTH), 120.0,
			"Advancing time never repeats instant damage")
	runtime.apply_effect(_damage(1000.0), _context(source))
	_near(target.get_value(CombatAttributes.Id.HEALTH), 0.0, "Overkill clamps Health to zero")
	_near(events.back().amount, 120.0, "Overkill telemetry reports actual damage")
	_near(events.back().resolved_amount, 1000.0, "Overkill preserves resolved magnitude")
	_check(runtime.apply_effect(_damage(1.0), _context(source)) == 0,
			"Dead targets reject further damage effects")


func _test_owned_duration_and_independent_instances() -> void:
	var actor := _actor()
	var tags := GameplayTagSet.new()
	var runtime := _runtime(actor, tags)
	var base := actor.get_value(CombatAttributes.Id.MAGIC_POWER)
	var definition := _buff()
	var first := runtime.apply_effect(definition, _context(actor))
	var second := runtime.apply_effect(definition, _context(actor))
	_check(first > 0 and second > first, "Independent applications receive unique handles")
	_check(runtime.active_count(definition.effect_id) == 2, "Identical effects retain independent ownership")
	_near(actor.get_value(CombatAttributes.Id.MAGIC_POWER), base + 100.0, "Both instances contribute")
	_check(tags.get_count(&"Buff.Empowered") == 2, "Each instance owns its tag count")
	_check(runtime.remove_effect(first), "One retained handle can be removed")
	_near(actor.get_value(CombatAttributes.Id.MAGIC_POWER), base + 50.0, "Only its modifier is removed")
	_check(tags.has_tag(&"Buff") and tags.get_count(&"Buff.Empowered") == 1,
			"The surviving instance retains its tag")
	_check(not runtime.remove_effect(first), "A handle cannot be removed twice")
	runtime.advance(1.0)
	_check(runtime.active_count() == 1, "A duration survives before its deadline")
	runtime.advance(1.0)
	_near(actor.get_value(CombatAttributes.Id.MAGIC_POWER), base, "Expiry removes the surviving modifier")
	_check(runtime.active_count() == 0 and not tags.has_tag(&"Buff"), "Expiry releases retained tag ownership")


func _test_modifier_order_and_scopes() -> void:
	var actor := _actor()
	var runtime := _runtime(actor)
	actor.set_base_value(CombatAttributes.Id.MAGIC_POWER, 20.0)
	var definition := _buff(0.0)
	definition.modifiers = [
		_modifier(CombatAttributes.Id.MAGIC_POWER, 50.0),
		_modifier(CombatAttributes.Id.MAGIC_POWER, 50.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(CombatAttributes.Id.MAGIC_POWER, 20.0, AttributeModifier.Operation.MORE_PERCENT),
	]
	var handle := runtime.apply_effect(definition, _context(actor))
	_near(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 126.0,
			"Owned effects use flat foundation, increased sum, then more")
	runtime.advance(10000.0)
	_check(runtime.active_count() == 1, "Zero duration remains active until explicitly removed")
	runtime.remove_effect(handle)
	_near(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 20.0, "Removal restores the prior modifier foundation")
	var scoped := _buff()
	var bonus := _modifier(CombatAttributes.Id.PHYSICAL_POWER, 30.0)
	bonus.required_context_tags = PackedStringArray(["Weapon.Finesse"])
	scoped.modifiers = [bonus]
	handle = runtime.apply_effect(scoped, _context(actor))
	_near(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER,
			PackedStringArray(["Weapon.Finesse"])), 50.0, "Owned modifier respects its Finesse scope")
	_near(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER,
			PackedStringArray(["Weapon.Brutality"])), 20.0, "Scoped buff does not leak to Brutality")
	runtime.remove_effect(handle)


func _test_immutable_application_data() -> void:
	var actor := _actor()
	var tags := GameplayTagSet.new()
	var runtime := _runtime(actor, tags)
	var definition := _buff()
	var original := definition.modifiers[0].value
	var base := actor.get_value(CombatAttributes.Id.MAGIC_POWER)
	runtime.apply_effect(definition, _context(actor))
	definition.duration = 1000.0
	definition.modifiers[0].value = 999.0
	definition.granted_tags = PackedStringArray(["Buff.Changed"])
	definition.effect_id = &"Effect.Changed"
	_near(actor.get_value(CombatAttributes.Id.MAGIC_POWER), base + original,
			"Application copies its modifier values")
	_check(runtime.active_count(&"Effect.Empowered") == 1,
			"An active instance retains its application identity")
	runtime.advance(2.0)
	_check(runtime.active_count() == 0 and not tags.has_tag(&"Buff"),
			"Application snapshots its duration and granted tags")


func _test_requirements_and_invalid_payloads() -> void:
	var actor := _actor()
	var tags := GameplayTagSet.new()
	var runtime := _runtime(actor, tags)
	var definition := _buff()
	definition.required_target_tags = PackedStringArray(["Target.Eligible"])
	definition.blocked_target_tags = PackedStringArray(["Target.Immune"])
	_check(not runtime.can_apply_effect(definition), "Required target tags gate application")
	tags.add_tag(&"Target.Eligible.Enemy")
	_check(runtime.can_apply_effect(definition), "Parent queries match eligible descendants")
	tags.add_tag(&"Target.Immune")
	_check(runtime.apply_effect(definition, _context(actor)) == 0, "Authored blocking tags reject an effect")
	tags.remove_tag(&"Target.Immune")
	_check(runtime.apply_effect(definition, null) == 0, "A source context is required")
	definition.duration = -1.0
	_check(not runtime.can_apply_effect(definition), "Invalid authored duration is rejected")
	var invalid := _buff()
	invalid.timing = GameplayEffectDefinition.Timing.INSTANT
	invalid.modifiers[0].value = NAN
	var payload: Array[GameplayEffectDefinition] = [null, invalid, _damage(10.0)]
	var result := runtime.apply_hit_payload(payload, _context(actor), 0.0)
	_check(result.applied_effects == 1, "A delivered payload counts only accepted effects")
	_check(runtime.active_count() == 0, "Invalid effects never create retained state")


func _test_authoritative_clear() -> void:
	var actor := _actor()
	var tags := GameplayTagSet.new()
	var runtime := _runtime(actor, tags)
	var definition := _buff()
	var context := _context(actor)
	var removals: Array[int] = []
	runtime.apply_effect(definition, context)
	runtime.apply_effect(definition, context)
	runtime.effect_removed.connect(func(_definition: GameplayEffectDefinition) -> void:
		removals.append(runtime.apply_effect(definition, context)))
	runtime.clear()
	_check(removals == [0, 0], "Clear rejects applications attempted by removal callbacks")
	_check(runtime.active_count() == 0 and not tags.has_tag(&"Buff"),
			"Clear removes all owned state")
	_near(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 20.0, "Clear restores unmodified power")


func _test_clear_during_modifier_setup() -> void:
	var actor := _actor()
	var tags := GameplayTagSet.new()
	var runtime := _runtime(actor, tags)
	var notifications: Array[String] = []
	runtime.effect_applied.connect(func(_definition: GameplayEffectDefinition) -> void: notifications.append("applied"))
	runtime.effect_removed.connect(func(_definition: GameplayEffectDefinition) -> void: notifications.append("removed"))
	actor.attribute_changed.connect(func(id: int, _previous: float, value: float) -> void:
		if id == CombatAttributes.Id.MAGIC_POWER and value > 20.0:
			runtime.clear())
	_check(runtime.apply_effect(_buff(), _context(actor)) == 0,
			"Clear during modifier setup cancels the pending application")
	_check(runtime.active_count() == 0 and not tags.has_tag(&"Buff"), "Cancelled setup leaves no owned state")
	_near(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 20.0, "Pending modifier ownership is cleaned")
	_check(notifications.is_empty(), "An incomplete setup emits no completed lifecycle notifications")


func _test_clear_during_tag_setup() -> void:
	var actor := _actor()
	var tags := GameplayTagSet.new()
	var runtime := _runtime(actor, tags)
	tags.changed.connect(func(tag: StringName, present: bool) -> void:
		if tag == &"Buff.Empowered" and present:
			runtime.clear())
	_check(runtime.apply_effect(_buff(), _context(actor)) == 0,
			"Clear during a tag grant cancels the pending application")
	_check(runtime.active_count() == 0 and tags.get_count(&"Buff.Empowered") == 0,
			"Pending tag ownership is released exactly once")
	_near(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 20.0, "Tag-setup cancellation removes its modifier")


func _test_reentrant_lifecycle_order() -> void:
	var actor := _actor()
	var tags := GameplayTagSet.new()
	var runtime := _runtime(actor, tags)
	var events: Array[StringName] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void:
		events.append(StringName(event.type))
		if event.type == &"effect_applied":
			runtime.remove_effect(int(runtime.get_active_effects()[0].handle)))
	var handle := runtime.apply_effect(_buff(), _context(actor))
	_check(handle > 0 and runtime.active_count() == 0, "A completed effect may be removed by its observer")
	_check(events == [&"effect_applied", &"effect_removed"], "Reentrant removal preserves lifecycle event order")
	_check(not tags.has_tag(&"Buff"), "Reentrant removal cleans its grants")


func _test_reentrant_clear_notifications() -> void:
	var actor := _actor()
	var runtime := _runtime(actor, GameplayTagSet.new())
	var definition := _buff()
	var context := _context(actor)
	var retry: Array[int] = []
	runtime.effect_applied.connect(func(_definition: GameplayEffectDefinition) -> void:
		runtime.clear())
	runtime.effect_removed.connect(func(_definition: GameplayEffectDefinition) -> void:
		retry.append(runtime.apply_effect(definition, context)))
	runtime.apply_effect(definition, context)
	_check(retry == [0] and runtime.active_count() == 0,
			"Clear inside publication still rejects deferred removal-callback applications")


func _test_expiry_and_detached_inspection() -> void:
	var actor := _actor()
	var runtime := _runtime(actor)
	runtime.apply_effect(_buff(1.0), _context(actor))
	var inspection := runtime.get_active_effects()
	inspection[0].remaining = 0.0
	inspection[0].handle = -1
	runtime.advance(NAN)
	runtime.advance(INF)
	runtime.advance(-10.0)
	runtime.advance(0.5)
	_check(runtime.active_count() == 1, "Invalid time inputs and inspection edits cannot expire an effect")
	_near(runtime.get_active_effects()[0].remaining, 0.5, "Valid time advances the retained deadline")
	runtime.advance(0.5)
	_check(runtime.active_count() == 0, "The exact finite deadline expires an effect")


func _test_retained_effect_snapshots() -> void:
	var actor := _actor()
	var runtime := _runtime(actor)
	var context := _context(actor)
	var definition := _buff()
	var snapshots: Array[Dictionary] = []
	var collect := func() -> void: snapshots.append(runtime.get_retained_effects())
	runtime.retained_effects_changed.connect(collect)
	var instant := runtime.apply_effect(_damage(10.0), context)
	_check(instant > 0 and snapshots.is_empty() and not runtime.has_retained_effect(instant),
			"Instant effects never appear in retained status snapshots")
	var first := runtime.apply_effect(definition, context)
	var second := runtime.apply_effect(definition, context)
	_check(first > 0 and second > first and snapshots.size() == 2
			and snapshots[1].get(first) == definition and snapshots[1].get(second) == definition,
			"Retained instances of the same definition appear under independent handles")
	var detached := runtime.get_retained_effects()
	detached.clear()
	_check(runtime.has_retained_effect(first) and runtime.has_retained_effect(second),
			"Changing a status snapshot cannot remove runtime instances")
	runtime.remove_effect(first)
	_check(snapshots.size() == 3 and not snapshots[2].has(first) and snapshots[2].has(second),
			"Removal publishes the remaining independent instance")
	runtime.apply_effect(definition, context)
	runtime.clear()
	_check(snapshots.size() == 5 and snapshots[4].is_empty(),
			"Clearing multiple effects publishes one empty status snapshot")
	runtime.retained_effects_changed.disconnect(collect)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _near(actual: float, expected: float, message: String) -> void:
	_check(is_equal_approx(actual, expected), "%s: expected %.6f, got %.6f" % [message, expected, actual])
