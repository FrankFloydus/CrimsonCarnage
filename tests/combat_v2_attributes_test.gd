extends SceneTree
## Combat 2.0 checks for governing attributes, flat foundations and independent More modifiers.

var _finesse := PackedStringArray(["Ability.Attack", "Weapon.Finesse"])
var _brutality := PackedStringArray(["Ability.Attack", "Weapon.Brutality"])
var _spell := PackedStringArray(["Ability.Spell", "Damage.Fire"])

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_primary_contexts()
	_test_flat_increased_and_more()
	_test_primary_gear_and_resource_capacities()
	_test_independent_stats_have_no_primary_or_level_contribution()
	_test_movement_speed_has_no_primary_or_level_contribution()
	_test_progression_budget()
	print("Combat 2.0 attribute checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_primary_contexts() -> void:
	var actor := _actor()
	actor.set_base_value(CombatAttributes.Id.STRENGTH, 30.0)
	actor.set_base_value(CombatAttributes.Id.DEXTERITY, 20.0)
	actor.set_base_value(CombatAttributes.Id.INTELLECT, 40.0)
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER, _brutality), 60.0,
			"Brutality uses Strength alone")
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER, _finesse), 40.0,
			"Finesse uses Dexterity alone")
	_close(actor.get_value(CombatAttributes.Id.ACCURACY_RATING, _brutality), 30.0,
			"Brutality accuracy uses Strength")
	_close(actor.get_value(CombatAttributes.Id.ACCURACY_RATING, _finesse), 20.0,
			"Finesse accuracy uses Dexterity")
	_close(actor.get_value(CombatAttributes.Id.ACCURACY_RATING, _spell), 40.0,
			"Spell accuracy uses Intellect")
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER, _spell), 80.0,
			"Starting Intellect is part of the flat Magic Power foundation")
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER), 0.0,
			"An unspecified action does not silently assume a weapon category")
	_close(actor.get_value(CombatAttributes.Id.ACCURACY_RATING), 0.0,
			"Generic accuracy excludes a guessed governing primary")
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER,
			PackedStringArray(["Damage.Physical"])), 0.0,
			"Damage school alone cannot select a weapon category")
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER,
			PackedStringArray(["Weapon.Finesse", "Weapon.Brutality"])), 0.0,
			"Conflicting categories cannot stack Strength and Dexterity")
	_close(actor.get_value(CombatAttributes.Id.ACCURACY_RATING,
			PackedStringArray(["Ability.Spell.Fire", "Weapon.Brutality"])), 40.0,
			"Casting keeps Intellect accuracy even with a physical weapon tag")
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER,
			PackedStringArray(["Weapon.Finesse.Sword"])), 40.0,
			"Weapon category matching supports descendant tags")
	_close(actor.get_value(CombatAttributes.Id.EVASION), 0.0,
			"Dexterity no longer supplies Evasion")
	_close(actor.get_value(CombatAttributes.Id.ATTACK_SPEED), 0.0,
			"Dexterity does not grant Attack Speed")
	_close(actor.get_value(CombatAttributes.Id.CAST_SPEED), 0.0,
			"Dexterity does not grant Cast Speed")
	actor.set_base_value(CombatAttributes.Id.STRENGTH, 1.0)
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER, _brutality), 2.0,
			"Power uses the full primary value, without a neutral-ten subtraction")
	actor.free()


func _test_flat_increased_and_more() -> void:
	var actor := _actor()
	var flat := _modifier(CombatAttributes.Id.MAGIC_POWER, 30.0)
	var increased_a := _modifier(CombatAttributes.Id.MAGIC_POWER, 20.0, AttributeModifier.Operation.ADD_PERCENT)
	var increased_b := _modifier(CombatAttributes.Id.MAGIC_POWER, 30.0, AttributeModifier.Operation.ADD_PERCENT)
	var more_a := _modifier(CombatAttributes.Id.MAGIC_POWER, 20.0, AttributeModifier.Operation.MORE_PERCENT)
	var more_b := _modifier(CombatAttributes.Id.MAGIC_POWER, 10.0, AttributeModifier.Operation.MORE_PERCENT)
	actor.set_modifiers(&"gear", [flat, increased_a, more_a])
	actor.set_modifiers(&"talent", [increased_b, more_b])
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 99.0,
			"Flat primary and gear power are both scaled by combined increased and independent More")
	actor.set_modifiers(&"gear", [more_a, increased_a, flat])
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 99.0,
			"Authored order does not turn flat gear into an unscaled final addition")
	actor.set_modifiers(&"talent", [increased_b, more_b, more_b])
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 108.9,
			"Separate More records multiply independently rather than adding percentages")
	actor.remove_modifiers(&"talent")
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 72.0,
			"Removing an owner removes only its increased and More contributions")
	more_a.value = 999.0
	flat.value = 999.0
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 72.0,
			"Registered modifier copies remain independent of authored resources")
	var scoped := _modifier(CombatAttributes.Id.PHYSICAL_POWER, 15.0)
	scoped.required_context_tags = PackedStringArray(["Weapon.Finesse"])
	actor.set_modifiers(&"precision", [scoped])
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER, _finesse), 35.0,
			"Scoped flat Physical Power joins the matching governing foundation")
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER, _brutality), 20.0,
			"Finesse power does not leak into Brutality")
	var zero_more := _modifier(CombatAttributes.Id.MAGIC_POWER, -100.0, AttributeModifier.Operation.MORE_PERCENT)
	actor.set_modifiers(&"suppression", [zero_more])
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 0.0,
			"A zero multiplier suppresses a nonnegative stat without flipping its sign")
	actor.remove_modifiers(&"suppression")
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 72.0,
			"Removing a zero multiplier restores the other owned contributions")
	actor.free()


func _test_primary_gear_and_resource_capacities() -> void:
	var actor := _actor()
	actor.set_modifiers(&"intellect", [_modifier(CombatAttributes.Id.INTELLECT, 5.0)])
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 30.0,
			"Flat Intellect gear supplies its Magic Power contribution")
	_close(actor.get_value(CombatAttributes.Id.MAX_MANA), 125.0,
			"The same Intellect gear supplies its independent Mana contribution")
	_close(actor.get_value(CombatAttributes.Id.MANA), 100.0,
			"Gaining Mana capacity does not restore the current pool")
	actor.set_modifiers(&"vitality", [_modifier(CombatAttributes.Id.VITALITY, 10.0)])
	_close(actor.get_value(CombatAttributes.Id.MAX_HEALTH), 300.0,
			"Vitality adds Health directly rather than a percentage of authored Health")
	_close(actor.get_value(CombatAttributes.Id.MAX_STAMINA), 150.0,
			"Vitality supplies Stamina")
	_close(actor.get_value(CombatAttributes.Id.CARRY_CAPACITY), 100.0,
			"Vitality does not supply Carry Capacity")
	actor.set_modifiers(&"strength", [_modifier(CombatAttributes.Id.STRENGTH, 10.0)])
	_close(actor.get_value(CombatAttributes.Id.CARRY_CAPACITY), 120.0,
			"Strength supplies Carry Capacity")
	_close(actor.get_value(CombatAttributes.Id.MAX_STAMINA), 150.0,
			"Strength does not also supply Stamina")
	actor.set_modifiers(&"capacity", [
		_modifier(CombatAttributes.Id.MAX_HEALTH, 50.0),
		_modifier(CombatAttributes.Id.MAX_HEALTH, 20.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(CombatAttributes.Id.MAX_HEALTH, 30.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(CombatAttributes.Id.MAX_HEALTH, 20.0, AttributeModifier.Operation.MORE_PERCENT)
	])
	_close(actor.get_value(CombatAttributes.Id.MAX_HEALTH), 630.0,
			"Base, Vitality and flat Health are all scaled once by capacity modifiers")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 200.0,
			"Multiple capacity modifiers cannot refill Health")
	actor.restore_resources()
	actor.remove_modifiers(&"capacity")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 300.0,
			"Losing capacity clamps current Health")
	actor.set_modifiers(&"capacity", [_modifier(CombatAttributes.Id.MAX_HEALTH, 50.0)])
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 300.0,
			"Reequipping flat capacity cannot create a swap-based heal")
	actor.free()


func _test_independent_stats_have_no_primary_or_level_contribution() -> void:
	var actor := _actor()
	var independent_stats := CombatAttributes.resistance_ids()
	independent_stats.append(CombatAttributes.Id.ARMOR)
	independent_stats.append(CombatAttributes.Id.ARMOR_PENETRATION)
	independent_stats.append(CombatAttributes.Id.CRITICAL_CHANCE)
	independent_stats.append(CombatAttributes.Id.CRITICAL_DAMAGE)
	independent_stats.append(CombatAttributes.Id.CARRIED_WEIGHT)
	for level in [1, 30, 60]:
		actor.level = level
		for amount: float in [0.0, 10.0, 128.0, 1000.0]:
			for primary: int in [CombatAttributes.Id.STRENGTH, CombatAttributes.Id.DEXTERITY,
					CombatAttributes.Id.INTELLECT, CombatAttributes.Id.VITALITY]:
				actor.set_base_value(primary, amount)
			for id: int in independent_stats:
				_close(actor.get_value(id), 0.0,
						"Primaries and levels do not contribute to %s" % CombatAttributes.display_name(id))
	actor.free()


func _test_movement_speed_has_no_primary_or_level_contribution() -> void:
	var actor := _actor()
	for level in [1, 30, 60]:
		actor.level = level
		for amount: float in [0.0, 10.0, 128.0, 1000.0]:
			for primary: int in [CombatAttributes.Id.STRENGTH, CombatAttributes.Id.DEXTERITY,
					CombatAttributes.Id.INTELLECT, CombatAttributes.Id.VITALITY]:
				actor.set_base_value(primary, amount)
			_close(actor.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 0.0,
					"Primary attributes and level do not automatically change Movement Speed")
	actor.free()


func _test_progression_budget() -> void:
	var actor := _actor()
	_check(actor.allocation_budget() == 0, "Level one starts with the four base primaries and no earned points")
	actor.level = 60
	_close(actor.get_value(CombatAttributes.Id.MAX_HEALTH), 200.0,
			"Level alone does not add a second hidden capacity progression")
	_check(actor.allocation_budget() == 118, "Fifty-nine level gains award 118 allocatable points")
	_check(actor.try_set_allocations(0, 0, 0, 118), "The full earned budget can be invested in Vitality")
	_close(actor.get_value(CombatAttributes.Id.VITALITY), 128.0, "Starting primary is separate from earned allocations")
	_close(actor.get_value(CombatAttributes.Id.MAX_HEALTH), 1380.0, "Full Vitality allocation supplies flat Health")
	_close(actor.get_value(CombatAttributes.Id.MAX_STAMINA), 690.0, "Full Vitality allocation supplies flat Stamina")
	actor.restore_resources()
	_check(actor.try_set_allocations(0, 0, 118, 0), "The same budget can be redistributed into Intellect")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 200.0, "Redistribution clamps lost Health capacity")
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 100.0, "Redistribution clamps lost Stamina capacity")
	_close(actor.get_value(CombatAttributes.Id.MANA), 100.0, "Redistribution does not refill newly gained Mana capacity")
	_close(actor.get_value(CombatAttributes.Id.MAX_MANA), 690.0, "Full Intellect allocation supplies flat Mana")
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 256.0, "Full Intellect allocation supplies flat Magic Power")
	actor.free()


func _actor() -> ActorAttributes:
	var actor := ActorAttributes.new()
	actor.initialize()
	return actor


func _modifier(id: int, amount: float,
		operation: AttributeModifier.Operation = AttributeModifier.Operation.ADD) -> AttributeModifier:
	var modifier := AttributeModifier.new()
	modifier.attribute = id
	modifier.value = amount
	modifier.operation = operation
	return modifier


func _close(actual: float, expected: float, label: String) -> void:
	_check(is_equal_approx(actual, expected), "%s: %.6f expected %.6f" % [label, actual, expected])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
