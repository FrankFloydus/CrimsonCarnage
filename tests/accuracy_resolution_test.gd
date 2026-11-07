extends SceneTree
## Shared attack/spell Accuracy anchors, probability boundaries and complete payload outcomes.
## Run headless with --script res://tests/accuracy_resolution_test.gd.

const ATTRIBUTE_FIXTURE = preload("res://tests/attribute_fixture.gd")

class WaitingExecution extends AbilityExecution:
	func begin(_cast: AbilityCast) -> void:
		pass

var _checks: int = 0
var _failures: int = 0
var _fixtures: Array[Node] = []
var _actors: Array[ActorAttributes] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_curve_anchors_and_examples()
	_test_probability_domains()
	_test_payload_is_one_shared_check()
	_test_control_and_beneficial_payloads()
	_test_action_type_selects_failure()
	_test_detached_source_accuracy()
	_test_system_events_costs_and_randomness()
	_test_rejections_have_no_outcome()
	for fixture in _fixtures:
		fixture.free()
	for actor in _actors:
		actor.free()
	print("Accuracy resolution checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _actor(level: int = 1) -> ActorAttributes:
	var actor := ATTRIBUTE_FIXTURE.new_attributes()
	actor.level = level
	actor.set_base_value(CombatAttributes.Id.MAX_HEALTH, 1000.0)
	actor.restore_resources()
	_actors.append(actor)
	return actor


func _system() -> AbilitySystem:
	var holder := Node.new()
	holder.process_mode = Node.PROCESS_MODE_DISABLED
	var attributes := ATTRIBUTE_FIXTURE.new_attributes()
	var system := AbilitySystem.new()
	system.attributes = attributes
	holder.add_child(attributes)
	holder.add_child(system)
	root.add_child(holder)
	_fixtures.append(holder)
	return system


func _context(source: ActorAttributes, tags: PackedStringArray) -> GameplayEffectContext:
	return GameplayEffectContext.capture(source, GameplayTagSet.new(), tags)


func _damage(amount: float = 20.0) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.executions = [GameplayEffectDamageExecution.new()]
	effect.effect_id = &"Effect.AccuracyDamage"
	effect.get_damage_execution().amount = AmountDefinition.fixed(amount)
	return effect


func _control() -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.effect_id = &"Effect.AccuracyControl"
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.duration = 5.0
	effect.granted_tags = PackedStringArray(["State.TestControl"])
	var modifier := AttributeModifier.new()
	modifier.attribute = CombatAttributes.Id.STRENGTH
	modifier.value = -5.0
	effect.modifiers = [modifier]
	return effect


func _test_curve_anchors_and_examples() -> void:
	var expected_base := [0.80, 0.75, 0.68, 0.60, 0.50, 0.40, 0.24, 0.18, 0.14, 0.11, 0.08]
	var expected_cap := [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.50, 0.35, 0.25, 0.16, 0.10]
	for source_level in [1, 25, 50]:
		for gap in 11:
			var details := CombatMath.get_hit_chance_details(source_level, source_level + gap, 10.0)
			_near(details.hit_chance, expected_base[gap], "Starting rating matches the agreed level table")
			_near(details.max_chance, expected_cap[gap], "Level ceiling matches the agreed table")
			_near(CombatMath.get_hit_chance(source_level, source_level + gap, 1e12),
					expected_cap[gap], "Even enormous rating cannot exceed the level ceiling")
			_near(CombatMath.get_hit_chance(source_level, source_level + gap,
					details.required_accuracy), expected_cap[gap],
					"Published total rating actually reaches the displayed ceiling")
	_near(CombatMath.get_hit_chance(60, 60, 69.0), 0.8855072463768116,
			"Split level-sixty allocation retains its documented Accuracy contribution")
	_near(CombatMath.get_hit_chance(60, 60, 128.0), 0.9710144927536232,
			"Full primary allocation still leaves an equipment contribution to reaching one hundred")
	_near(CombatMath.get_hit_chance(60, 60, 148.0), 1.0,
			"Twenty additional rating closes the documented level-sixty miss chance")
	_near(CombatMath.get_hit_chance(50, 60, 108.0), 0.0889908256880734,
			"A ten-level disadvantage remains near nine percent with full primary allocation")
	for advantage in 6:
		_near(CombatMath.get_hit_chance(10, 10 - advantage, 10.0),
				minf(1.0, 0.8 + 0.04 * advantage), "Natural accuracy improves against lower levels")
	_near(CombatMath.get_hit_chance(1, 16, 10.0), 0.018984375,
			"The positive tail continues below ten percent at fifteen levels")
	_near(CombatMath.get_hit_chance(1, 21, 10.0), 0.0045050811767578,
			"The twenty-level tail has no artificial global chance floor")
	_near(CombatMath.get_hit_chance(1, 60, 1e12), 0.1 * pow(0.75, 49),
			"Huge rating cannot erase the far higher-level tail")


func _test_probability_domains() -> void:
	var all_bounded := true
	var all_gap_monotonic := true
	var all_rating_monotonic := true
	var prior: float
	for level in range(1, 61):
		for rating: float in [0.0, 5.0, 10.0, 20.0, 69.0, 128.0, 1000.0, 1e12]:
			prior = 1.0
			for target_level in range(1, 61):
				var chance := CombatMath.get_hit_chance(level, target_level, rating)
				all_bounded = all_bounded and is_finite(chance) and chance > 0.0 and chance <= 1.0
				all_gap_monotonic = all_gap_monotonic and chance <= prior + 1e-12
				prior = chance
		for target_level in range(1, 61):
			prior = 0.0
			for rating: float in [0.0, 5.0, 10.0, 20.0, 69.0, 128.0, 1000.0, 1e12]:
				var chance := CombatMath.get_hit_chance(level, target_level, rating)
				all_rating_monotonic = all_rating_monotonic and chance >= prior - 1e-12
				prior = chance
	_check(all_bounded, "The supported level/rating domain has finite positive chances bounded by one")
	_check(all_gap_monotonic, "Raising the target level never raises success probability")
	_check(all_rating_monotonic, "Additional Accuracy never lowers success probability")
	_near(CombatMath.get_hit_chance(0, -10, 10.0), 0.8,
			"Invalid nonpositive levels safely normalize to the minimum level")
	_near(CombatMath.get_hit_chance(1, 1, -100.0), 0.7, "Negative rating is treated as zero")
	for invalid: float in [NAN, INF, -INF]:
		_near(CombatMath.get_hit_chance(1, 1, invalid), 0.0,
				"Nonfinite Accuracy cannot produce a successful probability")
	seed(73919)
	for iteration in 10:
		CombatMath.get_hit_chance(1, 11, 10.0)
	var after_inspection := randf()
	seed(73919)
	_near(after_inspection, randf(), "Inspecting probabilities never consumes global random sampling")


func _test_payload_is_one_shared_check() -> void:
	var source := _actor()
	var target := _actor()
	var target_tags := GameplayTagSet.new()
	var runtime := GameplayEffectRuntime.new(target, target_tags)
	var context := _context(source, PackedStringArray(["Ability.Spell"]))
	var events: Array[Dictionary] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	var payload: Array[GameplayEffectDefinition] = [_damage(20.0), _damage(30.0), _control()]
	var failed := runtime.apply_hit_payload(payload, context, 0.8)
	_check(failed.outcome == &"resist" and failed.applied_effects == 0,
			"A roll exactly at the eighty-percent boundary fails the entire spell payload")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 1000.0,
			"A failed hit causes zero direct or glancing damage")
	_check(runtime.active_count() == 0 and not target_tags.has_tag(&"State.TestControl"),
			"Failed hits cannot retain control tags or modifier instances")
	_check(events.is_empty(), "Failed hits emit no accepted-effect or damage notifications")
	var hit := runtime.apply_hit_payload(payload, context, 0.799999)
	_check(hit.outcome == &"hit" and hit.applied_effects == 3,
			"One successful boundary roll accepts all eligible components together")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 950.0,
			"Both components apply their full authored damage after one successful check")
	_check(runtime.active_count() == 1 and target_tags.has_tag(&"State.TestControl"),
			"The same hit result authorizes the attached control effect")
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 5.0,
			"Attached modifiers apply exactly once")
	runtime.clear()
	source.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 30.0)
	var certain := runtime.apply_hit_payload([_damage()], context, 1.0)
	_check(certain.outcome == &"hit", "One-hundred-percent Accuracy succeeds even at roll one")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 930.0,
			"The inclusive random endpoint cannot cause a false miss at the cap")


func _test_control_and_beneficial_payloads() -> void:
	var source := _actor()
	var target := _actor(11)
	var tags := GameplayTagSet.new()
	var runtime := GameplayEffectRuntime.new(target, tags)
	var context := _context(source, PackedStringArray(["Ability.Spell"]))
	var failed := runtime.apply_hit_payload([_control()], context, 0.5)
	_check(failed.outcome == &"resist" and runtime.active_count() == 0,
			"Control-only spells cannot bypass the same higher-level Accuracy check")
	var self_runtime := GameplayEffectRuntime.new(source, GameplayTagSet.new())
	var self_result := self_runtime.apply_hit_payload([_control()], context, 1.0)
	_check(self_result.outcome == &"hit" and self_runtime.active_count() == 1,
			"Self modifier applications do not randomly miss")
	self_runtime.clear()
	context.ability_tags.append("Ability.Beneficial")
	var positive := runtime.apply_hit_payload([_control()], context, 1.0)
	_check(positive.outcome == &"hit" and runtime.active_count() == 1,
			"Explicit beneficial modifier-only ally deliveries bypass Accuracy")
	runtime.clear()
	var damage := runtime.apply_hit_payload([_damage(), _control()], context, 0.5)
	_check(damage.outcome == &"resist" and runtime.active_count() == 0,
			"A Beneficial tag cannot bypass Accuracy for a payload containing damage")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 1000.0,
			"Misclassified damaging payloads still fail without damage")


func _test_action_type_selects_failure() -> void:
	var source := _actor()
	var target := _actor()
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var magic := _damage()
	magic.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	var attack := _context(source, PackedStringArray(["Ability.Attack", "Weapon.Finesse"]))
	_check(runtime.apply_hit_payload([magic], attack, 0.9).outcome == &"miss",
			"A magical component of an Attack still reports MISS")
	var spell := _context(source, PackedStringArray(["Ability.Spell", "Weapon.Finesse"]))
	_check(runtime.apply_hit_payload([_damage()], spell, 0.9).outcome == &"resist",
			"A physical component of a Spell still reports RESIST")
	var invalid := runtime.apply_hit_payload([_damage()], spell, NAN)
	_check(invalid.outcome == &"invalid", "Invalid explicit roll inputs cannot mutate a target")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 1000.0,
			"Failure labels do not affect target Health")


func _test_detached_source_accuracy() -> void:
	var source := _actor(20)
	var target := _actor(30)
	var modifier := AttributeModifier.new()
	modifier.attribute = CombatAttributes.Id.ACCURACY_RATING
	modifier.value = 50.0
	modifier.required_context_tags = PackedStringArray(["Weapon.Finesse"])
	source.set_modifiers(&"scope", [modifier])
	var context := _context(source, PackedStringArray(["Ability.Attack", "Weapon.Finesse"]))
	var expected := CombatMath.get_hit_chance(20, 30, 60.0)
	context.prime_effects([_damage()])
	_actors.erase(source)
	source.free()
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var result := runtime.apply_hit_payload([_damage()], context, expected - 0.000001)
	_near(result.hit_chance, expected,
			"A detached source retains launch-time level and scoped Accuracy for delivery")
	_check(result.outcome == &"hit", "Detached projectile payloads remain eligible to connect")
	var next := runtime.apply_hit_payload([_damage()], context, expected)
	_check(next.outcome == &"miss", "Each detached hit receives its own supplied Accuracy roll")


func _test_system_events_costs_and_randomness() -> void:
	var source := _system()
	var target := _system()
	var ability := AbilityDefinition.new()
	ability.ability_id = &"accuracy_spell"
	ability.ability_tags = PackedStringArray(["Ability.Spell"])
	var commitment := preload("res://tests/ability_commit_fixture.gd")
	ability.resource_costs = [commitment.make_cost(AmountDefinition.Pool.MANA, 20.0)]
	ability.charge_pool = commitment.make_cooldown(3.0)
	ability.execution = WaitingExecution.new()
	source.grant_ability(ability)
	var events: Array[Dictionary] = []
	var results: Array[Dictionary] = []
	target.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	target.hit_resolved.connect(func(result: Dictionary) -> void: results.append(result))
	_check(source.try_activate(ability.ability_id), "A costed spell activates before the delivery result")
	var context := source.get_active_cast(ability.ability_id).context
	var failed := target.receive_hit(context, [_damage()], 0.9)
	_check(failed.outcome == &"resist" and results.size() == 1,
			"AbilitySystem reports one failed delivery result")
	_near(source.attributes.get_value(CombatAttributes.Id.MANA), 80.0,
			"A resisted delivery does not refund the already committed spell cost")
	_near(source.get_cooldown_remaining(ability.ability_id), 3.0,
			"Failure does not erase the authored cooldown")
	_check(events.size() == 1 and events[0].type == &"hit_outcome"
			and events[0].outcome == &"resist", "Failure emits one authoritative target outcome event")
	_check(int(events[0].source_id) == source.attributes.get_instance_id()
			and int(events[0].target_id) == target.attributes.get_instance_id(),
			"Outcome events retain detached source and target identities")
	events.clear()
	target.receive_hit(context, [_damage()], 0.1)
	var outcomes := 0
	var damage_events := 0
	for event in events:
		outcomes += 1 if event.type == &"hit_outcome" else 0
		damage_events += 1 if event.type == &"damage" else 0
	_check(outcomes == 1 and damage_events == 1,
			"Success emits one outcome alongside its explicit damage event")
	source.cancel_ability(ability.ability_id)
	var twin := _system()
	target.configure_randomness(98231)
	twin.configure_randomness(98231)
	var first: Array[StringName] = []
	var second: Array[StringName] = []
	var tiny := _damage(0.01)
	for iteration in 30:
		first.append(target.receive_hit(context, [tiny]).outcome)
		second.append(twin.receive_hit(context, [tiny]).outcome)
	_check(first == second, "Configured independent Accuracy streams reproduce delivery sequences")
	_check(first.has(&"hit") and first.has(&"resist"),
			"A seeded ordinary Accuracy sequence contains successes and failures")


func _test_rejections_have_no_outcome() -> void:
	var source := _system()
	var target := _system()
	var context := source.create_effect_context(PackedStringArray(["Ability.Attack"]))
	var events: Array[Dictionary] = []
	target.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	_check(target.receive_hit(context, [], 0.0).outcome == &"invalid",
			"Empty payloads do not become hit attempts")
	_check(target.receive_hit(context, [_damage()], NAN).outcome == &"invalid",
			"Nonfinite explicit rolls reject before emitting an outcome")
	target.attributes.set_base_value(CombatAttributes.Id.HEALTH, 0.0)
	_check(target.receive_hit(context, [_damage()], 0.0).outcome == &"invalid",
			"Dead targets reject deliveries before Accuracy")
	_check(events.is_empty(), "Rejected deliveries produce no misleading hit/miss statistics")


func _near(actual: float, expected: float, message: String) -> void:
	_check(is_finite(actual) and absf(actual - expected) <= 1e-9 * maxf(1.0, absf(expected)),
			"%s: expected %.12f, got %.12f" % [message, expected, actual])


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
