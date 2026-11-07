extends SceneTree
## Single-player Gameplay Effect specs, timing, inhibition and execution output.

class Pulse extends GameplayEffectExecution:
	## Stamina added by one fixture tick before any per-spec override.
	@export var amount: float = 5.0
	## Optional gate consumed by this execution before its output is committed.
	@export var consume_tag: StringName = &""

	func execute(spec: GameplayEffectSpec, _target: ActorAttributes, tags: GameplayTagSet) -> Array[AttributeModifier]:
		if not consume_tag.is_empty():
			tags.remove_tag(consume_tag)
		var result := AttributeModifier.new()
		result.attribute = CombatAttributes.Id.STAMINA
		result.value = spec.get_set_by_caller_magnitude(&"Data.Test.Pulse", amount)
		return [result]


const STAMINA := CombatAttributes.Id.STAMINA
const MANA := CombatAttributes.Id.MANA
const POWER := CombatAttributes.Id.MAGIC_POWER

var _checks := 0
var _failures := 0
var _target: ActorAttributes
var _tags: GameplayTagSet
var _effects: GameplayEffectRuntime
var _context: GameplayEffectContext


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for test: Callable in [_test_instant_spec_outputs, _test_continuous_inhibition,
			_test_periodic_duration, _test_periodic_damage, _test_period_resets, _test_period_can_inhibit_itself,
			_test_aggregate_stack, _test_source_stacks_and_expiration, _test_stack_period_policy]:
		_target = ActorAttributes.new()
		_target.set_numeric_base_value(CombatAttributes.Id.MAX_HEALTH, 100.0)
		_target.set_numeric_base_value(CombatAttributes.Id.MAX_STAMINA, 100.0)
		_target.set_numeric_base_value(CombatAttributes.Id.MAX_MANA, 100.0)
		_target.restore_resources()
		_target.set_base_value(STAMINA, 20.0)
		_target.set_base_value(MANA, 30.0)
		_tags = GameplayTagSet.new()
		_effects = GameplayEffectRuntime.new(_target, _tags)
		_context = GameplayEffectContext.capture(_target, _tags)
		test.call()
		_effects.clear()
		_target.free()
	print("Gameplay Effect kernel checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_instant_spec_outputs() -> void:
	var definition := _definition()
	var cost := _modifier(STAMINA, -5.0)
	cost.set_by_caller_tag = &"Data.Test.StaminaCost"
	definition.modifiers = [cost, _modifier(MANA, -4.0)]
	var spec := _effects.make_effect_spec(definition, _context)
	spec.set_by_caller_magnitude(&"Data.Test.StaminaCost", -8.0)
	definition.modifiers[1].value = -999.0
	var changes: Array[float] = []
	_target.attribute_changed.connect(func(id: int, _previous: float, _current: float) -> void:
		if id == STAMINA:
			changes.append(_target.get_value(MANA)))
	var handle := _effects.apply_effect_spec(spec)
	_check(handle > 0 and not _effects.has_retained_effect(handle), "Instant output does not retain a handle")
	_near(_target.get_value(STAMINA), 12.0, "The outgoing spec supplies its caller magnitude")
	_near(_target.get_value(MANA), 26.0, "The outgoing spec captures the authored modifier")
	_check(changes == [26.0], "All pool outputs commit before the first resource change notification")


func _test_continuous_inhibition() -> void:
	var definition := _definition(GameplayEffectDefinition.Timing.INFINITE)
	definition.ongoing_blocked_target_tags = PackedStringArray(["State.Test.Paused"])
	definition.granted_tags = PackedStringArray(["State.Test.Powered"])
	definition.modifiers = [_modifier(POWER, 12.0)]
	var handle := _effects.apply_effect(definition, _context)
	_check(_effects.has_retained_effect(handle) and is_inf(_effects.get_remaining(handle)),
			"An infinite effect retains its handle indefinitely")
	_near(_target.get_value(POWER), 12.0, "The active effect owns its modifier")
	_tags.add_tag(&"State.Test.Paused.Child")
	_check(_effects.is_effect_inhibited(handle) and _effects.has_retained_effect(handle),
			"An ongoing block inhibits without removing the active instance")
	_check(not _tags.has_tag(&"State.Test.Powered"), "Inhibition releases the owned tag")
	_near(_target.get_value(POWER), 0.0, "Inhibition removes only this effect's modifier")
	_tags.remove_tag(&"State.Test.Paused.Child")
	_check(not _effects.is_effect_inhibited(handle) and _tags.has_tag(&"State.Test.Powered"),
			"Ending inhibition restores the owned tag under the same handle")
	_near(_target.get_value(POWER), 12.0, "Ending inhibition restores the modifier")


func _test_periodic_duration() -> void:
	var definition := _periodic()
	definition.timing = GameplayEffectDefinition.Timing.DURATION
	definition.duration = 0.5
	var spec := _effects.make_effect_spec(definition, _context)
	spec.set_by_caller_magnitude(&"Data.Test.Pulse", 3.0)
	var handle := _effects.apply_effect_spec(spec)
	spec.set_by_caller_magnitude(&"Data.Test.Pulse", 99.0)
	_near(_target.get_value(STAMINA), 20.0, "The period can wait for its first scheduled tick")
	_effects.advance(0.125)
	_near(_target.get_value(STAMINA), 20.0, "A partial period changes no attribute")
	_effects.advance(0.125)
	_near(_target.get_value(STAMINA), 23.0, "A periodic execution uses its retained spec copy")
	_effects.advance(0.25)
	_near(_target.get_value(STAMINA), 26.0, "The final due period executes before exact expiry")
	_check(not _effects.has_retained_effect(handle), "A duration expires at its deadline")


func _test_periodic_damage() -> void:
	var definition := _definition(GameplayEffectDefinition.Timing.DURATION)
	definition.duration = 0.5
	definition.period = 0.25
	definition.execute_periodic_on_application = false
	var execution := GameplayEffectDamageExecution.new()
	execution.amount = AmountDefinition.fixed(6.0)
	definition.executions = [execution]
	definition.granted_tags = PackedStringArray(["State.Test.PeriodicDamage"])
	var damage_context := definition.get_context_tags(PackedStringArray(["Ability.Spell", "Damage.Direct"]))
	_check(damage_context.has("Damage.Periodic") and not damage_context.has("Damage.Direct"),
			"The effect gives periodic damage its own canonical context")
	_target.set_base_value(CombatAttributes.Id.HEALTH, 10.0)
	var events: Array[Dictionary] = []
	_effects.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	var runtime := _effects
	_target.attribute_changed.connect(func(id: int, _previous: float, current: float) -> void:
		if id == CombatAttributes.Id.HEALTH and current <= 0.0:
			runtime.clear())
	var handle := _effects.apply_effect(definition, _context)
	_check(_effects.has_retained_effect(handle) and _tags.has_tag(&"State.Test.PeriodicDamage"),
			"Periodic damage can own status tags for its active lifetime")
	_near(_target.get_value(CombatAttributes.Id.HEALTH), 10.0, "Periodic damage waits for its first tick")
	_effects.advance(0.5)
	_near(_target.get_value(CombatAttributes.Id.HEALTH), 0.0, "Both due periodic calculations change Health")
	_check(events.size() == 5 and events[1].type == &"damage" and events[2].type == &"damage"
			and events[1].is_periodic and events[2].is_periodic and events[1].amount == 6.0
			and events[2].amount == 4.0 and events[3].type == &"effect_removed"
			and events[4].type == &"kill" and events[4].health_damage == 4.0,
			"Periodic damage reports actual loss, synchronous cleanup and one committed kill")
	_check(not _effects.has_retained_effect(handle) and not _tags.has_tag(&"State.Test.PeriodicDamage"),
			"The lethal period cleans up its active handle and tag")


func _test_period_resets() -> void:
	var definition := _periodic()
	definition.ongoing_required_target_tags = PackedStringArray(["State.Test.Gate"])
	var handle := _effects.apply_effect(definition, _context)
	_effects.advance(0.375)
	_tags.add_tag(&"State.Test.Gate")
	_near(_target.get_value(STAMINA), 20.0, "Keeping phase skips periods elapsed during inhibition")
	_effects.advance(0.125)
	_near(_target.get_value(STAMINA), 25.0, "Keeping phase runs at the original cadence")
	_effects.remove_effect(handle)
	_tags.remove_tag(&"State.Test.Gate")
	definition.period_inhibition_policy = GameplayEffectDefinition.PeriodInhibitionPolicy.RESET_PERIOD
	_effects.apply_effect(definition, _context)
	_effects.advance(0.125)
	_tags.add_tag(&"State.Test.Gate")
	_effects.advance(0.125)
	_near(_target.get_value(STAMINA), 25.0, "Reset waits one full period after inhibition ends")
	_effects.advance(0.125)
	_near(_target.get_value(STAMINA), 30.0, "The reset cadence executes after its new deadline")


func _test_period_can_inhibit_itself() -> void:
	var definition := _periodic()
	definition.ongoing_required_target_tags = PackedStringArray(["State.Test.Due"])
	definition.period_inhibition_policy = GameplayEffectDefinition.PeriodInhibitionPolicy.EXECUTE_AND_RESET_PERIOD
	(definition.executions[0] as Pulse).consume_tag = &"State.Test.Due"
	var handle := _effects.apply_effect(definition, _context)
	_tags.add_tag(&"State.Test.Due")
	_check(_effects.has_retained_effect(handle) and _effects.is_effect_inhibited(handle),
			"An execution can consume its gate and re-inhibit without removing its handle")
	_near(_target.get_value(STAMINA), 25.0, "Re-inhibiting during execution preserves that tick's output")
	_effects.advance(1.0)
	_near(_target.get_value(STAMINA), 25.0, "An inhibited effect has no further periodic output")
	_tags.add_tag(&"State.Test.Due")
	_near(_target.get_value(STAMINA), 30.0, "The same handle executes on the next gate")


func _test_aggregate_stack() -> void:
	var definition := _definition(GameplayEffectDefinition.Timing.DURATION)
	definition.duration = 1.0
	definition.stacking_type = GameplayEffectDefinition.StackingType.AGGREGATE_BY_TARGET
	definition.stack_limit_count = 2
	definition.deny_overflow_application = true
	definition.granted_tags = PackedStringArray(["State.Test.Stacked"])
	var flat := _modifier(POWER, 10.0)
	flat.set_by_caller_tag = &"Data.Test.Power"
	var more := _modifier(POWER, 20.0)
	more.operation = AttributeModifier.Operation.MORE_PERCENT
	definition.modifiers = [flat, more]
	_target.set_numeric_base_value(POWER, 10.0)
	var stack := _effects.apply_effect(definition, _context)
	_effects.advance(0.5)
	var reapplication := _effects.make_effect_spec(definition, _context)
	reapplication.set_by_caller_magnitude(&"Data.Test.Power", 12.0)
	_check(_effects.apply_effect_spec(reapplication) == stack and _effects.get_stack_count(stack) == 2,
			"Target aggregation keeps one handle and records two stacks")
	_near(_effects.get_remaining(stack), 1.0, "An accepted reapplication refreshes the stack duration")
	_near(_target.get_value(POWER), 48.96, "The newest magnitude scales Add and compounds More by stack count")
	_check(_tags.get_count(&"State.Test.Stacked") == 1, "A stack owns its granted tag once")
	_effects.advance(0.25)
	_check(_effects.apply_effect(definition, _context) == 0, "Deny Overflow rejects an application above the cap")
	_near(_effects.get_remaining(stack), 0.75, "An overflow denial does not refresh duration")
	_check(_effects.remove_effect(stack, 1) and _effects.get_stack_count(stack) == 1,
			"Removing part of a stack leaves the same handle active")
	_near(_target.get_value(POWER), 26.4, "Removing a stack updates only its magnitude")
	_check(_tags.get_count(&"State.Test.Stacked") == 1, "Partial stack removal keeps the granted tag")


func _test_source_stacks_and_expiration() -> void:
	var definition := _definition(GameplayEffectDefinition.Timing.DURATION)
	definition.duration = 1.0
	definition.stacking_type = GameplayEffectDefinition.StackingType.AGGREGATE_BY_SOURCE
	definition.stack_duration_policy = GameplayEffectDefinition.StackDurationPolicy.NEVER_REFRESH
	definition.stack_expiration_policy = GameplayEffectDefinition.StackExpirationPolicy.REMOVE_ONE_AND_REFRESH
	var first := _effects.apply_effect(definition, _context)
	_effects.advance(0.5)
	var other_source := ActorAttributes.new()
	var other_context := GameplayEffectContext.capture(other_source, null)
	var other := _effects.apply_effect(definition, other_context)
	_check(first != other and _effects.apply_effect(definition, _context) == first,
			"Source aggregation shares a handle only for repeated applications from one actor")
	_near(_effects.get_remaining(first), 0.5, "Never Refresh preserves the first expiration")
	_effects.advance(0.5)
	_check(_effects.get_stack_count(first) == 1 and _effects.get_stack_count(other) == 1,
			"Expiration can remove only one stack from the due handle")
	_near(_effects.get_remaining(first), 1.0, "Remove One refreshes duration for the remaining stack")
	_effects.advance(1.0)
	_check(_effects.active_count() == 0, "The last stack expires normally")
	other_source.free()


func _test_stack_period_policy() -> void:
	var definition := _periodic()
	definition.stacking_type = GameplayEffectDefinition.StackingType.AGGREGATE_BY_TARGET
	definition.stack_period_policy = GameplayEffectDefinition.StackPeriodPolicy.NEVER_RESET
	var handle := _effects.apply_effect(definition, _context)
	_effects.advance(0.125)
	_effects.apply_effect(definition, _context)
	_effects.advance(0.125)
	_near(_target.get_value(STAMINA), 30.0, "Preserved period executes on its original deadline for both stacks")
	_effects.remove_effect(handle)
	definition.stack_period_policy = GameplayEffectDefinition.StackPeriodPolicy.RESET
	_effects.apply_effect(definition, _context)
	_effects.advance(0.125)
	_effects.apply_effect(definition, _context)
	_effects.advance(0.125)
	_near(_target.get_value(STAMINA), 30.0, "Reset period skips the deadline that existed before reapplication")
	_effects.advance(0.125)
	_near(_target.get_value(STAMINA), 40.0, "Reset period executes both stacks one full period after reapplication")


func _periodic() -> GameplayEffectDefinition:
	var definition := _definition(GameplayEffectDefinition.Timing.INFINITE)
	definition.period = 0.25
	definition.execute_periodic_on_application = false
	definition.executions = [Pulse.new()]
	return definition


func _definition(timing: GameplayEffectDefinition.Timing = GameplayEffectDefinition.Timing.INSTANT) -> GameplayEffectDefinition:
	var definition := GameplayEffectDefinition.new()
	definition.timing = timing
	return definition


func _modifier(attribute: CombatAttributes.Id, value: float) -> AttributeModifier:
	var result := AttributeModifier.new()
	result.attribute = attribute
	result.value = value
	return result


func _near(value: float, expected: float, label: String) -> void:
	_check(is_equal_approx(value, expected), "%s: %f expected %f" % [label, value, expected])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
