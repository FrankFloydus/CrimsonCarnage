extends SceneTree
## Independent Combat 2.0 power/coefficient expectations across primary values and levels.

var _checks: int = 0
var _failures: int = 0
var _random := RandomNumberGenerator.new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_random.seed = 5197341
	_test_flat_primary_damage()
	_test_seeded_damage()
	_test_target_health_independence()
	print("Combat 2.0 math checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _actor() -> ActorAttributes:
	return ActorAttributes.new()


func _test_flat_primary_damage() -> void:
	var source := _actor()
	var target := _actor()
	var physical := GameplayEffectDefinition.new()
	physical.base_magnitude = 100.0
	physical.power_coefficient = 0.5
	for strength: float in [0.0, 10.0, 50.0, 100.0, 138.0]:
		source.set_base_value(CombatAttributes.Id.STRENGTH, strength)
		var context := GameplayEffectContext.capture(source, GameplayTagSet.new(),
				PackedStringArray(["Ability.Attack", "Weapon.Brutality"]))
		_near(CombatMath.raw_effect_magnitude(physical, context), 100.0 + strength,
				"Strength contributes flat Power through the coefficient exactly once")
		source.set_base_value(CombatAttributes.Id.DEXTERITY, strength)
		context = GameplayEffectContext.capture(source, GameplayTagSet.new(),
				PackedStringArray(["Ability.Attack", "Weapon.Finesse"]))
		_near(CombatMath.resolve_effect(physical, context, target), 100.0 + strength,
				"Dexterity contributes the same flat Power to its governed attacks")
	var magic := GameplayEffectDefinition.new()
	magic.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	magic.base_magnitude = 10.0
	magic.power_coefficient = 1.5
	for intellect: float in [0.0, 10.0, 30.0, 100.0, 10000.0]:
		source.set_base_value(CombatAttributes.Id.INTELLECT, intellect)
		var context := GameplayEffectContext.capture(source, GameplayTagSet.new(),
				PackedStringArray(["Ability.Spell"]))
		_near(CombatMath.resolve_effect(magic, context, target), 10.0 + 3.0 * intellect,
				"Intellect grants two flat Magic Power per point before the spell coefficient")
	source.free()
	target.free()


func _test_seeded_damage() -> void:
	var source := _actor()
	var target := _actor()
	for iteration in 600:
		source.level = _random.randi_range(1, 60)
		target.level = _random.randi_range(1, 60)
		var primary := _random.randf_range(0.0, 1000.0)
		var base := _random.randf_range(0.0, 2000.0)
		var coefficient := _random.randf_range(0.0, 5.0)
		var tags := PackedStringArray()
		var effect := GameplayEffectDefinition.new()
		effect.base_magnitude = base
		effect.power_coefficient = coefficient
		match iteration % 3:
			0:
				source.set_base_value(CombatAttributes.Id.STRENGTH, primary)
				tags = PackedStringArray(["Ability.Attack", "Weapon.Brutality"])
			1:
				source.set_base_value(CombatAttributes.Id.DEXTERITY, primary)
				tags = PackedStringArray(["Ability.Attack", "Weapon.Finesse"])
			2:
				source.set_base_value(CombatAttributes.Id.INTELLECT, primary)
				tags = PackedStringArray(["Ability.Spell"])
				effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
		var context := GameplayEffectContext.capture(source, GameplayTagSet.new(), tags)
		var expected := base + 2.0 * primary * coefficient
		var result := CombatMath.resolve_effect_result(effect, context, target)
		_near(result.raw_magnitude, expected, "Seeded raw magnitude uses one governing Power contribution")
		_near(result.magnitude, expected, "Neutral Armor and Resistance preserve raw damage without level or critical multipliers")
	source.free()
	target.free()


func _test_target_health_independence() -> void:
	var source := _actor()
	var target := _actor()
	var effect := GameplayEffectDefinition.new()
	effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	effect.base_magnitude = 25.0
	effect.power_coefficient = 2.0
	var context := GameplayEffectContext.capture(source, GameplayTagSet.new(),
			PackedStringArray(["Ability.Spell"]))
	for capacity: float in [1.0, 200.0, 2000.0, 1000000.0]:
		target.set_base_value(CombatAttributes.Id.MAX_HEALTH, capacity)
		_near(CombatMath.resolve_effect(effect, context, target), 65.0,
				"Target maximum Health does not change the source's damage")
	for source_level in [1, 30, 60]:
		for target_level in [1, 30, 60]:
			source.level = source_level
			target.level = target_level
			_near(CombatMath.resolve_effect(effect, context, target), 65.0,
					"Level metadata does not restore the removed level-damage formula")
	source.level = 100
	_check(source.level == 60, "Character level remains capped at sixty")
	source.free()
	target.free()


func _near(actual: float, expected: float, label: String) -> void:
	_check(is_finite(actual) and absf(actual - expected) <= 1e-8 * maxf(1.0, absf(expected)),
			"%s: expected %.12f, got %.12f" % [label, expected, actual])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
