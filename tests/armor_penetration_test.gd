extends SceneTree
## Source percentage penetration uses full target Armor before the Physical mitigation curve.

const ATTRIBUTE_FIXTURE = preload("res://tests/attribute_fixture.gd")

var _checks: int = 0
var _failures: int = 0
var _actors: Array[ActorAttributes] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_effective_armor_inputs()
	_test_independent_rating_and_percentage_grid()
	_test_modifier_order_scopes_and_overcap()
	_test_source_target_roles_and_per_hit_state()
	_test_detached_source_scope()
	_test_damage_types_and_levels()
	_test_hybrid_payload_and_status()
	_test_damage_telemetry()
	for actor in _actors:
		actor.free()
	print("Armor penetration checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _actor() -> ActorAttributes:
	var actor := ATTRIBUTE_FIXTURE.new_attributes()
	actor.set_base_value(CombatAttributes.Id.MAX_HEALTH, 10000.0)
	actor.restore_resources()
	_actors.append(actor)
	return actor


func _context(source: ActorAttributes, spell: bool = false) -> GameplayEffectContext:
	return GameplayEffectContext.capture(source, GameplayTagSet.new(),
			PackedStringArray(["Ability.Spell"]) if spell else PackedStringArray(["Ability.Attack", "Weapon.Finesse"]))


func _physical(amount: float = 100.0) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.executions = [GameplayEffectDamageExecution.new()]
	effect.effect_id = &"Effect.PenetrationPhysicalTest"
	effect.base_magnitude = amount
	return effect


func _magic(amount: float = 100.0) -> GameplayEffectDefinition:
	var effect := _physical(amount)
	effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	return effect


func _modifier(amount: float,
		operation: AttributeModifier.Operation = AttributeModifier.Operation.ADD) -> AttributeModifier:
	var modifier := AttributeModifier.new()
	modifier.attribute = CombatAttributes.Id.ARMOR_PENETRATION
	modifier.value = amount
	modifier.operation = operation
	return modifier


func _buff() -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.kind = GameplayEffectDefinition.Kind.MODIFIERS
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.duration = 2.0
	var modifier := _modifier(10.0)
	modifier.attribute = CombatAttributes.Id.STRENGTH
	effect.modifiers = [modifier]
	effect.granted_tags = PackedStringArray(["Buff.PenetrationTest"])
	return effect


func _test_effective_armor_inputs() -> void:
	var percentages: Array[float] = [-50.0, 0.0, 25.0, 50.0, 75.0, 100.0, 150.0]
	var expected: Array[float] = [1000.0, 1000.0, 750.0, 500.0, 250.0, 0.0, 0.0]
	for index in percentages.size():
		_near(CombatMath.get_effective_armor(1000.0, percentages[index]), expected[index],
				"Percentage penetration clamps to zero through one hundred before reducing Armor")
	for armor: float in [-100.0, 0.0, NAN, INF, -INF]:
		_near(CombatMath.get_effective_armor(armor, 50.0), 0.0,
				"Invalid or nonpositive target Armor safely produces no effective Armor")
	for invalid: float in [NAN, INF, -INF]:
		_near(CombatMath.get_effective_armor(1000.0, invalid), 1000.0,
				"Invalid penetration cannot grant offensive bypass")
	_near(CombatMath.get_effective_armor(1e300, 100.0), 0.0,
			"One hundred percent penetration ignores every finite target Armor rating")
	_near(CombatMath.get_effective_armor(1e300, 50.0), 5e299,
			"Very large finite Armor remains finite when partially penetrated")
	_near(CombatMath.get_effective_armor(2000.0, 50.0), 1000.0,
			"Penetration uses the full overcap Armor rather than first clipping it to one thousand")
	_near(CombatMath.get_armor_reduction(CombatMath.get_effective_armor(2000.0, 50.0)), 0.75,
			"Two thousand Armor with fifty percent penetration still reaches the mitigation cap")


func _test_independent_rating_and_percentage_grid() -> void:
	var source := _actor()
	var target := _actor()
	var effect := _physical()
	var context := _context(source)
	for armor: float in [0.0, 100.0, 500.0, 1000.0, 2000.0, 1e12]:
		target.set_base_value(CombatAttributes.Id.ARMOR, armor)
		for requested: float in [-50.0, 0.0, 25.0, 50.0, 75.0, 100.0, 200.0]:
			source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, requested)
			var applied := clampf(requested, 0.0, 100.0)
			var effective := armor * (1.0 - applied / 100.0)
			var expected_reduction := minf(0.75, 3.0 * effective / (3.0 * effective + 1000.0))
			var result := CombatMath.resolve_effect_result(effect, context, target)
			_near(result.raw_magnitude, 100.0, "Penetration never increases the raw source magnitude")
			_near(result.armor, armor, "Telemetry preserves the full modified target Armor")
			_near(result.effective_armor, effective, "Effective Armor reflects the source percentage before the curve")
			_near(result.armor_penetration_percent, applied, "Applied penetration is a capped percentage rather than a rating conversion")
			_near(result.armor_reduction, expected_reduction, "Post-penetration reduction matches the independent Armor equation")
			_near(result.magnitude, 100.0 * (1.0 - expected_reduction), "Physical damage uses only post-penetration mitigation")
			_near(target.get_value(CombatAttributes.Id.ARMOR), armor, "Per-hit penetration never changes the target's Armor attribute")
	target.set_base_value(CombatAttributes.Id.ARMOR, 1000.0)
	source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 50.0)
	_near(CombatMath.resolve_effect(effect, context, target), 40.0,
			"Fifty percent penetration removes half the rating rather than subtracting from seventy-five-percent reduction")


func _test_modifier_order_scopes_and_overcap() -> void:
	var source := _actor()
	var target := _actor()
	var effect := _physical()
	target.set_base_value(CombatAttributes.Id.ARMOR, 1000.0)
	source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 10.0)
	source.set_modifiers(&"gear", [
		_modifier(10.0),
		_modifier(20.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(30.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(20.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	var result := CombatMath.resolve_effect_result(effect, _context(source), target)
	_near(result.armor_penetration_percent, 36.0, "Source penetration uses flat, combined increased and independent More modifiers")
	_near(result.effective_armor, 640.0, "The fully modified source percentage is applied to target Armor")
	_near(result.magnitude, 100000.0 / 2920.0, "Modified penetration resolves the normal Armor curve without another damage bonus")
	source.remove_modifiers(&"gear")
	source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 0.0)
	source.set_modifiers(&"overcap", [_modifier(150.0)])
	_near(source.get_value(CombatAttributes.Id.ARMOR_PENETRATION), 100.0, "The effective source percentage has a hard cap")
	source.set_modifiers(&"debuff", [_modifier(-60.0)])
	result = CombatMath.resolve_effect_result(effect, _context(source), target)
	_near(result.armor_penetration_percent, 90.0, "Overcap contributions are retained before a signed debuff is applied")
	_near(result.effective_armor, 100.0, "The debuffed final percentage is capped after the full modifier calculation")
	source.remove_modifiers(&"debuff")
	_near(source.get_value(CombatAttributes.Id.ARMOR_PENETRATION), 100.0, "Removing the debuff restores the capped source percentage")
	source.remove_modifiers(&"overcap")
	var scoped := _modifier(50.0)
	scoped.required_context_tags = PackedStringArray(["Damage.Physical", "Ability.Spell"])
	source.set_modifiers(&"physical_spell", [scoped])
	_near(CombatMath.resolve_effect(effect, _context(source, true), target), 40.0,
			"Physical Spells use penetration from their canonical component and action scope")
	_near(CombatMath.resolve_effect(effect, _context(source), target), 25.0,
			"Spell-scoped penetration does not leak into a Physical Attack")
	source.remove_modifiers(&"physical_spell")
	var fire_scoped := _modifier(100.0)
	fire_scoped.required_context_tags = PackedStringArray(["Damage.Fire"])
	source.set_modifiers(&"fire_scope", [fire_scoped])
	var misleading_context := _context(source)
	misleading_context.ability_tags.append("Damage.Fire")
	_near(CombatMath.resolve_effect(effect, misleading_context, target), 25.0,
			"An action-level school tag cannot relabel a Physical component to obtain a mismatched penetration scope")
	source.remove_modifiers(&"fire_scope")
	target.set_base_value(CombatAttributes.Id.ARMOR, 500.0)
	var armor_flat := _modifier(500.0)
	armor_flat.attribute = CombatAttributes.Id.ARMOR
	var armor_increased := _modifier(100.0, AttributeModifier.Operation.ADD_PERCENT)
	armor_increased.attribute = CombatAttributes.Id.ARMOR
	var armor_more := _modifier(20.0, AttributeModifier.Operation.MORE_PERCENT)
	armor_more.attribute = CombatAttributes.Id.ARMOR
	target.set_modifiers(&"armor_gear", [armor_flat, armor_increased, armor_more])
	source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 50.0)
	result = CombatMath.resolve_effect_result(effect, _context(source), target)
	_near(result.armor, 2400.0, "The full target flat/increased/More Armor pipeline is evaluated before penetration")
	_near(result.effective_armor, 1200.0, "Penetration follows all target Armor modifiers without a premature rating cap")
	_near(result.magnitude, 25.0, "A sufficiently invested target can remain capped after partial penetration")
	var armor_debuff := _modifier(-500.0)
	armor_debuff.attribute = CombatAttributes.Id.ARMOR
	target.set_modifiers(&"armor_debuff", [armor_debuff])
	result = CombatMath.resolve_effect_result(effect, _context(source), target)
	_near(result.armor, 1200.0, "An owned target debuff affects the full modifier pipeline before penetration")
	_near(result.effective_armor, 600.0, "The next hit uses the changed target rating and the same source percentage")
	_near(result.magnitude, 100000.0 / 2800.0, "Target debuffs and source penetration compose through rating before the curve")
	target.remove_modifiers(&"armor_debuff")
	target.remove_modifiers(&"armor_gear")


func _test_source_target_roles_and_per_hit_state() -> void:
	var source := _actor()
	var target := _actor()
	source.set_base_value(CombatAttributes.Id.ARMOR, 1000.0)
	target.set_base_value(CombatAttributes.Id.ARMOR, 1000.0)
	target.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 100.0)
	var effect := _physical()
	var forward := _context(source)
	_near(CombatMath.resolve_effect(effect, forward, target), 25.0,
			"The defender's penetration does not reduce its own Armor or grant the attacker bypass")
	source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 50.0)
	target.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 0.0)
	_near(CombatMath.resolve_effect(effect, forward, target), 40.0, "The source actor's penetration is used")
	_near(CombatMath.resolve_effect(effect, _context(target), source), 25.0,
			"Reversing attacker and defender queries the new attacker's percentage")
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var before := target.get_value(CombatAttributes.Id.HEALTH)
	runtime.apply_hit_payload([effect], forward, 0.0)
	_near(before - target.get_value(CombatAttributes.Id.HEALTH), 40.0, "A delivered hit applies the attacker's current penetration")
	_near(target.get_value(CombatAttributes.Id.ARMOR), 1000.0, "The delivered hit does not leave a target Armor debuff")
	_near(source.get_value(CombatAttributes.Id.ARMOR_PENETRATION), 50.0, "Delivery does not consume or modify source penetration")
	source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 0.0)
	before = target.get_value(CombatAttributes.Id.HEALTH)
	runtime.apply_hit_payload([effect], forward, 0.0)
	_near(before - target.get_value(CombatAttributes.Id.HEALTH), 25.0,
			"A later unpenetrated hit sees the target's original Armor")
	_near(target.get_value(CombatAttributes.Id.ARMOR), 1000.0, "Independent hits preserve target equipment values")


func _test_detached_source_scope() -> void:
	var source := _actor()
	source.level = 20
	var target := _actor()
	target.level = 30
	target.set_base_value(CombatAttributes.Id.ARMOR, 1000.0)
	var scoped := _modifier(50.0)
	scoped.required_context_tags = PackedStringArray(["Damage.Physical", "Weapon.Finesse"])
	source.set_modifiers(&"penetration", [scoped])
	var effect := _physical()
	var context := _context(source)
	context.prime_effects([effect])
	context = context.duplicate_for_hit(0.25)
	_actors.erase(source)
	source.free()
	var result := CombatMath.resolve_effect_result(effect, context, target)
	_near(result.armor_penetration_percent, 50.0, "Detached sources retain primed component-scoped penetration")
	_near(result.effective_armor, 500.0, "The source fallback is applied to current target Armor")
	_near(result.magnitude, 40.0, "Detached Physical delivery preserves its expected post-penetration damage")
	target.set_base_value(CombatAttributes.Id.ARMOR, 2000.0)
	result = CombatMath.resolve_effect_result(effect, context, target)
	_near(result.armor, 2000.0, "A detached source does not freeze the target's Armor at launch")
	_near(result.effective_armor, 1000.0, "Current full target Armor is reduced before the curve")
	_near(result.magnitude, 25.0, "The changed target can still reach its cap after partial penetration")
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var hit := runtime.apply_hit_payload([effect], context, 0.0)
	_check(hit.outcome == &"hit", "Detached penetrated payloads still use the ordinary shared Accuracy path")


func _test_damage_types_and_levels() -> void:
	var source := _actor()
	var target := _actor()
	source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 100.0)
	target.set_base_value(CombatAttributes.Id.ARMOR, 1000.0)
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 80.0)
	for spell in [false, true]:
		var physical := CombatMath.resolve_effect_result(_physical(), _context(source, spell), target)
		_near(physical.magnitude, 100.0, "Every Physical component, including a Spell, uses source penetration")
		_near(physical.armor_reduction, 0.0, "One hundred percent penetration leaves no Armor mitigation")
		var magic := CombatMath.resolve_effect_result(_magic(), _context(source, spell), target)
		_near(magic.magnitude, 20.0, "Magic damage keeps matching Resistance regardless of penetration")
		_near(magic.armor_penetration_percent, 0.0, "Magic components do not apply or report penetration")
		_near(magic.effective_armor, 0.0, "Magic components retain neutral effective-Armor telemetry")
	var modifier_result := CombatMath.resolve_effect_result(_buff(), _context(source), target)
	_near(modifier_result.armor_penetration_percent, 0.0, "Modifier-only effects do not query source penetration")
	source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 50.0)
	for source_level in [1, 30, 60]:
		source.level = source_level
		for target_level in [1, 30, 60]:
			target.level = target_level
			_near(CombatMath.resolve_effect(_physical(), _context(source), target), 40.0,
					"Penetration applies no additional level or boss constant")


func _test_hybrid_payload_and_status() -> void:
	var source := _actor()
	var target := _actor()
	source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 50.0)
	target.set_base_value(CombatAttributes.Id.ARMOR, 1000.0)
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 50.0)
	var tags := GameplayTagSet.new()
	var runtime := GameplayEffectRuntime.new(target, tags)
	var events: Array[Dictionary] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	var context := _context(source)
	var payload: Array[GameplayEffectDefinition] = [_physical(), _magic(), _buff()]
	var failed := runtime.apply_hit_payload(payload, context, 0.8)
	_check(failed.outcome == &"miss" and failed.applied_effects == 0,
			"Penetration cannot bypass a failed shared Accuracy check")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 10000.0, "Failed penetrated hits apply zero Physical and Magic damage")
	_check(events.is_empty() and runtime.active_count() == 0, "A failed penetrated hit applies no attached effect")
	var hit := runtime.apply_hit_payload(payload, context, 0.79)
	_check(hit.outcome == &"hit" and hit.applied_effects == 3, "One successful Accuracy check authorizes all hybrid components")
	_near(hit.hit_chance, 0.8, "Penetration does not alter Accuracy probability")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 9910.0, "Physical forty and Magic fifty use their independent defense paths")
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "Penetration does not change attached modifier potency")
	_near(target.get_value(CombatAttributes.Id.ARMOR), 1000.0, "A hybrid hit also leaves target Armor unchanged")
	var damage_events := 0
	for event in events:
		if event.type == &"damage":
			damage_events += 1
		_check(event.type != &"hit_outcome", "Penetration adds no component-specific Accuracy roll or outcome event")
	_check(damage_events == 2, "A hybrid hit reports its two damage components exactly once")
	runtime.advance(1.99)
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "Penetration does not shorten attached effect duration")
	runtime.advance(0.01)
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 10.0, "Attached effects retain their authored expiry")
	runtime.clear()


func _test_damage_telemetry() -> void:
	var source := _actor()
	var target := _actor()
	source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 50.0)
	target.set_base_value(CombatAttributes.Id.ARMOR, 1000.0)
	target.set_base_value(CombatAttributes.Id.HEALTH, 30.0)
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var events: Array[Dictionary] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	var result := runtime.apply_hit_payload([_physical()], _context(source), 0.0)
	_check(result.outcome == &"hit", "A penetrated overkill remains an ordinary successful hit")
	var damages: Array[Dictionary] = []
	for event in events:
		if event.type == &"damage":
			damages.append(event)
	_check(damages.size() == 1, "One penetrated Physical component emits one damage event")
	if damages.is_empty():
		return
	var event: Dictionary = damages[0]
	_near(event.raw_magnitude, 100.0, "Telemetry retains raw source magnitude")
	_near(event.armor, 1000.0, "Telemetry retains full target Armor")
	_near(event.effective_armor, 500.0, "Telemetry separates the effective Armor used by the curve")
	_near(event.armor_penetration_percent, 50.0, "Telemetry records the source percentage")
	_near(event.armor_reduction, 0.6, "Telemetry reports mitigation after penetration")
	_near(event.resolved_amount, 40.0, "Resolved damage applies penetration before mitigation")
	_near(event.amount, 30.0, "Displayed damage remains actual Health loss after overkill")
	_near(event.resistance_percent, 0.0, "Physical damage keeps neutral school Resistance")
	target.restore_resources()
	var before := target.get_value(CombatAttributes.Id.HEALTH)
	runtime.apply_hit_payload([_physical(0.001)], _context(source), 0.0)
	_near(before - target.get_value(CombatAttributes.Id.HEALTH), 0.0004, "Fractional penetrated damage is preserved internally")


func _near(actual: float, expected: float, label: String) -> void:
	_check(is_finite(actual) and absf(actual - expected) <= 1e-8 * maxf(1.0, absf(expected)),
			"%s: expected %.12f, got %.12f" % [label, expected, actual])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
