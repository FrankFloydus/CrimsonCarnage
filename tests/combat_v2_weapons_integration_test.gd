extends SceneTree
## Exercises the Combat 2.0 weapon/attribute boundary without desktop interaction.
## Checks physical scaling, source/weapon snapshots, modifier scopes and reserved effect tags.

const ATTRIBUTE_FIXTURE = preload("res://tests/attribute_fixture.gd")

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_governing_power()
	_test_cycle_scaling()
	_test_weapon_range_and_launch_snapshot()
	_test_detached_source_power()
	_test_effect_tags_cannot_change_governing_attributes()
	print("Combat 2.0 weapon integration checks: %d passed, %d failed." % [
			_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _actor() -> ActorAttributes:
	return ATTRIBUTE_FIXTURE.new_attributes()


func _weapon(kind: WeaponDefinition.Kind, minimum: float, maximum: float,
		cycle: float) -> WeaponDefinition:
	var weapon := WeaponDefinition.new()
	weapon.kind = kind
	weapon.physical_damage_min = minimum
	weapon.physical_damage_max = maximum
	weapon.base_attack_cycle = cycle
	return weapon


func _effect() -> GameplayEffectDefinition:
	var effect := GameplayEffectDefinition.new()
	effect.executions = [GameplayEffectDamageExecution.new()]
	effect.use_weapon_damage = true
	return effect


func _context(source: ActorAttributes, weapon: WeaponDefinition) -> GameplayEffectContext:
	var ability := AbilityDefinition.new()
	ability.ability_tags = PackedStringArray(["Ability.Attack"])
	var context := GameplayEffectContext.capture(source, GameplayTagSet.new(),
			ability.get_context_tags())
	context.bind_weapon(weapon)
	return context


func _test_governing_power() -> void:
	var source := _actor()
	source.set_base_value(CombatAttributes.Id.STRENGTH, 30.0)
	source.set_base_value(CombatAttributes.Id.DEXTERITY, 60.0)
	source.set_base_value(CombatAttributes.Id.INTELLECT, 500.0)
	var effect := _effect()
	for kind: int in [WeaponDefinition.Kind.DAGGER_ONE_HAND, WeaponDefinition.Kind.SWORD_ONE_HAND,
			WeaponDefinition.Kind.SWORD_TWO_HAND,
			WeaponDefinition.Kind.MACE_ONE_HAND, WeaponDefinition.Kind.AXE_ONE_HAND,
			WeaponDefinition.Kind.MACE_TWO_HAND, WeaponDefinition.Kind.AXE_TWO_HAND]:
		var weapon := _weapon(kind, 40.0, 40.0, 1.25)
		var context := _context(source, weapon)
		var governing := 60.0 if kind <= WeaponDefinition.Kind.SWORD_TWO_HAND else 30.0
		_near(CombatMath.raw_effect_magnitude(effect, context), 40.0 + governing * 2.0 * 1.25,
				"Weapon damage uses exactly one governing primary, without Intellect or a Strength multiplier")
		_near(source.get_value(CombatAttributes.Id.ACCURACY_RATING, context.ability_tags), governing,
				"Weapon accuracy uses its governing primary")
	var power := AttributeModifier.new()
	power.attribute = CombatAttributes.Id.PHYSICAL_POWER
	power.value = 20.0
	var increased := power.copy()
	increased.operation = AttributeModifier.Operation.ADD_PERCENT
	increased.value = 50.0
	var more := power.copy()
	more.operation = AttributeModifier.Operation.MORE_PERCENT
	more.value = 20.0
	source.set_modifiers(&"weapon_power", [power, increased, more])
	var sword := _weapon(WeaponDefinition.Kind.SWORD_ONE_HAND, 40.0, 40.0, 1.25)
	_near(CombatMath.raw_effect_magnitude(effect, _context(source, sword)),
			40.0 + (120.0 + 20.0) * 1.5 * 1.2 * 1.25,
			"Flat, increased and more Physical Power apply once before weapon conversion")
	source.free()


func _test_cycle_scaling() -> void:
	var source := _actor()
	var effect := _effect()
	for cycle: float in [0.5, 1.0, 2.0]:
		var weapon := _weapon(WeaponDefinition.Kind.SWORD_ONE_HAND, 0.0, 0.0, cycle)
		var context := _context(source, weapon)
		var damage := CombatMath.raw_effect_magnitude(effect, context)
		_near(damage, 20.0 * cycle, "Base cycle determines the Physical Power coefficient")
		_near(damage / cycle, 20.0, "Power supplies equal base DPS across weapon cycles")
	source.free()


func _test_weapon_range_and_launch_snapshot() -> void:
	var source := _actor()
	var weapon := _weapon(WeaponDefinition.Kind.SWORD_ONE_HAND, 10.0, 20.0, 1.0)
	var context := _context(source, weapon)
	var effect := _effect()
	weapon.physical_damage_min = 1000.0
	weapon.physical_damage_max = 2000.0
	weapon.base_attack_cycle = 10.0
	_near(context.weapon_power_coefficient, 1.0,
			"Launched context snapshots the authored coefficient")
	var distinct: Dictionary = {}
	for iteration in 128:
		var hit := context.duplicate_for_hit()
		var first := CombatMath.raw_effect_magnitude(effect, hit)
		_check(first >= 30.0 and first <= 40.0,
				"Weapon roll remains inside its launch-time range after the resource changes")
		_near(CombatMath.raw_effect_magnitude(effect, hit), first,
				"Repeated resolution of one Hit uses the same weapon damage roll")
		_near(hit.get_weapon_base_damage() + 20.0, first,
				"The cached base roll and scaled power describe the same Hit")
		distinct[first] = true
	_check(distinct.size() > 1, "Separate Hits sample the weapon's min/max range")
	source.free()


func _test_detached_source_power() -> void:
	var source := _actor()
	source.set_base_value(CombatAttributes.Id.DEXTERITY, 30.0)
	var modifier := AttributeModifier.new()
	modifier.attribute = CombatAttributes.Id.PHYSICAL_POWER
	modifier.value = 15.0
	modifier.required_context_tags = PackedStringArray(["Damage.Physical"])
	source.set_modifiers(&"physical_scope", [modifier])
	var weapon := _weapon(WeaponDefinition.Kind.SWORD_ONE_HAND, 25.0, 25.0, 1.0)
	var context := _context(source, weapon)
	var effect := _effect()
	context.prime_effects([effect])
	source.set_base_value(CombatAttributes.Id.DEXTERITY, 100.0)
	source.remove_modifiers(&"physical_scope")
	source.free()
	_near(CombatMath.raw_effect_magnitude(effect, context), 100.0,
			"Detached physical projectile keeps scoped launch Power60+15 and weapon25")
	_near(context.get_source_value(CombatAttributes.Id.ACCURACY_RATING, context.ability_tags), 30.0,
			"Detached weapon retains its launch-time governing accuracy")
	var hit := context.duplicate_for_hit()
	_near(CombatMath.raw_effect_magnitude(effect, hit), 100.0,
			"Duplicating a detached Hit preserves weapon and source snapshots")


func _near(actual: float, expected: float, label: String) -> void:
	_check(is_finite(actual) and absf(actual - expected) < 0.00001,
			"%s (%.8f / %.8f)" % [label, actual, expected])


func _test_effect_tags_cannot_change_governing_attributes() -> void:
	var source := _actor()
	source.set_base_value(CombatAttributes.Id.STRENGTH, 100.0)
	source.set_base_value(CombatAttributes.Id.DEXTERITY, 30.0)
	var weapon := _weapon(WeaponDefinition.Kind.SWORD_ONE_HAND, 20.0, 20.0, 1.0)
	var context := _context(source, weapon)
	var effect := _effect()
	for tag: String in ["Ability", "Ability.Spell", "Ability.Attack.Custom", "Weapon",
			"Weapon.Brutality", "Weapon.Finesse.Override"]:
		effect.damage_tags = PackedStringArray([tag])
		_check(effect.get_validation_error() == &"Effect.ReservedContextTag",
				"Effect tags cannot replace the ability's delivery or weapon classification")
		_near(CombatMath.raw_effect_magnitude(effect, context), 0.0,
				"A forged governing tag rejects damage instead of losing Dexterity or borrowing Strength")
		effect.damage_tags = PackedStringArray(["Damage.Contract.Custom"])
		_near(CombatMath.raw_effect_magnitude(effect, context), 80.0,
				"Valid custom effect scopes preserve the selected weapon's Dexterity contribution")
	_near(source.get_value(CombatAttributes.Id.PHYSICAL_POWER, context.ability_tags), 60.0,
			"Rejected effect tags never mutate the source's governing Power")
	_check(context.ability_tags.has("Weapon.Finesse")
			and not context.ability_tags.has("Weapon.Brutality")
			and not context.ability_tags.has("Ability.Spell"),
			"Effect authoring never changes the captured action context")
	source.free()


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
