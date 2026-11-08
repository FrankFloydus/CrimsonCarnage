extends SceneTree
## Checks weapon categories, physical profiles, cast-only boundaries and saved authoring.

const WEAPON_SCRIPT = preload("res://combat/weapons/weapon_definition.gd")
var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_families()
	_test_physical_profiles()
	_test_inspector_visibility()
	_test_saved_profile()
	print("Weapon checks: %d; failures: %d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_families() -> void:
	var weapon := WEAPON_SCRIPT.new() as WeaponDefinition
	var finesse: Array[int] = [
		WeaponDefinition.Kind.DAGGER_ONE_HAND, WeaponDefinition.Kind.SWORD_ONE_HAND,
		WeaponDefinition.Kind.SWORD_TWO_HAND,
	]
	var brutality: Array[int] = [
		WeaponDefinition.Kind.MACE_ONE_HAND, WeaponDefinition.Kind.AXE_ONE_HAND,
		WeaponDefinition.Kind.MACE_TWO_HAND, WeaponDefinition.Kind.AXE_TWO_HAND,
	]
	var casters: Array[int] = [
		WeaponDefinition.Kind.RITUAL_DAGGER, WeaponDefinition.Kind.SCEPTER,
		WeaponDefinition.Kind.STAFF, WeaponDefinition.Kind.FOCUS,
	]
	for kind: int in finesse:
		weapon.kind = kind
		_check(weapon.get_category() == WeaponDefinition.Category.FINESSE,
				"Finesse weapon category %d" % kind)
		_check(weapon.get_governing_attribute() == CombatAttributes.Id.DEXTERITY,
				"Finesse uses Dexterity %d" % kind)
		_check(weapon.is_physical_weapon(), "Finesse has a physical attack %d" % kind)
		_check(weapon.get_context_tags().has("Weapon.Finesse"), "Finesse scope %d" % kind)
		_check(not weapon.get_context_tags().has("Weapon.Brutality"),
				"Finesse has one governing category %d" % kind)
	for kind: int in brutality:
		weapon.kind = kind
		_check(weapon.get_category() == WeaponDefinition.Category.BRUTALITY,
				"Brutality weapon category %d" % kind)
		_check(weapon.get_governing_attribute() == CombatAttributes.Id.STRENGTH,
				"Brutality uses Strength %d" % kind)
		_check(weapon.get_context_tags().has("Weapon.Brutality"), "Brutality scope %d" % kind)
		_check(not weapon.get_context_tags().has("Weapon.Finesse"),
				"Brutality has one governing category %d" % kind)
	for kind: int in casters:
		weapon.kind = kind
		weapon.physical_damage_min = 100.0
		weapon.physical_damage_max = 200.0
		_check(weapon.get_category() == WeaponDefinition.Category.CASTER,
				"Caster weapon category %d" % kind)
		_check(weapon.get_governing_attribute() == CombatAttributes.Id.INTELLECT,
				"Caster uses Intellect %d" % kind)
		_check(weapon.get_delivery() == WeaponDefinition.Delivery.SPELL,
				"Caster delivery stays spellcasting %d" % kind)
		_check(not weapon.is_physical_weapon(), "Caster has no physical attack %d" % kind)
		_close(weapon.get_power_coefficient(), 0.0, "Caster has no physical coefficient %d" % kind)
		_check(not weapon.get_physical_attack_error().is_empty(),
				"Caster cannot be used by a physical attack %d" % kind)
		_check(weapon.get_context_tags() == PackedStringArray(["Weapon.Caster"]),
				"Caster tags exclude physical categories %d" % kind)
	_check(not WeaponDefinition.Kind.has("SHIELD"), "Shields are not a weapon family")
	_check(not WeaponDefinition.Kind.has("SPEAR"), "The rejected spear is not a weapon family")
	weapon.kind = 99
	_check(weapon.get_category() == WeaponDefinition.Category.INVALID, "Unknown family is invalid")
	_check(weapon.get_governing_attribute() == CombatAttributes.Id.NONE,
			"Unknown family grants no primary contribution")
	_check(not weapon.get_validation_error().is_empty(), "Unknown family fails validation")


func _test_physical_profiles() -> void:
	var weapon := WEAPON_SCRIPT.new() as WeaponDefinition
	weapon.kind = WeaponDefinition.Kind.SWORD_ONE_HAND
	weapon.physical_damage_min = 20.0
	weapon.physical_damage_max = 30.0
	weapon.base_attack_cycle = 1.0
	_check(weapon.get_validation_error().is_empty(), "A valid physical damage range is accepted")
	_check(weapon.get_physical_attack_error().is_empty(), "A valid weapon profile can supply physical damage")
	for cycle: float in [0.5, 1.0, 2.0]:
		weapon.base_attack_cycle = cycle
		_close(weapon.get_power_coefficient(), cycle, "Ordinary coefficient uses the authored cycle")
		var power_damage := 20.0 * weapon.get_power_coefficient()
		_close(power_damage / cycle, 20.0, "Equal Power contributes equal base DPS across cycles")
	weapon.physical_damage_min = -1.0
	_check(not weapon.get_validation_error().is_empty(), "Negative physical damage is rejected")
	weapon.physical_damage_min = 31.0
	_check(not weapon.get_validation_error().is_empty(), "Inverted physical damage range is rejected")
	weapon.physical_damage_min = NAN
	_check(not weapon.get_validation_error().is_empty(), "NaN minimum damage is rejected")
	weapon.physical_damage_min = 20.0
	weapon.physical_damage_max = INF
	_check(not weapon.get_validation_error().is_empty(), "Infinite maximum damage is rejected")
	weapon.physical_damage_max = 30.0
	for cycle: float in [0.0, -1.0, NAN, INF]:
		weapon.base_attack_cycle = cycle
		_check(not weapon.get_validation_error().is_empty(), "Nonpositive or nonfinite cycle is rejected")
	weapon.base_attack_cycle = 1.0
	weapon.physical_damage_min = 0.0
	weapon.physical_damage_max = 0.0
	_check(weapon.get_validation_error().is_empty(), "Zero base damage may still scale through Power")
	weapon.physical_damage_min = 1e20
	weapon.physical_damage_max = 2e20
	_check(weapon.get_validation_error().is_empty(), "Finite large physical damage has no arbitrary cap")


func _test_inspector_visibility() -> void:
	var weapon := WEAPON_SCRIPT.new() as WeaponDefinition
	var physical_fields := [&"physical_damage_min", &"physical_damage_max", &"base_attack_cycle"]
	for kind: WeaponDefinition.Kind in [WeaponDefinition.Kind.BOW, WeaponDefinition.Kind.FOCUS]:
		weapon.kind = kind
		var field_count := 0
		for property: Dictionary in weapon.get_property_list():
			if property.name not in physical_fields:
				continue
			field_count += 1
			var editor_visible := (int(property.usage) & PROPERTY_USAGE_EDITOR) != 0
			_check(editor_visible == weapon.is_physical_weapon(),
					"The Inspector visibility of %s follows the weapon family" % property.name)
			_check((int(property.usage) & PROPERTY_USAGE_STORAGE) != 0,
					"The resource keeps %s serializable in either family" % property.name)
		_check(field_count == physical_fields.size(), "All physical fields remain in the property list")


func _test_saved_profile() -> void:
	var weapon := WEAPON_SCRIPT.new() as WeaponDefinition
	weapon.weapon_id = &"test_weapon"
	weapon.display_name = "Test Weapon"
	weapon.kind = WeaponDefinition.Kind.FOCUS
	weapon.physical_damage_min = 20.0
	weapon.physical_damage_max = 30.0
	weapon.base_attack_cycle = 1.25
	var path := "user://weapons_test_profile.tres"
	_check(ResourceSaver.save(weapon, path) == OK, "Weapon profile saves as an editable resource")
	var restored := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as WeaponDefinition
	_check(restored != null, "Saved weapon resource loads")
	if restored != null:
		_check(restored.kind == WeaponDefinition.Kind.FOCUS, "Saved weapon family is preserved")
		_check(restored.weapon_id == &"test_weapon", "Saved weapon identity is preserved")
		_close(restored.physical_damage_min, 20.0, "Hidden minimum damage survives serialization")
		_close(restored.physical_damage_max, 30.0, "Hidden maximum damage survives serialization")
		restored.kind = WeaponDefinition.Kind.SWORD_ONE_HAND
		_close(restored.get_power_coefficient(), 1.25, "Switching back restores the saved base cycle")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)


func _close(actual: float, expected: float, description: String) -> void:
	_check(is_equal_approx(actual, expected), "%s: expected %s, got %s" % [description, expected, actual])
