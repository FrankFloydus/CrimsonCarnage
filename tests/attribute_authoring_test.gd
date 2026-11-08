extends SceneTree
## Verifies the active Inspector catalogue and stable modifier serialization.

const ATTRIBUTE_FIXTURE = preload("res://tests/attribute_fixture.gd")

const TEMP_MODIFIER = "res://.godot/attribute_authoring_modifier.tres"
const EXPECTED_IDS: Array[int] = [
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 18, 19, 20, 21, 22,
	34, 38, 39, 40, 42, 44, 53, 54, 55, 56, 57,
]

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_inspector_catalogue()
	_test_ability_commitment_selectors()
	_test_dependent_inspector_fields()
	_test_stale_metadata_refresh()
	_test_modifier_roundtrips()
	_test_legacy_movement_identity_roundtrip()
	_test_operation_roundtrips()
	_test_attribute_based_modifier_roundtrip()
	await process_frame
	print("Attribute authoring checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_inspector_catalogue() -> void:
	var modifier := AttributeModifier.new()
	_check(modifier.get_script().is_tool(), "Modifier metadata executes in the editor")
	var metadata := _property(modifier, &"attribute")
	_check(metadata.get("hint") == PROPERTY_HINT_ENUM, "Attribute selection has explicit enum choices")
	var choices := _choices(metadata.get("hint_string", ""))
	var registered_ids := CombatAttributes.all_ids()
	var builtin_ids := registered_ids.filter(
			func(id: int) -> bool: return id < CombatAttributes.FIRST_CUSTOM_ID)
	_check(CombatAttributes.registry_error().is_empty(), "The saved attribute catalogue is valid")
	_check(choices.size() == registered_ids.size(), "The modifier offers only the registered attributes")
	_check(builtin_ids == EXPECTED_IDS, "The catalogue preserves every built-in identity")
	for id: int in registered_ids:
		_check(choices.get(id) == CombatAttributes.display_name(id), "The selector displays the registered name: %d" % id)
	for id: int in EXPECTED_IDS:
		_check(not CombatAttributes.description(id).is_empty(), "Every built-in attribute has a description: %d" % id)
	_check(CombatAttributes.Id.MOVEMENT_SPEED == 54 and CombatAttributes.Id.LEGACY_MOVEMENT_SPEED_PERCENT == 27,
			"The live Movement Speed bonus does not reuse a retired saved identity")
	_check(CombatAttributes.uses_percentage_units(55) and CombatAttributes.uses_percentage_units(56),
			"Both speed attributes use percentage-point authoring units")
	_check(choices.has(57) and CombatAttributes.uses_percentage_units(57),
			"Spell Penetration has its own saved identity and uses percentage-point units")
	_check(CombatAttributes.Id.CRITICAL_MULTIPLIER == 15,
			"The legacy critical multiplier spelling aliases the bonus-stat identity")
	_check(CombatAttributes.uses_percentage_units(14) and CombatAttributes.uses_percentage_units(15),
			"Both critical attributes use percentage-point authoring units")
	_check(CombatAttributes.Id.FROST_RESISTANCE == 20 and CombatAttributes.Id.POISON_RESISTANCE == 22,
			"Legacy Frost and Poison spellings preserve their saved identities")
	_check(not choices.has(32), "Retired Attack Power is not reused as Physical Power")
	_check(not choices.has(-1), "A modifier cannot select a missing attribute")
	for id: int in CombatAttributes.RETIRED_IDS:
		_check(not choices.has(id), "Old combat attributes are absent from new authoring: %d" % id)
	var optional := _choices(CombatAttributes.inspector_hint(true))
	_check(optional.size() == registered_ids.size() + 1 and optional.get(-1) == "None",
			"Optional selectors add only the None sentinel")


func _test_ability_commitment_selectors() -> void:
	var ability := AbilityDefinition.new()
	var pool := _property(ability, &"charge_pool")
	_check(pool.get("hint") == PROPERTY_HINT_RESOURCE_TYPE
			and pool.get("hint_string") == "AbilityChargeDefinition",
			"The cooldown selects an editable charge profile")
	var amount := _property(AbilityResourceCost.new(), &"amount")
	_check(amount.get("hint") == PROPERTY_HINT_RESOURCE_TYPE
			and amount.get("hint_string") == "AmountDefinition",
			"Resource payment selects an editable semantic amount")


func _test_dependent_inspector_fields() -> void:
	var cost := AbilityResourceCost.new()
	cost.maximum = 31.0
	var refreshes := [0]
	cost.property_list_changed.connect(func() -> void: refreshes[0] += 1)
	_check(_hidden_and_stored(cost, &"maximum"), "Fixed spending hides the variable maximum")
	cost.spend_up_to_maximum = true
	_check(_visible(cost, &"maximum") and cost.maximum == 31.0 and refreshes[0] == 1,
			"Variable spending refreshes the Inspector and exposes the saved cap")

	var charge := AbilityChargeDefinition.new()
	charge.parallel_recharge = true
	_check(_hidden_and_stored(charge, &"parallel_recharge") and not charge.uses_parallel_recharge(),
			"A one-charge cooldown hides and ignores the parallel option")
	charge.capacity = 2
	_check(_visible(charge, &"parallel_recharge") and charge.uses_parallel_recharge(),
			"Adding a charge brings back the saved parallel option")

	var policy := AbilityInterruptionPolicy.new()
	_check(_hidden_and_stored(policy, &"compatible_channels"),
			"Compatibility hides until a channel is occupied")
	policy.occupied_channels = PackedStringArray(["offense"])
	_check(_visible(policy, &"compatible_channels"), "Occupied channels can declare compatibility")
	policy.interrupt_windup = false
	policy.interrupt_channel = false
	_check(_hidden_and_stored(policy, &"cancel_on_tags")
			and _hidden_and_stored(policy, &"interruptible_by_action"),
			"Interruption options hide when no phase can be interrupted")
	policy.interrupt_channel = true
	_check(_visible(policy, &"cancel_on_tags") and _visible(policy, &"interruptible_by_action"),
			"An interruptible phase shows its policy controls")

	var modifier := AttributeModifier.new()
	modifier.capture_coefficient = 2.0
	_check(_hidden_and_stored(modifier, &"capture_coefficient"),
			"Fixed modifiers hide the coefficient for captured attributes")
	modifier.capture_attribute = CombatAttributes.Id.STRENGTH
	_check(_visible(modifier, &"capture_coefficient") and modifier.capture_coefficient == 2.0,
			"Selecting a captured attribute shows its saved coefficient")
	modifier.attribute = CombatAttributes.Id.MOVEMENT_SPEED
	modifier.value = -50.0
	modifier.operation = AttributeModifier.Operation.FINAL_MOVEMENT_PERCENT
	_check(_hidden_and_stored(modifier, &"capture_attribute")
			and _hidden_and_stored(modifier, &"capture_coefficient")
			and _hidden_and_stored(modifier, &"set_by_caller_tag"),
			"Final Movement Percent hides settings for a dynamic magnitude")
	_check(GameplayEffectDefinition.is_valid_modifier(modifier, false)
			and modifier.get_magnitude(null, PackedStringArray()) == -50.0,
			"Final Movement Percent uses its fixed value while the captured attribute is dormant")
	modifier.operation = AttributeModifier.Operation.ADD
	_check(_visible(modifier, &"capture_coefficient") and modifier.capture_coefficient == 2.0,
			"Returning to an ordinary modifier restores its capture settings")


func _hidden_and_stored(resource: Resource, property_name: StringName) -> bool:
	var usage := int(_property(resource, property_name).get("usage", 0))
	return (usage & PROPERTY_USAGE_EDITOR) == 0 and (usage & PROPERTY_USAGE_STORAGE) != 0


func _visible(resource: Resource, property_name: StringName) -> bool:
	return (int(_property(resource, property_name).get("usage", 0)) & PROPERTY_USAGE_EDITOR) != 0


func _test_stale_metadata_refresh() -> void:
	var metadata := {"name": &"attribute", "hint": PROPERTY_HINT_ENUM,
			"hint_string": "Old Burn Chance:47,Old Movement Percent:27,Old Critical Multiplier:15"}
	AttributeModifier.new()._validate_property(metadata)
	var choices := _choices(metadata.hint_string)
	_check(choices.size() == CombatAttributes.all_ids().size() and choices.has(53) and choices.has(54)
			and choices.has(44) and choices.has(18) and choices.has(34) and choices.has(57)
			and not choices.has(13) and not choices.has(27) and not choices.has(47),
			"Tool metadata refresh removes stale Combat 1.0 choices")
	var operations := _choices(_property(AttributeModifier.new(), &"operation").hint_string)
	_check(operations.get(0) == "Add Flat" and operations.get(1) == "Increased Percent"
			and operations.get(2) == "Set Base" and operations.get(3) == "More Percent"
			and operations.get(4) == "Add to Derived Base",
			"Operation names distinguish derived base and ordinary flat modifiers")


func _test_modifier_roundtrips() -> void:
	for id: int in EXPECTED_IDS:
		var modifier := AttributeModifier.new()
		modifier.attribute = id
		modifier.operation = AttributeModifier.Operation.SET_BASE
		modifier.value = -35.25 if CombatAttributes.is_resistance(id) else 50.0
		if id == CombatAttributes.Id.ARMOR:
			modifier.value = 2500.0
		elif id == CombatAttributes.Id.ARMOR_PENETRATION:
			modifier.value = 175.0
		elif id == CombatAttributes.Id.CRITICAL_DAMAGE:
			modifier.value = 10000.0
		elif id == CombatAttributes.Id.MOVEMENT_SPEED:
			modifier.value = -12.5
		elif id == CombatAttributes.Id.CARRIED_WEIGHT:
			modifier.value = 137.25
		modifier.required_context_tags = PackedStringArray(["Weapon.Finesse"])
		_check(ResourceSaver.save(modifier, TEMP_MODIFIER) == OK, "Every current attribute modifier serializes")
		var loaded := ResourceLoader.load(TEMP_MODIFIER, "", ResourceLoader.CACHE_MODE_IGNORE) as AttributeModifier
		_check(loaded != null, "Every current attribute modifier reloads")
		if loaded == null:
			continue
		_check(loaded.attribute == id and loaded.operation == 2 and loaded.value == modifier.value,
				"Saved IDs and modifier values survive resource reload")
		if CombatAttributes.is_resistance(id):
			var actor := ATTRIBUTE_FIXTURE.new_attributes()
			actor.set_modifiers(&"loaded_resistance", [loaded])
			_close(actor.get_value(id, PackedStringArray(["Weapon.Finesse"])), -35.25,
					"A saved negative Resistance modifier retains its signed runtime value")
			actor.free()
		elif id == CombatAttributes.Id.ARMOR:
			var actor := ATTRIBUTE_FIXTURE.new_attributes()
			actor.set_modifiers(&"loaded_armor", [loaded])
			_close(actor.get_value(id, PackedStringArray(["Weapon.Finesse"])), 2500.0,
					"Saved Armor beyond the reduction cap retains its uncapped rating")
			actor.free()
		elif id == CombatAttributes.Id.ARMOR_PENETRATION:
			var actor := ATTRIBUTE_FIXTURE.new_attributes()
			actor.set_modifiers(&"loaded_penetration", [loaded])
			_close(actor.get_value(id, PackedStringArray(["Weapon.Finesse"])), 100.0,
					"Saved over-cap Armor Penetration applies its effective percentage cap")
			_close(loaded.value, 175.0, "Serialization preserves the underlying over-cap penetration value")
			actor.free()
		elif id in [CombatAttributes.Id.CRITICAL_CHANCE, CombatAttributes.Id.CRITICAL_DAMAGE]:
			var actor := ATTRIBUTE_FIXTURE.new_attributes()
			actor.set_modifiers(&"loaded_critical", [loaded])
			_close(actor.get_value(id, PackedStringArray(["Weapon.Finesse"])), modifier.value,
					"Critical authoring units and uncapped Damage bonus survive resource reload")
			actor.free()
		elif id == CombatAttributes.Id.MOVEMENT_SPEED:
			var actor := ATTRIBUTE_FIXTURE.new_attributes()
			actor.set_modifiers(&"loaded_movement", [loaded])
			_close(actor.get_value(id, PackedStringArray(["Weapon.Finesse"])), -12.5,
					"A saved Movement Speed modifier preserves a fractional negative bonus")
			actor.free()
		elif id == CombatAttributes.Id.CARRIED_WEIGHT:
			var actor := ATTRIBUTE_FIXTURE.new_attributes()
			actor.set_modifiers(&"loaded_weight", [loaded])
			_close(actor.get_value(id, PackedStringArray(["Weapon.Finesse"])), 137.25,
					"A saved Carried Weight modifier retains fractional load above capacity")
			actor.free()
		_check(loaded.required_context_tags == PackedStringArray(["Weapon.Finesse"]),
				"Modifier scopes survive resource reload")
	_check(DirAccess.remove_absolute(TEMP_MODIFIER) == OK, "Temporary current modifier fixture is removed")
	var retired := AttributeModifier.new()
	retired.attribute = CombatAttributes.Id.HEALING_POWER
	_check(ResourceSaver.save(retired, TEMP_MODIFIER) == OK, "A legacy numeric identity can still be preserved")
	var loaded := ResourceLoader.load(TEMP_MODIFIER, "", ResourceLoader.CACHE_MODE_IGNORE) as AttributeModifier
	_check(loaded != null and loaded.attribute == 16, "A retired saved slot does not become a different stat")
	_check(not CombatAttributes.is_active(loaded.attribute), "Loading an old identity does not reactivate it")
	_check(DirAccess.remove_absolute(TEMP_MODIFIER) == OK, "Temporary retired modifier fixture is removed")


func _test_legacy_movement_identity_roundtrip() -> void:
	var legacy := AttributeModifier.new()
	legacy.attribute = CombatAttributes.Id.LEGACY_MOVEMENT_SPEED_PERCENT
	legacy.value = 25.0
	_check(ResourceSaver.save(legacy, TEMP_MODIFIER) == OK, "A legacy percentage Movement Speed modifier still serializes")
	var loaded := ResourceLoader.load(TEMP_MODIFIER, "", ResourceLoader.CACHE_MODE_IGNORE) as AttributeModifier
	_check(loaded != null and loaded.attribute == 27 and loaded.value == 25.0,
			"Old Movement Speed data keeps its original identity and value")
	var actor := ATTRIBUTE_FIXTURE.new_attributes()
	actor.set_modifiers(&"legacy_movement", [loaded])
	_close(actor.get_value(CombatAttributes.Id.MOVEMENT_SPEED), 0.0,
			"A legacy twenty-five-percent modifier cannot affect the new zero-base movement bonus")
	_close(actor.get_value(27), 0.0, "The retired percentage Movement Speed slot remains inactive")
	actor.free()
	_check(DirAccess.remove_absolute(TEMP_MODIFIER) == OK, "The temporary legacy Movement Speed fixture is removed")


func _test_operation_roundtrips() -> void:
	_check(AttributeModifier.Operation.ADD == 0 and AttributeModifier.Operation.ADD_PERCENT == 1
			and AttributeModifier.Operation.SET_BASE == 2 and AttributeModifier.Operation.MORE_PERCENT == 3
			and AttributeModifier.Operation.ADD_TO_FOUNDATION == 4,
			"Modifier operation identities remain stable")
	for operation: int in AttributeModifier.Operation.values():
		var modifier := AttributeModifier.new()
		modifier.attribute = CombatAttributes.Id.PHYSICAL_POWER
		modifier.operation = operation
		modifier.value = 20.0
		modifier.required_context_tags = PackedStringArray(["Weapon.Finesse"])
		modifier.excluded_context_tags = PackedStringArray(["Ability.Disabled"])
		_check(ResourceSaver.save(modifier, TEMP_MODIFIER) == OK, "Every modifier operation serializes")
		var loaded := ResourceLoader.load(TEMP_MODIFIER, "", ResourceLoader.CACHE_MODE_IGNORE) as AttributeModifier
		_check(loaded != null and loaded.attribute == 53 and loaded.operation == operation
				and loaded.value == 20.0 and loaded.required_context_tags == modifier.required_context_tags
				and loaded.excluded_context_tags == modifier.excluded_context_tags,
				"Operation, Physical Power identity, value and scopes survive reload")
	_check(DirAccess.remove_absolute(TEMP_MODIFIER) == OK, "Temporary operation fixture is removed")


func _test_attribute_based_modifier_roundtrip() -> void:
	var modifier := AttributeModifier.new()
	modifier.attribute = CombatAttributes.Id.MAGIC_POWER
	modifier.operation = AttributeModifier.Operation.ADD_TO_FOUNDATION
	modifier.capture_attribute = CombatAttributes.Id.INTELLECT
	modifier.capture_coefficient = 1.25
	_check(ResourceSaver.save(modifier, TEMP_MODIFIER) == OK, "An Attribute Based modifier saves")
	var loaded := ResourceLoader.load(TEMP_MODIFIER, "", ResourceLoader.CACHE_MODE_IGNORE) as AttributeModifier
	_check(loaded != null and loaded.capture_attribute == CombatAttributes.Id.INTELLECT
			and is_equal_approx(loaded.capture_coefficient, 1.25), "The captured stat and coefficient survive reload")
	if loaded != null:
		var actor := ATTRIBUTE_FIXTURE.new_attributes()
		actor.set_modifiers(&"loaded_derivation", [loaded])
		actor.set_base_value(CombatAttributes.Id.INTELLECT, 20.0)
		_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 65.0,
				"The loaded modifier reads the changed target value and adds to the foundation")
		actor.remove_modifiers(&"loaded_derivation")
		_close(actor.get_value(CombatAttributes.Id.MAGIC_POWER), 40.0,
				"Removing a retained derivation leaves the other derivation in place")
		actor.free()
	_check(DirAccess.remove_absolute(TEMP_MODIFIER) == OK, "The temporary capture fixture is removed")


func _property(resource: Resource, name: StringName) -> Dictionary:
	for property: Dictionary in resource.get_property_list():
		if property.name == name:
			return property
	return {}


func _choices(hint_string: String) -> Dictionary:
	var choices: Dictionary = {}
	for entry: String in hint_string.split(",", false):
		var parts := entry.rsplit(":", true, 1)
		_check(parts.size() == 2 and parts[1].is_valid_int(), "Every selector entry has an explicit saved ID")
		if parts.size() != 2 or not parts[1].is_valid_int():
			continue
		var id := int(parts[1])
		_check(not choices.has(id), "Selector saved IDs are unique")
		choices[id] = parts[0]
	return choices


func _close(actual: float, expected: float, label: String) -> void:
	_check(is_equal_approx(actual, expected), "%s: %.6f expected %.6f" % [label, actual, expected])


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
