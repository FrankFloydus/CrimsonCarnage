extends SceneTree
## Matching-school Resistance boundaries, authoring, payload integration and actual damage telemetry.

const ATTRIBUTE_FIXTURE = preload("res://tests/attribute_fixture.gd")
const COMBAT_DEFINITION_JSON = preload("res://combat/abilities/combat_definition_json.gd")

const RESISTANCES: Array[int] = [
	CombatAttributes.Id.FIRE_RESISTANCE, CombatAttributes.Id.COLD_RESISTANCE,
	CombatAttributes.Id.LIGHTNING_RESISTANCE, CombatAttributes.Id.VOID_RESISTANCE,
	CombatAttributes.Id.NECROTIC_RESISTANCE,
]
const SCHOOL_TAGS := ["Damage.Fire", "Damage.Cold", "Damage.Lightning", "Damage.Void", "Damage.Necrotic"]
const TEMP_EFFECT := "res://.godot/resistance_effect_roundtrip.tres"

var _checks: int = 0
var _failures: int = 0
var _actors: Array[ActorAttributes] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_school_identity_and_validation()
	_test_all_school_boundaries()
	_test_spell_penetration()
	_test_spell_penetration_delivery()
	_test_school_scopes_and_power()
	_test_detached_source_and_fractional_damage()
	_test_physical_and_action_independence()
	_test_hybrid_payload_and_accuracy()
	_test_modifier_effects_are_not_mitigated()
	_test_damage_telemetry_and_overkill()
	_test_saved_fireball()
	_test_serialized_school()
	for actor in _actors:
		actor.free()
	print("Resistance resolution checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _actor() -> ActorAttributes:
	var actor := ATTRIBUTE_FIXTURE.new_attributes()
	actor.set_base_value(CombatAttributes.Id.MAX_HEALTH, 10000.0)
	actor.restore_resources()
	_actors.append(actor)
	return actor


func _effect(school: int = GameplayEffectDefinition.MagicSchool.FIRE, amount: float = 100.0) -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.executions = [GameplayEffectDamageExecution.new()]
	effect.effect_id = 269
	effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	effect.magic_school = school
	effect.get_damage_execution().amount = AmountDefinition.fixed(amount)
	return effect


func _context(source: ActorAttributes, spell: bool = true) -> GameplayEffectContext:
	return GameplayEffectContext.capture(source, GameplayTagSet.new(),
			PackedStringArray(["Ability.Spell"]) if spell else PackedStringArray(["Ability.Attack", "Weapon.Finesse"]))


func _modifier(attribute: int, amount: float) -> AttributeModifier:
	var modifier := AttributeModifier.new()
	modifier.attribute = attribute
	modifier.value = amount
	return modifier


func _buff() -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.duration = 2.0
	effect.modifiers = [_modifier(CombatAttributes.Id.STRENGTH, 10.0)]
	effect.granted_tags = PackedStringArray(["Buff.ResistanceTest"])
	return effect


func _test_school_identity_and_validation() -> void:
	_check(GameplayEffectDefinition.DamageType.PHYSICAL == 0 and GameplayEffectDefinition.DamageType.MAGIC == 1,
			"Existing damage-type identities retain their original Physical/Magic meanings")
	_check(GameplayEffectDefinition.MagicSchool.values() == [0, 1, 2, 3, 4],
			"Five explicit schools have stable independent identities")
	for school in 5:
		var effect := _effect(school)
		_check(effect.get_validation_error().is_empty(), "Each authored Magic school is valid")
		_check(effect.get_resistance_attribute() == RESISTANCES[school], "Each school selects exactly its matching Resistance")
		var tags := effect.get_context_tags(PackedStringArray(["Ability.Spell", "Damage.Cold", "Damage.Physical"]))
		_check(tags.has("Damage.Magic") and tags.has(SCHOOL_TAGS[school]) and tags.has("Damage.Direct"),
				"Magic payloads derive their canonical type, school and timing")
		_check(not tags.has("Damage.Physical"), "Action-level damage identity cannot relabel a Magic component")
		for other in 5:
			if other != school:
				_check(not tags.has(SCHOOL_TAGS[other]), "A component cannot inherit another school's identity from its action")
		effect.damage_tags = PackedStringArray([SCHOOL_TAGS[school], "Damage.Magic", "Damage.ResistanceTest.Custom"])
		_check(effect.get_validation_error().is_empty(), "Matching explicit tags and unrelated custom tags remain valid")
		_check(effect.get_context_tags().has("Damage.ResistanceTest.Custom"), "Custom damage tags retain their authoring scope")
		effect.damage_tags = PackedStringArray([SCHOOL_TAGS[(school + 1) % 5]])
		_check(effect.get_validation_error() == &"Effect.ConflictingDamageTag", "Contradictory effect-school tags are rejected")
	var invalid := _effect()
	invalid.set("magic_school", 99)
	_check(invalid.get_validation_error() == &"Effect.InvalidMagicSchool", "Invalid Magic school values are rejected before damage")
	invalid.damage_type = GameplayEffectDefinition.DamageType.PHYSICAL
	_check(invalid.get_validation_error().is_empty() and invalid.get_resistance_attribute() == CombatAttributes.Id.NONE,
			"Physical damage ignores the unused Magic school field")
	invalid.damage_tags = PackedStringArray(["Damage.Physical"])
	_check(invalid.get_validation_error().is_empty(), "Existing matching Physical tags remain valid")
	invalid.damage_tags = PackedStringArray(["Damage.Fire"])
	_check(invalid.get_validation_error() == &"Effect.ConflictingDamageTag", "Physical damage cannot claim a Magic school scope")
	invalid.damage_tags = PackedStringArray()
	invalid.set("damage_type", 4)
	_check(invalid.get_validation_error() == &"Effect.InvalidDamageType",
			"An old invalid numeric damage type is not silently reinterpreted as a new school")
	var buff := _buff()
	buff.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	buff.set("magic_school", 99)
	_check(buff.get_validation_error().is_empty() and buff.get_resistance_attribute() == CombatAttributes.Id.NONE,
			"Modifier payloads do not require or use a Magic school")


func _test_all_school_boundaries() -> void:
	var source := _actor()
	var target := _actor()
	var context := _context(source)
	for school in 5:
		var effect := _effect(school)
		for id in RESISTANCES:
			target.set_base_value(id, 80.0)
		for requested: float in [-1000.0, -100.0, -50.0, 0.0, 25.0, 50.0, 80.0, 100.0, 1000000.0]:
			target.set_base_value(RESISTANCES[school], requested)
			var expected := clampf(requested, -100.0, 80.0)
			var result := CombatMath.resolve_effect_result(effect, context, target)
			_near(result.raw_magnitude, 100.0, "Resistance never changes source magnitude")
			_near(result.resistance_percent, expected, "Each school clamps to minus one hundred through eighty percent")
			_near(result.magnitude, 100.0 * (1.0 - expected / 100.0), "Each matching Resistance applies exactly one damage multiplier")
			_check(result.resistance_attribute == RESISTANCES[school] and result.magic_school == school,
					"Resolution metadata identifies the exact school and defense")
		target.set_base_value(RESISTANCES[school], 0.0)
		_near(CombatMath.resolve_effect(effect, context, target), 100.0,
				"Other schools at eighty percent do not protect the selected neutral school")
	_actors.erase(target)
	target.free()
	_near(CombatMath.resolve_effect(_effect(), context, null), 0.0, "Missing targets safely resolve zero damage")


func _test_spell_penetration() -> void:
	var source := _actor()
	var target := _actor()
	var penetration := CombatAttributes.Id.SPELL_PENETRATION
	var context := _context(source)
	var fire := _effect()
	_near(source.get_value(penetration), 0.0, "Spell Penetration starts at zero")
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 80.0)
	_near(CombatMath.resolve_effect(fire, context, target), 20.0, "Zero penetration preserves high Resistance")
	source.set_base_value(penetration, -20.0)
	_near(source.get_value(penetration), 0.0, "Negative Spell Penetration floors at zero")
	source.set_base_value(penetration, 20.0)
	for school in RESISTANCES.size():
		var effect := _effect(school)
		var resistance := RESISTANCES[school]
		target.set_base_value(resistance, 140.0)
		_near(CombatMath.resolve_effect(effect, context, target), 40.0,
				"Twenty penetration subtracts from the matching capped Resistance")
		_near(target.get_value(resistance), 80.0, "Spell resolution preserves the target's effective Resistance")
		_near(target.get_base_value(resistance), 140.0, "Spell resolution preserves the target's stored Resistance")
		target.set_base_value(resistance, 0.0)
		_near(CombatMath.resolve_effect(effect, context, target), 120.0,
				"Twenty penetration turns neutral Resistance into a damage vulnerability")
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, -25.0)
	_near(CombatMath.resolve_effect(fire, context, target), 145.0, "Penetration deepens existing vulnerabilities")
	source.set_base_value(penetration, 150.0)
	_near(source.get_value(penetration), 150.0, "Spell Penetration can exceed one hundred points")
	_near(CombatMath.resolve_effect(fire, context, target), 200.0, "Effective Resistance stops at minus one hundred percent")
	_near(CombatMath.resolve_effect(fire, _context(source, false), target), 125.0,
			"Magic components of Attacks use Resistance without Spell Penetration")
	var periodic_fire := _effect()
	periodic_fire.timing = GameplayEffectDefinition.Timing.DURATION
	periodic_fire.duration = 2.0
	periodic_fire.period = 1.0
	_near(CombatMath.resolve_effect(periodic_fire, context, target), 125.0,
			"Periodic spell damage uses Resistance without the spell-hit penetration bonus")


func _test_spell_penetration_delivery() -> void:
	var source := _actor()
	var target := _actor()
	source.set_base_value(CombatAttributes.Id.SPELL_PENETRATION, 20.0)
	source.set_base_value(CombatAttributes.Id.CRITICAL_CHANCE, 100.0)
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 80.0)
	var physical := _effect(GameplayEffectDefinition.MagicSchool.FIRE, 20.0)
	physical.damage_type = GameplayEffectDefinition.DamageType.PHYSICAL
	var payload: Array[GameplayEffectDefinition] = [
		_effect(), _effect(GameplayEffectDefinition.MagicSchool.COLD), physical,
	]
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var context := _context(source)
	var damage_events: Array[Dictionary] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void:
		if event.type == &"damage":
			damage_events.append(event))
	_check(runtime.apply_hit_payload(payload, context, 1.0, 0.0).outcome == &"resist"
			and damage_events.is_empty(), "Spell Penetration cannot turn a failed Accuracy roll into a hit")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 10000.0, "A failed spell deals no damage")
	var hit := runtime.apply_hit_payload(payload, context, 0.0, 0.0)
	_check(hit.outcome == &"hit" and hit.is_critical and damage_events.size() == 3,
			"One successful critical spell delivers every component")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 9730.0,
			"Critical spell deals 60 Fire, 180 Cold and 30 Physical damage")
	if damage_events.size() == 3:
		_near(damage_events[0].resistance_percent, 80.0, "Fire telemetry preserves the target's original Resistance")
		_near(damage_events[0].effective_resistance_percent, 60.0, "Fire telemetry reports effective Resistance")
		_near(damage_events[0].spell_penetration, 20.0, "Fire telemetry reports caster Spell Penetration")
		_near(damage_events[1].effective_resistance_percent, -20.0, "Cold telemetry reports the vulnerability")
		_near(damage_events[2].spell_penetration, 0.0, "Physical components ignore Spell Penetration")
	_near(target.get_value(CombatAttributes.Id.FIRE_RESISTANCE), 80.0, "A delivered hit does not alter target Resistance")


func _test_school_scopes_and_power() -> void:
	var source := _actor()
	var target := _actor()
	var effect := _effect(GameplayEffectDefinition.MagicSchool.FIRE)
	effect.get_damage_execution().power_coefficient = 0.5
	var fire_power := _modifier(CombatAttributes.Id.MAGIC_POWER, 20.0)
	fire_power.required_context_tags = PackedStringArray(["Damage.Fire"])
	source.set_modifiers(&"fire_power", [fire_power])
	var scoped_resistance := _modifier(CombatAttributes.Id.FIRE_RESISTANCE, 50.0)
	scoped_resistance.required_context_tags = PackedStringArray(["Damage.Fire", "Ability.Spell"])
	target.set_modifiers(&"fire_defense", [scoped_resistance])
	var result := CombatMath.resolve_effect_result(effect, _context(source), target)
	_near(result.raw_magnitude, 120.0, "Canonical school scopes select matching source Power bonuses")
	_near(result.magnitude, 60.0, "Target Resistance scopes use the component's complete action and school tags")
	result = CombatMath.resolve_effect_result(effect, _context(source, false), target)
	_near(result.magnitude, 120.0, "A spell-only Resistance modifier does not leak into a Magic Attack")
	effect.magic_school = GameplayEffectDefinition.MagicSchool.COLD
	result = CombatMath.resolve_effect_result(effect, _context(source), target)
	_near(result.raw_magnitude, 110.0, "A different school does not inherit a Fire-scoped Power bonus")
	_near(result.magnitude, 110.0, "A different school does not inherit Fire Resistance")
	target.remove_modifiers(&"fire_defense")
	effect.magic_school = GameplayEffectDefinition.MagicSchool.FIRE
	_near(CombatMath.resolve_effect(effect, _context(source), target), 120.0, "Removing a Resistance owner restores neutral mitigation")
	source.remove_modifiers(&"fire_power")
	_near(CombatMath.resolve_effect(effect, _context(source), target), 110.0, "Removing source Power preserves its independent primary foundation")


func _test_detached_source_and_fractional_damage() -> void:
	var source := _actor()
	var target := _actor()
	var school_power := _modifier(CombatAttributes.Id.MAGIC_POWER, 20.0)
	school_power.required_context_tags = PackedStringArray(["Damage.Fire"])
	var school_penetration := _modifier(CombatAttributes.Id.SPELL_PENETRATION, 20.0)
	school_penetration.required_context_tags = PackedStringArray(["Damage.Fire"])
	source.set_modifiers(&"fire_bonuses", [school_power, school_penetration])
	var effect := _effect()
	effect.get_damage_execution().amount = null
	effect.get_damage_execution().power_coefficient = 1.0
	var context := _context(source)
	context.prime_effects([effect])
	_actors.erase(source)
	source.free()
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 80.0)
	var result := CombatMath.resolve_effect_result(effect, context, target)
	_near(result.raw_magnitude, 40.0, "Detached sources retain the correct school-scoped Power fallback")
	_near(result.magnitude, 16.0, "Detached payloads combine scoped source penetration with live target Resistance")
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, -100.0)
	_near(CombatMath.resolve_effect(effect, context, target), 80.0,
			"Changing target Resistance affects the next delivery rather than an old target snapshot")
	effect.get_damage_execution().amount = AmountDefinition.fixed(0.001)
	effect.get_damage_execution().power_coefficient = 0.0
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 80.0)
	result = CombatMath.resolve_effect_result(effect, context, target)
	_near(result.magnitude, 0.0004, "Small mitigated components retain fractional damage internally")
	var before := target.get_value(CombatAttributes.Id.HEALTH)
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	_check(runtime.apply_hit_payload([effect], context, 0.0).outcome == &"hit",
			"A fractional mitigated hit still follows the shared Accuracy path")
	_near(before - target.get_value(CombatAttributes.Id.HEALTH), 0.0004,
			"Fractional Resistance results are not rounded away before applying Health loss")


func _test_physical_and_action_independence() -> void:
	var source := _actor()
	var target := _actor()
	for id in RESISTANCES:
		target.set_base_value(id, 80.0)
	var physical := _effect()
	physical.damage_type = GameplayEffectDefinition.DamageType.PHYSICAL
	for spell in [false, true]:
		_near(CombatMath.resolve_effect(physical, _context(source, spell), target), 100.0,
				"Physical damage ignores school Resistance for both Attacks and Spells")
		_near(CombatMath.resolve_effect(_effect(), _context(source, spell), target), 20.0,
				"Magic damage uses school Resistance for both Attacks and Spells")
	for id in RESISTANCES:
		target.set_base_value(id, -100.0)
	_near(CombatMath.resolve_effect(physical, _context(source), target), 100.0, "School vulnerabilities do not amplify Physical damage")
	for school in 5:
		_near(CombatMath.resolve_effect(_effect(school), _context(source), target), 200.0,
				"The negative Resistance floor doubles matching damage without healing")
	for level in [1, 30, 60]:
		source.level = level
		target.level = 61 - level
		_near(CombatMath.resolve_effect(_effect(), _context(source), target), 200.0,
				"Level changes Accuracy separately rather than changing the Resistance multiplier")


func _test_hybrid_payload_and_accuracy() -> void:
	var source := _actor()
	var target := _actor()
	target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, 50.0)
	target.set_base_value(CombatAttributes.Id.COLD_RESISTANCE, -100.0)
	target.set_base_value(CombatAttributes.Id.NECROTIC_RESISTANCE, 80.0)
	var physical := _effect()
	physical.damage_type = GameplayEffectDefinition.DamageType.PHYSICAL
	physical.get_damage_execution().amount = AmountDefinition.fixed(20.0)
	var payload: Array[GameplayEffectDefinition] = [
		physical, _effect(GameplayEffectDefinition.MagicSchool.FIRE, 100.0),
		_effect(GameplayEffectDefinition.MagicSchool.COLD, 40.0),
		_effect(GameplayEffectDefinition.MagicSchool.NECROTIC, 10.0), _buff(),
	]
	var tags := GameplayTagSet.new()
	var runtime := GameplayEffectRuntime.new(target, tags)
	var events: Array[Dictionary] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	var context := _context(source)
	var failed := runtime.apply_hit_payload(payload, context, 0.8)
	_check(failed.outcome == &"resist" and failed.applied_effects == 0, "One failed Accuracy check rejects every hybrid component")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 10000.0, "A failed hybrid hit applies no damage regardless of school")
	_check(events.is_empty() and runtime.active_count() == 0 and not tags.has_tag(&"Buff.ResistanceTest"),
			"Resistance does not allow attached effects to escape a failed Accuracy outcome")
	var result := runtime.apply_hit_payload(payload, context, 0.79)
	_check(result.outcome == &"hit" and result.applied_effects == 5, "One successful check authorizes all valid hybrid components")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 9848.0, "Physical20 plus Fire50 plus Cold80 plus Necrotic2 resolves per component")
	_near(result.hit_chance, 0.8, "School Resistance does not change the shared Accuracy probability")
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "Attached modifiers retain their full authored magnitude")
	var damage_count := 0
	for event in events:
		if event.type == &"damage":
			damage_count += 1
		_check(event.type != &"hit_outcome", "Per-component mitigation does not emit extra Accuracy outcomes")
	_check(damage_count == 4, "Hybrid delivery reports one actual damage event for each damage component")
	runtime.clear()


func _test_modifier_effects_are_not_mitigated() -> void:
	var source := _actor()
	var target := _actor()
	for id in RESISTANCES:
		target.set_base_value(id, 80.0)
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var buff := _buff()
	buff.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	buff.magic_school = GameplayEffectDefinition.MagicSchool.VOID
	var context := _context(source)
	var failed := runtime.apply_hit_payload([buff], context, 0.8)
	_check(failed.outcome == &"resist" and runtime.active_count() == 0, "Hostile modifier-only effects still require Accuracy")
	var result := runtime.apply_hit_payload([buff], context, 0.79)
	_check(result.outcome == &"hit", "High Resistance does not independently resist a successful hostile effect")
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "Resistance does not reduce modifier magnitude")
	runtime.advance(1.99)
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "Resistance does not shorten modifier duration")
	runtime.advance(0.01)
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 10.0, "The full authored modifier duration expires normally")
	_check(runtime.apply_effect(buff, context) > 0, "Explicit buff application remains separate from hostile hit resolution")
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "Explicit buffs retain full potency through capped defenses")
	runtime.clear()
	context.ability_tags.append("Ability.Beneficial")
	_check(runtime.apply_hit_payload([buff], context, 1.0).outcome == &"hit",
			"Beneficial ally modifier payloads still bypass hostile Accuracy")
	_near(target.get_value(CombatAttributes.Id.STRENGTH), 20.0, "Beneficial modifier potency is not attenuated by Resistance")
	runtime.clear()


func _test_damage_telemetry_and_overkill() -> void:
	var source := _actor()
	var target := _actor()
	target.set_base_value(CombatAttributes.Id.HEALTH, 30.0)
	target.set_base_value(CombatAttributes.Id.VOID_RESISTANCE, 50.0)
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	var effect := _effect(GameplayEffectDefinition.MagicSchool.VOID)
	var context := _context(source)
	var events: Array[Dictionary] = []
	runtime.combat_event.connect(func(event: Dictionary) -> void: events.append(event))
	_check(runtime.apply_hit_payload([effect], context, 1.0).outcome == &"resist",
			"A failed spell remains a full Accuracy failure before mitigation")
	_check(events.is_empty(), "Accuracy failure produces no damage or mitigation event")
	_check(runtime.apply_hit_payload([effect], context, 0.1).outcome == &"hit",
			"Partial damage mitigation remains a successful hit outcome")
	var damage_events: Array[Dictionary] = []
	for event in events:
		if event.type == &"damage":
			damage_events.append(event)
	_check(damage_events.size() == 1, "One delivered component reports one damage event")
	var event: Dictionary = damage_events[0]
	_near(event.raw_magnitude, 100.0, "Telemetry retains the unmitigated source magnitude")
	_near(event.resolved_amount, 50.0, "Resolved damage includes the matching Resistance")
	_near(event.amount, 30.0, "Displayed damage counts actual Health removed rather than overkill")
	_near(event.health_damage, 30.0, "Actual Health damage agrees with the damage amount")
	_near(event.resistance_percent, 50.0, "Telemetry reports applied Resistance in percentage points")
	_near(event.resistance_multiplier, 0.5, "Telemetry reports the matching damage multiplier")
	_check(event.magic_school == GameplayEffectDefinition.MagicSchool.VOID
			and event.resistance_attribute == CombatAttributes.Id.VOID_RESISTANCE,
			"Telemetry identifies the component's school and target defense")
	_near(target.get_value(CombatAttributes.Id.HEALTH), 0.0, "Mitigated overkill still kills without producing negative Health")


func _test_saved_fireball() -> void:
	var ability := COMBAT_DEFINITION_JSON.load_definition("res://examples/fireball/fireball.ability.json") as AbilityDefinition
	_check(ability != null and ability.execution is PhasedAbilityExecution,
			"The saved Fireball keeps its authored projectile execution")
	if ability == null or not ability.execution is PhasedAbilityExecution:
		return
	var execution := ability.execution as PhasedAbilityExecution
	_check(execution.get_effect_payload().size() == 1, "Fireball retains one direct payload without automatic ailments")
	if execution.get_effect_payload().size() != 1:
		return
	var effect := execution.get_effect_payload()[0]
	_check(effect.damage_type == GameplayEffectDefinition.DamageType.MAGIC
			and effect.magic_school == GameplayEffectDefinition.MagicSchool.FIRE,
			"Saved Fireball explicitly selects Fire Resistance without changing its Magic damage identity")
	# Preserve authored balance tuning while isolating the numeric Resistance contract.
	var numeric_effect := effect.duplicate_deep(Resource.DEEP_DUPLICATE_ALL) as GameplayEffectDefinition
	numeric_effect.get_damage_execution().amount = null
	numeric_effect.get_damage_execution().power_coefficient = 1.0
	var payload: Array[GameplayEffectDefinition] = [numeric_effect]
	var source := _actor()
	var target := _actor()
	var context := GameplayEffectContext.capture(source, GameplayTagSet.new(), ability.get_context_tags())
	var runtime := GameplayEffectRuntime.new(target, GameplayTagSet.new())
	for resistance: float in [0.0, 80.0, -100.0]:
		target.restore_resources()
		target.set_base_value(CombatAttributes.Id.FIRE_RESISTANCE, resistance)
		var before := target.get_value(CombatAttributes.Id.HEALTH)
		var result := runtime.apply_hit_payload(payload, context, 0.0)
		_check(result.outcome == &"hit" and result.applied_effects == 1,
				"A normalized saved Fireball payload remains one accepted direct effect")
		_near(before - target.get_value(CombatAttributes.Id.HEALTH), 20.0 * (1.0 - resistance / 100.0),
				"Zero-base, unit-Power Fireball fixture deals twenty/four/forty damage across Fire Resistance boundaries")
		_check(runtime.active_count() == 0, "Resistance does not add a retained Burn or other automatic effect")


func _test_serialized_school() -> void:
	var effect := _effect(GameplayEffectDefinition.MagicSchool.NECROTIC, 123.0)
	_check(ResourceSaver.save(effect, TEMP_EFFECT) == OK, "A Magic school is saved as editable effect data")
	var loaded := ResourceLoader.load(TEMP_EFFECT, "", ResourceLoader.CACHE_MODE_IGNORE) as GameplayEffectDefinition
	_check(loaded != null and loaded.damage_type == GameplayEffectDefinition.DamageType.MAGIC
			and loaded.magic_school == GameplayEffectDefinition.MagicSchool.NECROTIC,
			"School and existing damage-type identities survive Resource serialization")
	if loaded != null:
		_check(loaded.get_resistance_attribute() == CombatAttributes.Id.NECROTIC_RESISTANCE,
				"Reloaded Magic data still selects the correct Resistance")
	_check(DirAccess.remove_absolute(TEMP_EFFECT) == OK, "Temporary school fixture is removed")


func _near(actual: float, expected: float, label: String) -> void:
	_check(is_finite(actual) and absf(actual - expected) <= 1e-8 * maxf(1.0, absf(expected)),
			"%s: expected %.12f, got %.12f" % [label, expected, actual])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
