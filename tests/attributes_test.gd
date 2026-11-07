extends SceneTree
## Combat 2.0 resource bounds, ownership, modifier order and point redistribution checks.

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_baselines_and_retired_catalogue()
	_test_capacity_and_current_values()
	_test_carried_weight_bounds_and_modifiers()
	_test_scoped_modifiers_and_ownership()
	_test_signed_resistance_bounds_and_modifiers()
	_test_armor_rating_modifiers_and_bounds()
	_test_armor_penetration_modifiers_and_bounds()
	_test_critical_attribute_units_and_modifiers()
	_test_movement_speed_units_and_modifiers()
	_test_action_speed_percentages()
	_test_damage_accounting()
	_test_validated_allocation()
	_test_tags()
	_test_automatic_recovery()
	print("Attribute checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_baselines_and_retired_catalogue() -> void:
	var actor := _actor()
	_close(actor.get_value(CombatAttributes.Id.MAX_HEALTH), 200.0, "Starting Health includes Vitality")
	_close(actor.get_value(CombatAttributes.Id.MAX_STAMINA), 100.0, "Starting Stamina includes Vitality")
	_close(actor.get_value(CombatAttributes.Id.MAX_MANA), 100.0, "Starting Mana includes Intellect")
	_close(actor.get_value(CombatAttributes.Id.CARRY_CAPACITY), 100.0, "Starting capacity includes Strength")
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 20.0, "Starting Intellect supplies Magic Power")
	_check(CombatAttributes.all_ids().size() == 30, "Exactly thirty attributes are active")
	_check(CombatAttributes.current_ids() == [0, 2, 4], "Only Health, Stamina and Mana are current pools")
	for id: int in range(57):
		if id in CombatAttributes.ACTIVE_IDS:
			continue
		_check(not CombatAttributes.is_active(id), "Legacy slot remains inactive: %d" % id)
		actor.set_base_value(id, 1000.0)
		actor.set_modifiers(&"legacy", [_modifier(id, 1000.0)])
		_close(actor.get_value(id), 0.0, "Legacy attributes cannot regain behavior: %d" % id)
		_close(actor.get_base_value(id), 0.0, "Legacy attributes have no editable runtime base: %d" % id)
	_check(not actor.has_method("restore_consumable_health"), "No legacy consumable restoration API remains")
	_check(not actor.has_method("get_encumbrance_multiplier"), "No old encumbrance calculation remains")
	_check(not actor.has_method("capture_critical_query"), "No old critical query pipeline remains")
	actor.free()


func _test_capacity_and_current_values() -> void:
	var actor := _actor()
	_close(actor.modify_current(CombatAttributes.Id.HEALTH, -20.0), -20.0,
			"Resource spending returns its actual delta")
	var capacity: Array[AttributeModifier] = [
		_modifier(CombatAttributes.Id.MAX_HEALTH, 50.0),
		_modifier(CombatAttributes.Id.MAX_HEALTH, 50.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(CombatAttributes.Id.MAX_HEALTH, 20.0, AttributeModifier.Operation.MORE_PERCENT),
	]
	actor.set_modifiers(&"capacity", capacity)
	_close(actor.get_value(CombatAttributes.Id.MAX_HEALTH), 450.0,
			"Base, primary and flat capacity scale before increased and More")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 180.0, "Increasing capacity does not restore Health")
	actor.modify_current(CombatAttributes.Id.HEALTH, 1000.0)
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 450.0, "Current Health is bounded by capacity")
	actor.remove_modifiers(&"capacity")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 200.0, "Losing capacity clamps the current pool")
	actor.set_modifiers(&"capacity", capacity)
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 200.0, "Capacity swapping cannot create restoration")
	actor.set_base_value(CombatAttributes.Id.MAX_HEALTH, 200.0)
	actor.allocated_vitality = 100
	_close(actor.get_value(CombatAttributes.Id.MAX_HEALTH), 450.0,
			"Set Base intentionally replaces the complete derived foundation")
	actor.restore_resources()
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 450.0, "An explicit test reset restores resources")
	for id: int in [CombatAttributes.Id.MAX_HEALTH, CombatAttributes.Id.MAX_STAMINA,
			CombatAttributes.Id.MAX_MANA, CombatAttributes.Id.CARRY_CAPACITY]:
		actor.set_base_value(id, 1000000.0)
		_check(actor.get_value(id) >= 1000000.0, "Capacity has no upper cap: %d" % id)
		actor.set_base_value(id, -1000000.0)
		_close(actor.get_value(id), 1.0, "Capacity retains a positive minimum: %d" % id)
	actor.free()


func _test_carried_weight_bounds_and_modifiers() -> void:
	var actor := _actor()
	var id := CombatAttributes.Id.CARRIED_WEIGHT
	_close(actor.get_value(id), 0.0, "Actors start without carried weight")
	_check(not CombatAttributes.is_current_resource(id) and not CombatAttributes.uses_percentage_units(id),
			"Carried Weight uses weight units and remains independent of resource pools")
	actor.set_base_value(id, 160.0)
	actor.set_modifiers(&"load", [
		_modifier(id, 40.0),
		_modifier(id, 50.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(id, 20.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	_close(actor.get_value(id), 360.0, "Flat, increased and More modifiers can increase weight beyond capacity")
	_close(actor.get_value(CombatAttributes.Id.CARRY_CAPACITY), 100.0,
			"Carried Weight modifiers leave Carry Capacity independent")
	actor.remove_modifiers(&"load")
	_close(actor.get_value(id), 160.0, "Removing load modifiers restores the actual base weight")
	actor.set_base_value(id, 1000000.0)
	_close(actor.get_value(id), 1000000.0, "Carried Weight remains uncapped")
	actor.set_modifiers(&"load", [_modifier(id, -1000001.0)])
	_close(actor.get_value(id), 0.0, "Negative final load clamps to zero after weight adjustments")
	actor.free()


func _test_scoped_modifiers_and_ownership() -> void:
	var actor := _actor()
	var flat := _modifier(CombatAttributes.Id.MAGIC_POWER, 30.0)
	var increased := _modifier(CombatAttributes.Id.MAGIC_POWER, 50.0,
			AttributeModifier.Operation.ADD_PERCENT)
	var more := _modifier(CombatAttributes.Id.MAGIC_POWER, 20.0,
			AttributeModifier.Operation.MORE_PERCENT)
	actor.set_modifiers(&"gear", [flat, increased])
	actor.set_modifiers(&"buff", [more])
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 90.0,
			"Owned sources share a flat-increased-More calculation")
	flat.value = 900.0
	more.value = 900.0
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 90.0,
			"Runtime modifiers are immutable copies of authored resources")
	actor.remove_modifiers(&"gear")
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 24.0,
			"Removing one owner preserves another owner's modifier")
	var scoped := _modifier(CombatAttributes.Id.PHYSICAL_POWER, 10.0)
	scoped.required_context_tags = PackedStringArray(["Weapon.Finesse"])
	scoped.excluded_context_tags = PackedStringArray(["Ability.Disabled"])
	actor.set_modifiers(&"finesse", [scoped])
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER,
			PackedStringArray(["Weapon.Finesse.Sword"])), 30.0,
			"Parent scopes match descendant weapon categories")
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER,
			PackedStringArray(["Weapon.Finesse", "Ability.Disabled.Child"])), 20.0,
			"Excluded parent scopes suppress only their modifier")
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER,
			PackedStringArray(["Weapon.Brutality"])), 20.0,
			"Finesse bonuses do not leak into Brutality attacks")
	var replacement := _modifier(CombatAttributes.Id.MAGIC_POWER, 5.0)
	actor.set_modifiers(&"buff", [replacement])
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 25.0,
			"Replacing an owner replaces its prior records rather than accumulating them")
	actor.set_modifiers(&"invalid", [_modifier(CombatAttributes.Id.MAGIC_POWER, INF)])
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 25.0,
			"Nonfinite modifier data cannot poison the attribute calculation")
	actor.free()


func _test_signed_resistance_bounds_and_modifiers() -> void:
	var actor := _actor()
	_check(CombatAttributes.resistance_ids() == [19, 20, 21, 22, 44],
			"The five resistances retain their original identities")
	var detached_ids := CombatAttributes.resistance_ids()
	detached_ids.clear()
	_check(CombatAttributes.resistance_ids().size() == 5, "Inspection cannot mutate the resistance catalogue")
	for id: int in CombatAttributes.resistance_ids():
		_check(CombatAttributes.is_resistance(id), "Resistance classification includes its canonical ID")
		_close(actor.get_value(id), 0.0, "Resistance starts neutral")
		actor.set_base_value(id, 250.0)
		_close(actor.get_base_value(id), 250.0, "Over-cap authored resistance remains in its raw foundation")
		_close(actor.get_value(id), 80.0, "Positive Resistance caps at eighty percent")
		actor.set_base_value(id, -250.0)
		_close(actor.get_base_value(id), -250.0, "Negative authored Resistance remains signed")
		_close(actor.get_value(id), -100.0, "Vulnerability is bounded at negative one hundred percent")
		actor.set_base_value(id, 0.0)
		actor.set_modifiers(&"resistance_gear", [_modifier(id, 110.0)])
		actor.set_modifiers(&"resistance_debuff", [_modifier(id, -50.0)])
		_close(actor.get_value(id), 60.0, "Clamp follows aggregation so over-cap resistance can offset a debuff")
		actor.remove_modifiers(&"resistance_debuff")
		_close(actor.get_value(id), 80.0, "Removing a debuff exposes the final positive cap")
		actor.remove_modifiers(&"resistance_gear")
		_close(actor.get_value(id), 0.0, "Removing the gear contribution restores neutrality")
		actor.set_modifiers(&"resistance_formula", [
			_modifier(id, 40.0),
			_modifier(id, 50.0, AttributeModifier.Operation.ADD_PERCENT),
			_modifier(id, 20.0, AttributeModifier.Operation.MORE_PERCENT),
		])
		_close(actor.get_value(id), 72.0, "Resistance uses flat then increased then More before its cap")
		actor.set_modifiers(&"resistance_formula", [
			_modifier(id, -40.0),
			_modifier(id, 50.0, AttributeModifier.Operation.ADD_PERCENT),
			_modifier(id, 20.0, AttributeModifier.Operation.MORE_PERCENT),
		])
		_close(actor.get_value(id), -72.0, "Relative modifiers preserve a negative resistance foundation")
		actor.set_modifiers(&"resistance_formula", [
			_modifier(id, -25.0, AttributeModifier.Operation.SET_BASE),
			_modifier(id, 5.0),
		])
		_close(actor.get_value(id), -20.0, "Set Base resistance remains signed before ordinary flat bonuses")
		actor.remove_modifiers(&"resistance_formula")
		var scoped := _modifier(id, 60.0)
		scoped.required_context_tags = PackedStringArray(["Ability.Spell"])
		scoped.excluded_context_tags = PackedStringArray(["Damage.Disabled"])
		actor.set_modifiers(&"resistance_scope", [scoped])
		_close(actor.get_value(id, PackedStringArray(["Ability.Spell.Fire"])), 60.0,
				"Resistance modifiers can target an incoming action context")
		_close(actor.get_value(id, PackedStringArray(["Ability.Attack"])), 0.0,
				"Scoped resistance does not leak into unrelated attacks")
		_close(actor.get_value(id, PackedStringArray(["Ability.Spell", "Damage.Disabled.Fire"])), 0.0,
				"Excluded resistance scopes use ordinary parent matching")
		actor.remove_modifiers(&"resistance_scope")
	_check(not CombatAttributes.is_resistance(CombatAttributes.Id.PHYSICAL_POWER),
			"Ordinary combat stats do not acquire signed resistance behavior")
	actor.set_base_value(CombatAttributes.Id.PHYSICAL_POWER, -50.0)
	_close(actor.get_value(CombatAttributes.Id.PHYSICAL_POWER), 0.0, "Physical Power keeps its nonnegative minimum")
	actor.free()


func _test_armor_rating_modifiers_and_bounds() -> void:
	var actor := _actor()
	var id := CombatAttributes.Id.ARMOR
	_close(actor.get_value(id), 0.0, "Armor starts at zero rating")
	_check(not CombatAttributes.is_resistance(id), "Armor remains a rating rather than a signed resistance percentage")
	actor.set_base_value(id, -100.0)
	_close(actor.get_value(id), 0.0, "Armor has a nonnegative minimum")
	actor.set_base_value(id, 1000000000.0)
	_close(actor.get_value(id), 1000000000.0, "Only Armor reduction is capped, not its rating")
	actor.set_base_value(id, 0.0)
	actor.set_modifiers(&"armor_gear", [_modifier(id, 1500.0)])
	actor.set_modifiers(&"armor_debuff", [_modifier(id, -1000.0)])
	_close(actor.get_value(id), 500.0, "Armor above the reduction threshold remains available to offset a debuff")
	actor.remove_modifiers(&"armor_debuff")
	_close(actor.get_value(id), 1500.0, "Removing a debuff restores the full uncapped rating")
	actor.set_modifiers(&"armor_scaling", [
		_modifier(id, 50.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(id, 20.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	_close(actor.get_value(id), 2700.0, "Armor uses the shared flat-increased-More calculation")
	actor.remove_modifiers(&"armor_gear")
	_close(actor.get_value(id), 0.0, "Relative Armor bonuses do not create a flat foundation")
	actor.remove_modifiers(&"armor_scaling")
	var scoped := _modifier(id, 750.0)
	scoped.required_context_tags = PackedStringArray(["Ability.Attack"])
	actor.set_modifiers(&"armor_scope", [scoped])
	_close(actor.get_value(id, PackedStringArray(["Ability.Attack.Custom"])), 750.0,
			"Armor modifiers support incoming action scopes")
	_close(actor.get_value(id, PackedStringArray(["Ability.Spell"])), 0.0,
			"Scoped Armor does not leak to unrelated incoming actions")
	actor.remove_modifiers(&"armor_scope")
	actor.set_modifiers(&"armor_base", [
		_modifier(id, 1250.0, AttributeModifier.Operation.SET_BASE),
		_modifier(id, 100.0),
	])
	_close(actor.get_value(id), 1350.0, "Armor Set Base preserves later flat contributions")
	actor.remove_modifiers(&"armor_base")
	_close(actor.get_value(id), 0.0, "Removing owned Armor restores its neutral foundation")
	actor.free()


func _test_armor_penetration_modifiers_and_bounds() -> void:
	var actor := _actor()
	var id := CombatAttributes.Id.ARMOR_PENETRATION
	_close(actor.get_value(id), 0.0, "Armor Penetration starts at zero percent")
	_check(not CombatAttributes.is_resistance(id), "Outgoing Armor Penetration is not a target school resistance")
	_check(CombatAttributes.uses_percentage_units(id) and not CombatAttributes.uses_percentage_units(CombatAttributes.Id.ARMOR),
			"Armor Penetration uses percentage units while Armor remains a rating")
	actor.set_base_value(id, -100.0)
	_close(actor.get_value(id), 0.0, "Negative Armor Penetration cannot amplify target Armor")
	actor.set_base_value(id, 250.0)
	_close(actor.get_value(id), 100.0, "Armor Penetration caps at one hundred percent")
	_close(actor.get_base_value(id), 250.0, "Raw penetration remains available before final clamping")
	actor.set_base_value(id, 0.0)
	actor.set_modifiers(&"penetration_gear", [_modifier(id, 150.0)])
	actor.set_modifiers(&"penetration_debuff", [_modifier(id, -80.0)])
	_close(actor.get_value(id), 70.0, "Penetration modifiers aggregate before the cap, retaining over-cap investment")
	actor.remove_modifiers(&"penetration_debuff")
	_close(actor.get_value(id), 100.0, "Removing a debuff restores capped penetration")
	actor.remove_modifiers(&"penetration_gear")
	actor.set_modifiers(&"penetration_formula", [
		_modifier(id, 40.0),
		_modifier(id, 50.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(id, 20.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	_close(actor.get_value(id), 72.0, "Penetration uses flat points, combined increased and independent More")
	actor.set_modifiers(&"penetration_formula", [
		_modifier(id, 30.0, AttributeModifier.Operation.SET_BASE),
		_modifier(id, 10.0),
	])
	_close(actor.get_value(id), 40.0, "Penetration Set Base preserves ordinary flat bonuses")
	actor.remove_modifiers(&"penetration_formula")
	var scoped := _modifier(id, 60.0)
	scoped.required_context_tags = PackedStringArray(["Ability.Attack"])
	scoped.excluded_context_tags = PackedStringArray(["Damage.Disabled"])
	actor.set_modifiers(&"penetration_scope", [scoped])
	_close(actor.get_value(id, PackedStringArray(["Ability.Attack.Custom"])), 60.0,
			"Penetration can be scoped to outgoing attack contexts")
	_close(actor.get_value(id, PackedStringArray(["Ability.Spell"])), 0.0,
			"An attack-scoped penetration bonus does not leak into spells")
	_close(actor.get_value(id, PackedStringArray(["Ability.Attack", "Damage.Disabled.Physical"])), 0.0,
			"Excluded penetration scopes retain normal parent matching")
	actor.remove_modifiers(&"penetration_scope")
	_close(actor.get_value(id), 0.0, "Removing penetration investment restores the zero base")
	actor.free()


func _test_critical_attribute_units_and_modifiers() -> void:
	var actor := _actor()
	var chance := CombatAttributes.Id.CRITICAL_CHANCE
	var damage := CombatAttributes.Id.CRITICAL_DAMAGE
	_close(actor.get_value(chance), 0.0, "Critical Chance starts at zero percent")
	_close(actor.get_value(damage), 0.0, "Critical Damage starts with zero bonus percentage points")
	actor.set_base_value(chance, -50.0)
	_close(actor.get_value(chance), 0.0, "Critical Chance has a zero minimum")
	actor.set_base_value(chance, 250.0)
	_close(actor.get_value(chance), 100.0, "Critical Chance can reach one hundred percent and caps there")
	actor.set_base_value(damage, -50.0)
	_close(actor.get_value(damage), 0.0, "Critical Damage bonus has a zero minimum")
	actor.set_base_value(damage, 1000000000.0)
	_close(actor.get_value(damage), 1000000000.0, "Critical Damage bonus remains uncapped")
	actor.set_base_value(chance, 0.0)
	actor.set_base_value(damage, 0.0)
	actor.set_modifiers(&"crit_percent_only", [
		_modifier(chance, 50.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(damage, 20.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	_close(actor.get_value(chance), 0.0, "Increased Critical Chance needs a nonzero flat foundation")
	_close(actor.get_value(damage), 0.0, "More Critical Damage scales its bonus rather than the base multiplier")
	actor.remove_modifiers(&"crit_percent_only")
	actor.set_modifiers(&"critical_gear", [
		_modifier(chance, 40.0),
		_modifier(chance, 50.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(chance, 20.0, AttributeModifier.Operation.MORE_PERCENT),
		_modifier(damage, 50.0),
		_modifier(damage, 50.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(damage, 20.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	_close(actor.get_value(chance), 72.0, "Critical Chance uses flat percentage points, increased and More")
	_close(actor.get_value(damage), 90.0, "Critical Damage modifiers act on bonus percentage points")
	actor.remove_modifiers(&"critical_gear")
	actor.set_modifiers(&"critical_overcap", [_modifier(chance, 150.0)])
	actor.set_modifiers(&"critical_debuff", [_modifier(chance, -80.0)])
	_close(actor.get_value(chance), 70.0, "Critical Chance aggregates raw over-cap sources before applying its cap")
	actor.remove_modifiers(&"critical_debuff")
	_close(actor.get_value(chance), 100.0, "Removing a debuff restores the capped critical chance")
	actor.remove_modifiers(&"critical_overcap")
	actor.set_modifiers(&"critical_base", [
		_modifier(chance, 30.0, AttributeModifier.Operation.SET_BASE),
		_modifier(chance, 5.0),
		_modifier(damage, 250.0, AttributeModifier.Operation.SET_BASE),
		_modifier(damage, 50.0),
	])
	_close(actor.get_value(chance), 35.0, "Critical Chance Set Base preserves ordinary flat bonuses")
	_close(actor.get_value(damage), 300.0, "Critical Damage Set Base remains an uncapped bonus")
	actor.remove_modifiers(&"critical_base")
	var scoped := _modifier(chance, 60.0)
	scoped.required_context_tags = PackedStringArray(["Weapon.Finesse"])
	scoped.excluded_context_tags = PackedStringArray(["Ability.Disabled"])
	actor.set_modifiers(&"critical_scope", [scoped])
	_close(actor.get_value(chance, PackedStringArray(["Weapon.Finesse.Sword"])), 60.0,
			"Critical bonuses use ordinary action scope matching")
	_close(actor.get_value(chance, PackedStringArray(["Weapon.Brutality"])), 0.0,
			"A Finesse critical bonus does not leak to Brutality")
	_close(actor.get_value(chance, PackedStringArray(["Weapon.Finesse", "Ability.Disabled.Spell"])), 0.0,
			"Excluded critical scopes suppress only their modifier")
	actor.remove_modifiers(&"critical_scope")
	_close(actor.get_value(chance), 0.0, "Removing critical investment restores its neutral chance")
	_close(actor.get_value(damage), 0.0, "Removing critical investment restores its zero damage bonus")
	actor.free()


func _test_movement_speed_units_and_modifiers() -> void:
	var actor := _actor()
	var id := CombatAttributes.Id.MOVEMENT_SPEED
	_close(actor.get_value(id), 0.0, "Movement Speed starts at zero bonus to normal speed")
	_check(CombatAttributes.uses_percentage_units(id), "Movement Speed uses bonus percentage-point units")
	_check(not CombatAttributes.is_active(27), "The old percentage Movement Speed identity remains retired")
	actor.set_modifiers(&"movement_gear", [_modifier(id, 1.0)])
	_close(actor.get_value(id), 1.0, "One flat Movement Speed point grants one percent faster movement")
	actor.remove_modifiers(&"movement_gear")
	actor.set_modifiers(&"movement_talent", [_modifier(id, 20.0, AttributeModifier.Operation.ADD_PERCENT)])
	_close(actor.get_value(id), 0.0, "An increased modifier cannot create a bonus from zero")
	actor.set_modifiers(&"movement_gear", [_modifier(id, 20.0)])
	_close(actor.get_value(id), 24.0, "Twenty percent increased scales a twenty-point movement bonus to twenty-four")
	actor.set_modifiers(&"movement_talent", [
		_modifier(id, 20.0, AttributeModifier.Operation.ADD_PERCENT),
		_modifier(id, 25.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	_close(actor.get_value(id), 25.0, "The movement bonus caps after flat, combined increased and independent More")
	actor.remove_modifiers(&"movement_gear")
	_close(actor.get_value(id), 0.0, "Removing the flat bonus leaves zero even while its multipliers remain")
	actor.remove_modifiers(&"movement_talent")
	_close(actor.get_value(id), 0.0, "Removing movement investment restores the authored zero bonus")
	actor.set_modifiers(&"movement_override", [
		_modifier(id, 50.0, AttributeModifier.Operation.SET_BASE),
		_modifier(id, 0.5),
	])
	_close(actor.get_value(id), 25.0, "An over-cap Set Base movement bonus applies the final upper bound")
	actor.set_modifiers(&"movement_debuff", [_modifier(id, -30.5)])
	_close(actor.get_value(id), 20.0, "A debuff uses the full Set Base value and flat additions before the cap")
	actor.remove_modifiers(&"movement_debuff")
	_close(actor.get_value(id), 25.0, "Removing a debuff exposes the retained over-cap Set Base bonus again")
	actor.remove_modifiers(&"movement_override")
	actor.set_modifiers(&"movement_gear", [_modifier(id, 30.0)])
	_close(actor.get_value(id), 25.0, "Flat movement bonuses above twenty-five use the effective upper cap")
	actor.remove_modifiers(&"movement_gear")
	_close(actor.get_value(id), 0.0, "Removing an over-cap flat movement buff restores the zero bonus")
	actor.set_modifiers(&"movement_gear", [
		_modifier(id, 20.0),
		_modifier(id, 50.0, AttributeModifier.Operation.ADD_PERCENT),
	])
	_close(actor.get_value(id), 25.0, "Increased modifiers cannot raise the effective movement bonus above twenty-five")
	actor.set_modifiers(&"movement_gear", [
		_modifier(id, 20.0),
		_modifier(id, 50.0, AttributeModifier.Operation.MORE_PERCENT),
	])
	_close(actor.get_value(id), 25.0, "More modifiers cannot raise the effective movement bonus above twenty-five")
	actor.remove_modifiers(&"movement_gear")
	actor.set_base_value(id, -20.0)
	_close(actor.get_value(id), -20.0, "Movement Speed preserves a negative bonus for slowing")
	actor.set_modifiers(&"movement_talent", [_modifier(id, 20.0, AttributeModifier.Operation.ADD_PERCENT)])
	_close(actor.get_value(id), -24.0, "Increased modifiers multiply a signed negative movement bonus normally")
	actor.remove_modifiers(&"movement_talent")
	actor.set_base_value(id, -150.0)
	_close(actor.get_value(id), -100.0, "Movement Speed cannot reduce normal speed by more than one hundred percent")
	actor.set_modifiers(&"movement_gear", [_modifier(id, 80.0)])
	_close(actor.get_value(id), -70.0, "The lower bound applies after flat modifiers and retains the underlying negative base")
	actor.remove_modifiers(&"movement_gear")
	actor.set_base_value(id, 0.0)
	_close(actor.get_value(id), 0.0, "Zero Movement Speed bonus restores normal speed")
	actor.set_base_value(id, 25.0)
	_close(actor.get_value(id), 25.0, "The exact twenty-five-percent Movement Speed boundary is allowed")
	actor.set_base_value(id, 100.0)
	_close(actor.get_base_value(id), 100.0, "The raw movement foundation keeps its over-cap value")
	_close(actor.get_value(id), 25.0, "A large movement foundation caps only its final effective bonus")
	actor.set_modifiers(&"movement_debuff", [_modifier(id, -90.0)])
	_close(actor.get_value(id), 10.0, "A flat debuff offsets full raw movement rather than an already capped value")
	actor.remove_modifiers(&"movement_debuff")
	_close(actor.get_value(id), 25.0, "Removing the debuff restores the effective cap without losing raw movement")
	actor.set_modifiers(&"movement_debuff", [_modifier(id, -80.0, AttributeModifier.Operation.ADD_PERCENT)])
	_close(actor.get_value(id), 20.0, "Increased modifiers evaluate the full raw movement bonus before capping")
	actor.set_modifiers(&"movement_debuff", [_modifier(id, -80.0, AttributeModifier.Operation.MORE_PERCENT)])
	_close(actor.get_value(id), 20.0, "More modifiers evaluate the full raw movement bonus before capping")
	actor.remove_modifiers(&"movement_debuff")
	var saved_rules := CombatRules._values.duplicate()
	CombatRules._values.erase("movement_speed_max_percent")
	_close(actor.get_value(id), 25.0, "Older rules without a movement cap key still enforce the default cap")
	CombatRules._values = saved_rules
	actor.free()


func _test_action_speed_percentages() -> void:
	var actor := _actor()
	for id: int in [CombatAttributes.Id.ATTACK_SPEED, CombatAttributes.Id.CAST_SPEED]:
		_close(actor.get_value(id), 0.0, "Speed starts at normal playback")
		actor.set_modifiers(&"first_speed_bonus", [_modifier(id, 20.0)])
		actor.set_modifiers(&"second_speed_bonus", [_modifier(id, 30.0)])
		_close(actor.get_value(id), 50.0, "Flat speed percentage points add together")
		actor.set_base_value(id, 80.0)
		_close(actor.get_value(id), 100.0, "Only the effective speed bonus caps at 100 percent")
		actor.remove_modifiers(&"second_speed_bonus")
		actor.remove_modifiers(&"first_speed_bonus")
		_close(actor.get_value(id), 80.0, "Removing bonuses restores the underlying speed")
		actor.set_base_value(id, -20.0)
		_close(actor.get_value(id), 0.0, "Speed bonus floors at zero")
	actor.free()


func _test_damage_accounting() -> void:
	var actor := _actor()
	var result := actor.apply_damage(25.0)
	_close(result.health_damage, 25.0, "Damage reports actual Health loss")
	_close(result.resolved_amount, 25.0, "Damage reports its requested magnitude separately")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 175.0, "Damage removes Health directly")
	result = actor.apply_damage(1000.0)
	_close(result.health_damage, 175.0, "Overkill reports only remaining Health as actual damage")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 0.0, "Health cannot become negative")
	_check(not result.has("absorbed"), "Damage has no retired protective-pool channel")
	result = actor.apply_damage(1.0)
	_close(result.health_damage, 0.0, "An already dead actor takes no further Health loss")
	actor.restore_resources()
	for amount: float in [0.0, -1.0, INF, NAN]:
		result = actor.apply_damage(amount)
		_close(result.health_damage, 0.0, "Invalid or nonpositive damage changes no Health")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 200.0, "Invalid damage preserves the current pool")
	actor.free()


func _test_validated_allocation() -> void:
	var actor := _actor()
	_check(actor.allocation_budget() == 0, "Starting primaries are separate from earned points")
	_check(not actor.try_set_allocations(1, 0, 0, 0), "A level-one actor cannot spend unearned points")
	actor.level = 60
	_check(actor.allocation_budget() == 118, "Level sixty awards 118 earned points")
	_check(actor.try_set_allocations(0, 0, 0, 118), "The complete budget can be invested in Vitality")
	actor.restore_resources()
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 1380.0, "Vitality investment supplies flat Health")
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 690.0, "Vitality investment supplies flat Stamina")
	_check(not actor.try_set_allocations(1, 0, 0, 118), "Overspending is rejected")
	_check(not actor.try_set_allocations(-1, 0, 0, 0), "Negative allocation is rejected")
	_check(not actor.try_set_allocations(9223372036854775807, 0, 0, 0),
			"Very large allocations cannot overflow the budget validation")
	_check(actor.allocated_vitality == 118, "Rejected allocation leaves the previous investment intact")
	var observations: Array[Vector4i] = []
	actor.attribute_changed.connect(func(_id: int, _previous: float, _value: float) -> void:
		observations.append(Vector4i(actor.allocated_strength, actor.allocated_dexterity,
				actor.allocated_intellect, actor.allocated_vitality)))
	_check(actor.try_set_allocations(0, 0, 118, 0), "Earned points can be redistributed")
	var atomic := not observations.is_empty()
	for observation: Vector4i in observations:
		atomic = atomic and observation == Vector4i(0, 0, 118, 0)
	_check(atomic, "Signals observe the final redistribution, not intermediate allocations")
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 200.0, "Lost Health capacity clamps current Health")
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 100.0, "Lost Stamina capacity clamps current Stamina")
	_close(actor.get_value(CombatAttributes.Id.MANA), 100.0, "Gaining Mana capacity does not refill Mana")
	_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 256.0, "New allocation updates derived Magic Power")
	actor.level = 100
	_check(actor.level == 60, "Level cannot exceed sixty")
	actor.allocated_strength = 1000
	_check(actor.allocated_strength == 1000, "Explicit test/NPC profiles can exceed the earned point budget")
	actor.free()


func _test_tags() -> void:
	var tags := GameplayTagSet.new()
	tags.add_tag(&"State.Test.Active")
	tags.add_tag(&"State.Test.Active")
	_check(tags.has_tag(&"State.Test") and tags.get_count(&"State.Test.Active") == 2,
			"Tags preserve hierarchy and owned counts")
	tags.remove_tag(&"State.Test.Active")
	_check(tags.has_tag(&"State.Test"), "Removing one grant preserves another owner's tag")
	tags.remove_tag(&"State.Test.Active")
	_check(not tags.has_tag(&"State.Test"), "The final grant removal clears the hierarchy")


func _test_automatic_recovery() -> void:
	var actor := _actor()
	actor.modify_current(CombatAttributes.Id.HEALTH, -20.0)
	actor.modify_current(CombatAttributes.Id.STAMINA, -20.0)
	actor.modify_current(CombatAttributes.Id.MANA, -20.0)
	actor.advance_regeneration(1.0)
	_close(actor.get_value(CombatAttributes.Id.HEALTH), 180.0, "Health requires explicit recovery investment")
	_close(actor.get_value(CombatAttributes.Id.STAMINA), 90.0, "Stamina recovers continuously at ten per second")
	_close(actor.get_value(CombatAttributes.Id.MANA), 85.0, "Mana recovers continuously at five per second")
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
