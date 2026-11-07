extends SceneTree
## One action-scoped critical per successful damaging Hit, independent of Accuracy and weapon RNG.

const ATTRIBUTE_FIXTURE = preload("res://tests/attribute_fixture.gd")

var _checks: int = 0
var _failures: int = 0
var _actors: Array[ActorAttributes] = []
var _fixtures: Array[Node] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_multiplier_and_probability_boundaries()
	_test_shared_hybrid_critical_and_action_scopes()
	_test_rng_advances_only_for_damaging_success()
	_test_direct_effect_and_fresh_context_rules()
	_test_detached_source()
	_test_independent_seeded_streams()
	_test_reentrant_payload_keeps_resolved_critical()
	_test_event_overkill()
	for fixture in _fixtures:
		fixture.free()
	for actor in _actors:
		actor.free()
	print("Critical resolution checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _actor() -> ActorAttributes:
	var actor := ATTRIBUTE_FIXTURE.new_attributes()
	actor.set_base_value(CombatAttributes.Id.MAX_HEALTH, 1000000.0)
	actor.restore_resources()
	_actors.append(actor)
	return actor


func _context(source: ActorAttributes, spell: bool = true) -> GameplayEffectContext:
	return GameplayEffectContext.capture(source, GameplayTagSet.new(),
			PackedStringArray(["Ability.Spell"]) if spell else PackedStringArray(["Ability.Attack", "Weapon.Finesse"]))


func _damage(amount: float = 100.0, magic: bool = false) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.executions = [GameplayEffectDamageExecution.new()]
	effect.effect_id = &"Effect.CriticalTest"
	effect.base_magnitude = amount
	if magic:
		effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	return effect


func _modifier(attribute: int, value: float, tags: PackedStringArray) -> AttributeModifier:
	var modifier := AttributeModifier.new()
	modifier.attribute = attribute
	modifier.value = value
	modifier.required_context_tags = tags
	return modifier


func _buff() -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.kind = GameplayEffectDefinition.Kind.MODIFIERS
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.duration = 2.0
	effect.modifiers = [_modifier(CombatAttributes.Id.STRENGTH, 10.0, PackedStringArray())]
	effect.granted_tags = PackedStringArray(["Buff.CriticalTest"])
	return effect


func _system(seed_value: int = 73913, before_ready: bool = false) -> AbilitySystem:
	var holder := Node.new()
	holder.process_mode = Node.PROCESS_MODE_DISABLED
	var attributes := ATTRIBUTE_FIXTURE.new_attributes()
	attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 1000000.0)
	attributes.restore_resources()
	var system := AbilitySystem.new()
	system.attributes = attributes
	holder.add_child(attributes)
	holder.add_child(system)
	if before_ready:
		system.configure_randomness(seed_value)
	root.add_child(holder)
	if not before_ready:
		system.configure_randomness(seed_value)
	_fixtures.append(holder)
	return system


func _test_multiplier_and_probability_boundaries() -> void:
	var bonuses: Array[float] = [0.0, 50.0, 150.0, 1000.0, 1e9]
	var expected: Array[float] = [1.5, 2.0, 3.0, 11.5, 10000001.5]
	for index in bonuses.size():
		_near(CombatMath.get_critical_multiplier(bonuses[index]), expected[index],
				"Critical Damage adds uncapped bonus percentage points to the base multiplier")
	for invalid: float in [-100.0, NAN, INF, -INF]:
		_near(CombatMath.get_critical_multiplier(invalid), 1.5, "Invalid or negative critical bonuses grant no extra damage")
	var source := _actor()
	var target := _actor()
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var context := _context(source)
	var effect := _damage()
	var percentages: Array[float] = [0.0, 50.0, 75.0, 100.0]
	for chance in percentages:
		source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, chance)
		for roll: float in [0.0, 0.499999, 0.5, 0.749999, 0.75, 1.0]:
			var critical := chance > 0.0 and (chance == 100.0 or roll < chance / 100.0)
			var result := runtime.apply_hit_payload([effect], context, 0.0, roll)
			_check(result.outcome == &"hit" and result.is_critical == critical,
					"Critical chance uses correct zero, threshold and guaranteed endpoints")
			_near(result.critical_multiplier, 1.5 if critical else 1.0,
					"Normal hits use one while zero-bonus criticals use one-point-five")
			_near(result.critical_chance, chance / 100.0, "Successful result reports the action's fractional critical chance")
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 1000.0)
	_check(runtime.apply_hit_payload([effect], context, 0.0, 1.0).is_critical,
			"Overcap chance still guarantees a critical at the inclusive random endpoint")
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, -100.0)
	_check(not runtime.apply_hit_payload([effect], context, 0.0, 0.0).is_critical,
			"Negative chance clamps to zero")
	var resolved := context.with_critical_result(true, expected[-1], bonuses[-1])
	var magnitude := CombatMath.resolve_effect_result(effect, resolved, target)
	_near(magnitude.critical_magnitude, 100.0 * expected[-1], "Very large Critical Damage is not silently capped")
	_near(magnitude.raw_magnitude, 100.0, "Raw magnitude remains before critical scaling")


func _test_shared_hybrid_critical_and_action_scopes() -> void:
	var source := _actor()
	var target := _actor()
	target.set_base_value(CombatAttributes.Id.ARMOR, 2000.0)
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 80.0)
	target.set_base_value(CombatAttributes.Id.COLD_RESISTANCE, -100.0)
	source.set_base_value(CombatAttributes.Id.ARMOR_PENETRATION, 50.0)
	source.set_modifiers(&"scoped_crit", [
		_modifier(CombatAttributes.Id.CRITICAL_CHANCE, 100.0, PackedStringArray(["Ability.Spell"])),
		_modifier(CombatAttributes.Id.CRITICAL_DAMAGE, 50.0, PackedStringArray(["Ability.Spell"])),
		_modifier(CombatAttributes.Id.CRITICAL_DAMAGE, 300.0, PackedStringArray(["Damage.Fire"])),
	])
	var cold := _damage(100.0, true)
	cold.magic_school = GameplayEffectDefinition.MagicSchool.COLD
	var tags := GameplayTagSet.new()
	var runtime := GameplayEffectRuntime.new(target, tags)
	var events: Array[Dictionary] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	var payload: Array[GameplayEffectDefinition] = [_damage(), _damage(100.0, true), cold, _buff()]
	var result := runtime.apply_hit_payload(payload, _context(source), 0.0, 1.0)
	_check(result.outcome == &"hit" and result.is_critical and result.applied_effects == 4,
			"A guaranteed damaging critical authorizes the complete hybrid payload")
	_near(result.critical_multiplier, 2.0, "Critical Damage is queried in the shared action scope rather than Fire component scope")
	_near(result.critical_damage_percent, 50.0, "Critical metadata excludes the base multiplier")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 999510.0,
			"Critical Physical50, Fire40 and vulnerable Cold400 use penetration/mitigation after the shared multiplier")
	var damage_events := 0
	for event in events:
		if event.type == &"damage":
			damage_events += 1
			_check(event.is_critical, "Every damaging component shares the same critical outcome")
			_near(event.critical_magnitude, 200.0, "Each component retains critical magnitude before mitigation")
			_near(event.raw_magnitude, 100.0, "Each component retains its precritical source magnitude")
			_near(event.critical_multiplier, 2.0, "Every component shares the frozen Hit multiplier")
		else:
			_check(not event.is_critical or event.damage_type >= 0,
					"Non-damage lifecycle events do not invent a separate critical")
		if event.effect_id == &"":
			_check(not event.is_critical, "Attached modifier lifecycle events remain noncritical")
	_check(damage_events == 3, "A hybrid critical reports three component damage events, not three critical rolls")
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "A critical does not multiply attached modifier potency")
	runtime.advance(1.99)
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "A critical does not shorten attached modifier duration")
	runtime.advance(0.01)
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 10.0, "Attached modifiers expire at their authored time")
	_check(not runtime.apply_hit_payload([_damage(1.0, true)], _context(source, false), 0.0, 0.0).is_critical,
			"A Spell-scoped critical source does not leak into a Magic Attack")
	source.remove_modifiers(&"scoped_crit")
	source.set_modifiers(&"fire_only", [
		_modifier(CombatAttributes.Id.CRITICAL_CHANCE, 100.0, PackedStringArray(["Damage.Fire"])),
	])
	_check(not runtime.apply_hit_payload([_damage(1.0, true)], _context(source), 0.0, 0.0).is_critical,
			"A component school cannot independently add a critical to an unqualified action")


func _test_rng_advances_only_for_damaging_success() -> void:
	var source := _actor()
	var target := _actor()
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 100.0)
	var random := RandomNumberGenerator.new()
	random.seed = 8511
	var reference := RandomNumberGenerator.new()
	reference.seed = 8511
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new(), random)
	var context := _context(source)
	var before := random.state
	var failed := runtime.apply_hit_payload([_damage()], context, 0.8)
	_check(failed.outcome == &"resist" and not failed.is_critical, "Failed Accuracy cannot become critical")
	_check(random.state == before, "A failed Accuracy check never consumes the critical stream")
	var control := runtime.apply_hit_payload([_buff()], context, 0.0)
	_check(control.outcome == &"hit" and not control.is_critical, "A hostile modifier-only success is never critical")
	_check(random.state == before, "Modifier-only payloads never consume critical randomness")
	runtime.clear()
	runtime.apply_effect(_damage(), context)
	_check(random.state == before, "Direct non-hit effect application does not roll a critical")
	runtime.apply_hit_payload([_damage(), _damage(), _buff()], context, 0.0)
	reference.randf()
	_check(random.state == reference.state, "A successful multi-component damaging payload consumes exactly one critical roll")
	runtime.clear()
	before = random.state
	runtime.apply_hit_payload([_damage()], context, 0.0, 0.0)
	_check(random.state == before, "An explicit deterministic critical roll does not consume the seeded stream")
	for invalid: float in [NAN, INF, -INF]:
		var result := runtime.apply_hit_payload([_damage()], context, 0.0, invalid)
		_check(result.outcome == &"invalid", "Malformed critical roll input is rejected before payload mutation")
	_check(random.state == before, "Rejected roll inputs leave the critical stream unchanged")


func _test_direct_effect_and_fresh_context_rules() -> void:
	var source := _actor()
	var target := _actor()
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 100.0)
	source.set_base_value(CombatAttributes.Id.CRITICAL_DAMAGE, 50.0)
	var context := _context(source)
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var events: Array[Dictionary] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	var before := target.get_value(CombatAttributes.Id.HEALTH)
	runtime.apply_effect(_damage(), context)
	_near(before - target.get_value(CombatAttributes.Id.HEALTH), 100.0,
			"Direct effect application remains noncritical despite source critical attributes")
	_check(not events[-1].is_critical and events[-1].critical_multiplier == 1.0,
			"Direct effect telemetry explicitly marks a normal application")
	var resolved := context.with_critical_result(true, 2.0, 50.0)
	before = target.get_value(CombatAttributes.Id.HEALTH)
	runtime.apply_effect(_damage(), resolved)
	_near(before - target.get_value(CombatAttributes.Id.HEALTH), 200.0,
			"An explicitly supplied resolved Hit context can carry a critical into direct damage")
	_check(events[-1].is_critical, "Resolved critical context propagates its damage metadata")
	var fresh := resolved.duplicate_for_hit(0.3)
	_check(not fresh.is_critical and fresh.critical_multiplier == 1.0 and fresh.critical_damage_percent == 0.0,
			"A new delivery cannot inherit another Hit's critical outcome")
	_check(not context.is_critical and context.critical_multiplier == 1.0,
			"Resolving a Hit never mutates the original reusable launch context")
	before = target.get_value(CombatAttributes.Id.HEALTH)
	runtime.apply_effect(_damage(), fresh)
	_near(before - target.get_value(CombatAttributes.Id.HEALTH), 100.0, "A reset context has normal damage")
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 0.0)
	var next := runtime.apply_hit_payload([_damage()], resolved, 0.0, 0.0)
	_check(not next.is_critical and next.critical_multiplier == 1.0,
			"Even reusing a resolved context starts a fresh payload's critical decision")


func _test_detached_source() -> void:
	var source := _actor()
	var target := _actor()
	source.set_modifiers(&"spell_critical", [
		_modifier(CombatAttributes.Id.CRITICAL_CHANCE, 100.0, PackedStringArray(["Ability.Spell"])),
		_modifier(CombatAttributes.Id.CRITICAL_DAMAGE, 50.0, PackedStringArray(["Ability.Spell"])),
	])
	var context := _context(source)
	context.prime_effects([_damage()])
	_actors.erase(source)
	source.free()
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var result := runtime.apply_hit_payload([_damage()], context, 0.0, 1.0)
	_check(result.is_critical, "A detached projectile retains the source's action-scoped critical chance")
	_near(result.critical_multiplier, 2.0, "Detached source fallback retains the critical bonus")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 999800.0, "Detached critical payload damage remains correct")


func _signatures(system: AbilitySystem, context: GameplayEffectContext, effect: GameplayEffectDefinition) -> Dictionary:
	var raw: Array[float] = []
	var flags: Array[bool] = []
	var outcomes: Array[StringName] = []
	var receiver := func(event: Dictionary) -> void:
		if event.type == &"damage":
			raw.append(float(event.raw_magnitude))
			flags.append(bool(event.is_critical))
	system.combat_event.connect(receiver)
	for attempt in 60:
		outcomes.append(system.receive_hit(context, [effect]).outcome)
	system.combat_event.disconnect(receiver)
	return {"raw": raw, "flags": flags, "outcomes": outcomes}


func _test_independent_seeded_streams() -> void:
	var source := _actor()
	var weapon := WeaponDefinition.new()
	weapon.kind = WeaponDefinition.Kind.SWORD_ONE_HAND
	weapon.physical_damage_min = 30.0
	weapon.physical_damage_max = 40.0
	weapon.base_attack_cycle = 1.0
	var context := _context(source, false)
	context.bind_weapon(weapon)
	var effect := _damage(0.0)
	effect.use_weapon_damage = true
	var first := _system(51379)
	var second := _system(51379)
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 0.0)
	var normal := _signatures(first, context, effect)
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 100.0)
	var critical := _signatures(second, context, effect)
	_check(normal.outcomes == critical.outcomes, "Critical chance does not perturb the independent Accuracy sequence")
	_check(normal.raw == critical.raw, "Critical chance does not perturb the independent weapon damage sequence")
	_check(not normal.flags.has(true) and not critical.flags.has(false), "The compared streams still apply their different critical chances")
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 50.0)
	var seeded_before_ready := _system(73917, true)
	var seeded_after_ready := _system(73917)
	var a := _signatures(seeded_before_ready, context, effect)
	var b := _signatures(seeded_after_ready, context, effect)
	_check(a.flags == b.flags and a.raw == b.raw and a.outcomes == b.outcomes,
			"Configuring randomness before or after initialization reproduces all three streams")
	_check(a.flags.has(true) and a.flags.has(false), "The seeded comparison covers ordinary and critical hits")


func _test_reentrant_payload_keeps_resolved_critical() -> void:
	var source := _actor()
	var target := _actor()
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 100.0)
	source.set_base_value(CombatAttributes.Id.CRITICAL_DAMAGE, 50.0)
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var context := _context(source)
	var damages: Array[Dictionary] = []
	var nested := [false]
	runtime.combat_event.connect(func(event: Dictionary) -> void:
		if event.type != &"damage":
			return
		damages.append(event)
		if not nested[0]:
			nested[0] = true
			source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 0.0)
			source.set_base_value(CombatAttributes.Id.CRITICAL_DAMAGE, 1000.0)
			runtime.apply_hit_payload([_damage(10.0)], context, 0.0, 0.0))
	var result := runtime.apply_hit_payload([_damage(), _damage(100.0, true)], context, 0.0, 0.0)
	_check(result.is_critical and result.critical_multiplier == 2.0,
			"A callback cannot overwrite the outer Hit's resolved critical")
	_check(damages.size() == 3, "The reentrant test emits the outer two components and nested damage once each")
	if damages.size() == 3:
		_check(damages[0].is_critical and not damages[1].is_critical and damages[2].is_critical,
				"Nested normal damage does not clear the remaining outer component's critical flag")
		_near(damages[2].critical_multiplier, 2.0, "Changing source bonuses mid-payload does not recompute the outer critical")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 999590.0,
			"Reentrant damage uses outer two-hundred plus nested ten plus outer two-hundred")
	_check(not context.is_critical, "Reentrant resolution does not contaminate the reusable source context")


func _test_event_overkill() -> void:
	var source := _actor()
	var target := _actor()
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 100.0)
	target.set_base_value(CombatAttributes.Id.HEALTH, 50.0)
	var system := _system()
	system.attributes.set_base_value(CombatAttributes.Id.HEALTH, 50.0)
	var events: Array[Dictionary] = []
	system.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	var result := system.receive_hit(_context(source), [_damage()], 0.0, 1.0)
	_check(result.is_critical and result.critical_multiplier == 1.5, "A guaranteed critical survives the inclusive supplied roll endpoint")
	var damages: Array[Dictionary] = []
	var outcomes: Array[Dictionary] = []
	for event in events:
		if event.type == &"damage":
			damages.append(event)
		elif event.type == &"hit_outcome":
			outcomes.append(event)
	_check(damages.size() == 1 and outcomes.size() == 1, "A critical emits one damage component and one shared Hit outcome")
	if damages.size() == 1 and outcomes.size() == 1:
		_near(damages[0].raw_magnitude, 100.0, "Critical telemetry retains raw source magnitude")
		_near(damages[0].critical_magnitude, 150.0, "Critical telemetry retains magnitude before mitigation")
		_near(damages[0].resolved_amount, 150.0, "Resolved critical damage remains independent of target Health")
		_near(damages[0].amount, 50.0, "Displayed critical damage still records actual Health loss")
		_check(outcomes[0].is_critical and damages[0].is_critical, "Hit and damage events agree on the shared critical flag")
	_near(system.attributes.get_value(CombatAttributes.Id.HEALTH), 0.0, "Critical overkill does not produce negative Health")


func _near(actual: float, expected: float, label: String) -> void:
	_check(is_finite(actual) and absf(actual - expected) <= 1e-8 * maxf(1.0, absf(expected)),
			"%s: expected %.12f, got %.12f" % [label, expected, actual])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
