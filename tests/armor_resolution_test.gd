extends SceneTree
## Armor rating curve, Physical-only mitigation and shared payload/telemetry contracts.

const ATTRIBUTE_FIXTURE = preload("res://tests/attribute_fixture.gd")

var _checks: int = 0
var _failures: int = 0
var _actors: Array[ActorAttributes] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_independent_curve_anchors()
	_test_curve_domain_and_diminishing_returns()
	_test_modifier_order_scopes_and_overcap()
	_test_levels_and_hit_sizes()
	_test_damage_type_and_delivery()
	_test_hybrid_payload_and_attached_effects()
	_test_actual_damage_telemetry_and_fractionals()
	for actor in _actors:
		actor.free()
	print("Armor resolution checks: %d passed, %d failed." % [_checks - _failures, _failures])
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
	effect.effect_id = &"Effect.ArmorPhysicalTest"
	effect.base_magnitude = amount
	return effect


func _magic(school: int, amount: float = 100.0) -> GameplayEffectDefinition:
	var effect := _physical(amount)
	effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	effect.magic_school = school
	return effect


func _modifier(attribute: int, amount: float,
		operation: AttributeModifier.Operation = AttributeModifier.Operation.ADD) -> AttributeModifier:
	var modifier := AttributeModifier.new()
	modifier.attribute = attribute
	modifier.value = amount
	modifier.operation = operation
	return modifier


func _buff() -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.kind = GameplayEffectDefinition.Kind.MODIFIERS
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.duration = 2.0
	effect.modifiers = [_modifier(CombatAttributes.Id.STRENGTH, 10.0)]
	effect.granted_tags = PackedStringArray(["Buff.ArmorTest"])
	return effect


func _test_independent_curve_anchors() -> void:
	var ratings: Array[float] = [0.0, 100.0, 250.0, 500.0, 750.0, 1000.0, 1250.0, 1000000.0, 1e300]
	var expected: Array[float] = [0.0, 3.0 / 13.0, 3.0 / 7.0, 0.6, 9.0 / 13.0, 0.75, 0.75, 0.75, 0.75]
	for index in ratings.size():
		_near(CombatMath.get_armor_reduction(ratings[index]), expected[index],
				"Armor matches the independently derived rating anchors and seventy-five-percent cap")
	for invalid: float in [-1.0, -1000000.0, NAN, INF, -INF]:
		_near(CombatMath.get_armor_reduction(invalid), 0.0, "Invalid or nonpositive Armor cannot grant protection")
	var target := _actor()
	_near(target.get_value(CombatAttributes.Id.ARMOR), 0.0, "Armor starts at zero without an authored contribution")
	target.set_base_value(CombatAttributes.Id.ARMOR, 1500.0)
	_near(target.get_value(CombatAttributes.Id.ARMOR), 1500.0, "The Armor rating itself is not capped at one thousand")
	target.set_base_value(CombatAttributes.Id.ARMOR, -100.0)
	_near(target.get_value(CombatAttributes.Id.ARMOR), 0.0, "Armor rating has a zero minimum")


func _test_curve_domain_and_diminishing_returns() -> void:
	var bounded := true
	var monotonic := true
	var previous := 0.0
	for rating in 2001:
		var reduction := CombatMath.get_armor_reduction(float(rating))
		bounded = bounded and is_finite(reduction) and reduction >= 0.0 and reduction <= 0.75
		monotonic = monotonic and reduction >= previous
		previous = reduction
	_check(bounded, "The integer rating domain stays finite between zero and seventy-five percent")
	_check(monotonic, "Additional Armor never increases Physical damage taken")
	var previous_gain := 1.0
	var diminishing := true
	for step in range(1, 11):
		var lower := CombatMath.get_armor_reduction(float((step - 1) * 100))
		var upper := CombatMath.get_armor_reduction(float(step * 100))
		var gain := upper - lower
		diminishing = diminishing and gain > 0.0 and gain < previous_gain
		previous_gain = gain
	_check(diminishing, "Equal rating increments grant diminishing percentage-point mitigation below the cap")
	_near(CombatMath.get_armor_reduction(999.0), 2997.0 / 3997.0, "The last precap point follows the curve without an early clamp")
	_near(CombatMath.get_armor_reduction(1000.0), 0.75, "The configured threshold reaches the mitigation cap exactly")
	_near(CombatMath.get_armor_reduction(1001.0), 0.75, "Rating above the threshold does not create invulnerability")


func _test_modifier_order_scopes_and_overcap() -> void:
	var source := _actor()
	var target := _actor()
	var context := _context(source)
	var physical := _physical()
	target.set_base_value(CombatAttributes.Id.ARMOR, 100.0)
	target.set_modifiers(&"armor_gear", [
		_modifier(CombatAttributes.Id.ARMOR, 100.0),
		_modifier(CombatAttributes.Id.ARMOR, 20.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(CombatAttributes.Id.ARMOR, 30.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(CombatAttributes.Id.ARMOR, 20.0, AttributeModifier.Operation.MORE_PERCENT),
		_modifier(CombatAttributes.Id.ARMOR, 10.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	_near(target.get_value(CombatAttributes.Id.ARMOR), 396.0, "Flat, combined increased and independent More apply to the rating before the curve")
	_near(CombatMath.resolve_effect(physical, context, target), 100.0 * 1000.0 / 2188.0,
			"Damage mitigation uses the final modified rating rather than modifying an already converted percentage")
	target.remove_modifiers(&"armor_gear")
	_near(target.get_value(CombatAttributes.Id.ARMOR), 100.0, "Removing a modifier owner restores only its own rating contributions")
	target.set_base_value(CombatAttributes.Id.ARMOR, 0.0)
	target.set_modifiers(&"overcap_gear", [_modifier(CombatAttributes.Id.ARMOR, 1500.0)])
	_near(target.get_value(CombatAttributes.Id.ARMOR), 1500.0, "Overcap Armor remains in the attribute foundation")
	_near(CombatMath.resolve_effect(physical, context, target), 25.0, "Overcap rating still provides only seventy-five-percent reduction")
	target.set_modifiers(&"debuff", [_modifier(CombatAttributes.Id.ARMOR, -750.0)])
	_near(target.get_value(CombatAttributes.Id.ARMOR), 750.0, "An Armor debuff reduces retained overcap rating before mitigation")
	_near(CombatMath.resolve_effect(physical, context, target), 100.0 * 4.0 / 13.0,
			"Debuffed overcap Armor resolves the curve from seven hundred fifty rather than two hundred fifty")
	target.remove_modifiers(&"debuff")
	_near(target.get_value(CombatAttributes.Id.ARMOR), 1500.0, "Removing a debuff restores the retained gear rating")
	target.remove_modifiers(&"overcap_gear")
	var scoped := _modifier(CombatAttributes.Id.ARMOR, 500.0)
	scoped.required_context_tags = PackedStringArray(["Damage.Physical", "Ability.Spell"])
	target.set_modifiers(&"spell_armor", [scoped])
	_near(CombatMath.resolve_effect(physical, _context(source, true), target), 40.0,
			"Target Armor evaluates the component's canonical Physical and Spell scopes")
	_near(CombatMath.resolve_effect(physical, context, target), 100.0,
			"A spell-scoped Armor bonus does not leak into a Physical Attack")
	var magic := _magic(GameplayEffectDefinition.MagicSchool.FIRE)
	_near(CombatMath.resolve_effect(magic, _context(source, true), target), 100.0,
			"Magic damage does not consume a Physical Armor scope")
	target.remove_modifiers(&"spell_armor")


func _test_levels_and_hit_sizes() -> void:
	var source := _actor()
	var target := _actor()
	target.set_base_value(CombatAttributes.Id.ARMOR, 500.0)
	for source_level in [1, 30, 60]:
		source.level = source_level
		for target_level in [1, 30, 60]:
			target.level = target_level
			for amount: float in [0.001, 1.0, 100.0, 1000000.0]:
				var result := CombatMath.resolve_effect_result(_physical(amount), _context(source), target)
				_near(result.raw_magnitude, amount, "Armor leaves source magnitude independent of levels")
				_near(result.armor_reduction, 0.6, "Armor reduction does not vary with level or hit size")
				_near(result.magnitude, amount * 0.4, "Small and large hits receive the same Physical mitigation fraction")


func _test_damage_type_and_delivery() -> void:
	var source := _actor()
	var target := _actor()
	target.set_base_value(CombatAttributes.Id.ARMOR, 1000.0)
	for id in CombatAttributes.resistance_ids():
		target.set_base_value(id, 80.0)
	for spell in [false, true]:
		var context := _context(source, spell)
		var physical := CombatMath.resolve_effect_result(_physical(), context, target)
		_near(physical.magnitude, 25.0, "Both Physical Attacks and Physical Spells receive Armor mitigation")
		_near(physical.resistance_percent, 0.0, "Physical components ignore every school Resistance")
		_near(physical.resistance_multiplier, 1.0, "Physical Resistance metadata remains neutral")
		_check(physical.resistance_attribute == CombatAttributes.Id.NONE and physical.magic_school == -1,
				"Physical components do not acquire a Magic school or school-defense identity")
		for school in 5:
			var magic := CombatMath.resolve_effect_result(_magic(school), context, target)
			_near(magic.magnitude, 20.0, "Magic Attacks and Spells receive matching Resistance without Armor multiplying it again")
			_near(magic.armor, 0.0, "Magic component Armor telemetry stays neutral")
			_near(magic.armor_reduction, 0.0, "Magic components receive no Armor reduction")
			_near(magic.resistance_percent, 80.0, "Magic retains its existing matching school mitigation")
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, -100.0)
	_near(CombatMath.resolve_effect(_magic(GameplayEffectDefinition.MagicSchool.FIRE), _context(source), target), 200.0,
			"Armor does not reduce a Magic school vulnerability")


func _test_hybrid_payload_and_attached_effects() -> void:
	var source := _actor()
	var target := _actor()
	target.set_base_value(CombatAttributes.Id.ARMOR, 500.0)
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 50.0)
	target.set_base_value(CombatAttributes.Id.COLD_RESISTANCE, -100.0)
	var tags := GameplayTagSet.new()
	var runtime := GameplayEffectRuntime.new(target, tags)
	var events: Array[Dictionary] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	var payload: Array[GameplayEffectDefinition] = [
		_physical(20.0), _magic(GameplayEffectDefinition.MagicSchool.FIRE, 100.0),
		_magic(GameplayEffectDefinition.MagicSchool.COLD, 40.0), _buff(),
	]
	var context := _context(source, true)
	var failed := runtime.apply_hit_payload(payload, context, 0.8)
	_check(failed.outcome == &"resist" and failed.applied_effects == 0,
			"One failed shared Accuracy check rejects Physical and Magic components before mitigation")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 10000.0, "Failed mixed hits still apply zero damage")
	_check(events.is_empty() and runtime.active_count() == 0, "Armor does not allow attached effects to escape an Accuracy failure")
	var hit := runtime.apply_hit_payload(payload, context, 0.79)
	_check(hit.outcome == &"hit" and hit.applied_effects == 4, "One successful Accuracy result authorizes the complete mixed payload")
	_near(hit.hit_chance, 0.8, "Armor does not alter the chance to connect")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 9862.0, "Physical8 plus Fire50 plus Cold80 resolves the corresponding defense exactly once")
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "Attached modifier magnitude is not reduced by Armor")
	var damage_count := 0
	for event in events:
		if event.type == &"damage":
			damage_count += 1
		_check(event.type != &"hit_outcome", "Per-component Armor mitigation introduces no additional Accuracy event")
	_check(damage_count == 3, "A mixed payload emits exactly its three damage component events")
	runtime.advance(1.99)
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "Armor does not shorten an attached effect's duration")
	runtime.advance(0.01)
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 10.0, "Attached modifiers expire after their full authored lifetime")
	var buff := _buff()
	var modifier_result := CombatMath.resolve_effect_result(buff, context, target)
	_near(modifier_result.armor_reduction, 0.0, "Modifier-only payloads do not query Armor")
	_check(runtime.apply_effect(buff, context) > 0, "Direct explicit buffs remain independent of Armor")
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "Direct modifier potency is unaffected by mitigation")
	runtime.clear()


func _test_actual_damage_telemetry_and_fractionals() -> void:
	var source := _actor()
	var target := _actor()
	target.set_base_value(CombatAttributes.Id.ARMOR, 500.0)
	target.set_base_value(CombatAttributes.Id.HEALTH, 30.0)
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var events: Array[Dictionary] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	var effect := _physical()
	var context := _context(source)
	_check(runtime.apply_hit_payload([effect], context, 1.0).outcome == &"miss", "A failed Attack remains MISS before Armor")
	_check(events.is_empty(), "Failed Accuracy creates no Armor damage event")
	_check(runtime.apply_hit_payload([effect], context, 0.0).outcome == &"hit", "Mitigation preserves a successful hit outcome")
	var damage_events: Array[Dictionary] = []
	for event in events:
		if event.type == &"damage":
			damage_events.append(event)
	_check(damage_events.size() == 1, "One Physical component emits one damage event")
	if damage_events.is_empty():
		return
	var event: Dictionary = damage_events[0]
	_near(event.raw_magnitude, 100.0, "Damage telemetry retains source magnitude before Armor")
	_near(event.armor, 500.0, "Damage telemetry records the applied Armor rating")
	_near(event.armor_reduction, 0.6, "Damage telemetry records the applied mitigation fraction")
	_near(event.resolved_amount, 40.0, "Resolved magnitude includes Armor before the Health clamp")
	_near(event.amount, 30.0, "Displayed damage records actual Health removed rather than mitigated overkill")
	_near(event.health_damage, 30.0, "Actual damage agrees with the Health resource change")
	_near(event.resistance_percent, 0.0, "Physical damage events retain neutral school Resistance")
	target.restore_resources()
	target.set_base_value(CombatAttributes.Id.ARMOR, 1000.0)
	var before := target.get_value(CombatAttributes.Id.HEALTH)
	var tiny := runtime.apply_hit_payload([_physical(0.001)], context, 0.0)
	_check(tiny.outcome == &"hit", "A small mitigated Physical hit remains a valid delivery")
	_near(before - target.get_value(CombatAttributes.Id.HEALTH), 0.00025, "Fractional damage is not rounded away by Armor")


func _near(actual: float, expected: float, label: String) -> void:
	_check(is_finite(actual) and absf(actual - expected) <= 1e-8 * maxf(1.0, absf(expected)),
			"%s: expected %.12f, got %.12f" % [label, expected, actual])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
