@tool
class_name CombatAttributes
extends RefCounted
## Project attribute catalogue and stable engine bindings for Combat 2.0.
## Retired numeric slots remain reserved so older assets cannot silently change meaning.

## Persistent identifiers for engine-bound and retired attributes. Custom attributes use integer IDs.
enum Id {
	## The optional selector has no attribute.
	NONE = -1,
	## Current Health points, bounded by maximum Health.
	HEALTH = 0,
	## Maximum Health; receives flat Vitality and authored capacity bonuses.
	MAX_HEALTH = 1,
	## Current Stamina points, bounded by maximum Stamina.
	STAMINA = 2,
	## Maximum Stamina; receives flat Vitality and authored capacity bonuses.
	MAX_STAMINA = 3,
	## Current Mana points, bounded by maximum Mana.
	MANA = 4,
	## Maximum Mana; receives flat Intellect and authored capacity bonuses.
	MAX_MANA = 5,
	## Primary governing Brutality attacks and Carry Capacity.
	STRENGTH = 6,
	## Primary governing Finesse attacks, including bows.
	DEXTERITY = 7,
	## Primary governing Magic Power, maximum Mana and spell accuracy.
	INTELLECT = 8,
	## Primary governing maximum Health and maximum Stamina.
	VITALITY = 9,
	## Health restored per second while alive; supplied by explicit authored investment.
	HEALTH_REGEN = 10,
	## Stamina restored per second while alive and outside Sprint or Stamina Exhaustion.
	STAMINA_REGEN = 11,
	## Mana restored per second while alive, including while casting.
	MANA_REGEN = 12,
	## Reserved ID for the retired generic damage bonus.
	DAMAGE_BONUS = 13,
	## Percentage chance for a successful direct damage hit to critically strike.
	CRITICAL_CHANCE = 14,
	## Uncapped bonus percentage points added to the base critical damage multiplier.
	CRITICAL_DAMAGE = 15,
	## Alias of Critical Damage for the original saved bonus-stat ID.
	CRITICAL_MULTIPLIER = 15,
	## Reserved ID for retired Healing Power.
	HEALING_POWER = 16,
	## Reserved slot with no active attribute.
	RESERVED_17 = 17,
	## Nonnegative, uncapped rating that reduces incoming Physical damage with diminishing returns.
	ARMOR = 18,
	## Percentage reduction to incoming Fire magic damage; negative values amplify it.
	FIRE_RESISTANCE = 19,
	## Percentage reduction to incoming Cold magic damage; negative values amplify it.
	COLD_RESISTANCE = 20,
	## Original alias of the active Cold Resistance ID.
	FROST_RESISTANCE = 20,
	## Percentage reduction to incoming Lightning magic damage; negative values amplify it.
	LIGHTNING_RESISTANCE = 21,
	## Percentage reduction to incoming Necrotic magic damage; negative values amplify it.
	NECROTIC_RESISTANCE = 22,
	## Original alias of the active Necrotic Resistance ID.
	POISON_RESISTANCE = 22,
	## Reserved ID for retired block efficiency.
	BLOCK_EFFICIENCY = 23,
	## Reserved ID for the retired Resolve attribute.
	RESOLVE = 24,
	## Alias of the retired Resolve ID.
	CONTROL_DURATION_REDUCTION = 24,
	## Reserved ID for the old rating-based Attack Speed model.
	ATTACK_SPEED_RATING = 25,
	## Reserved ID for the old rating-based Cast Speed model.
	CAST_SPEED_RATING = 26,
	## Reserved ID for the old movement percentage. Active Movement Speed uses ID 54.
	LEGACY_MOVEMENT_SPEED_PERCENT = 27,
	## Reserved ID for the retired Stamina cost discount.
	STAMINA_COST_EFFICIENCY = 28,
	## Reserved ID for the retired Mana cost discount.
	MANA_COST_EFFICIENCY = 29,
	## Reserved ID for retired cooldown-recovery scaling.
	COOLDOWN_RECOVERY = 30,
	## Reserved ID for the old Spell Power attribute. Active Magic Power uses ID 42.
	SPELL_POWER = 31,
	## Reserved ID for the old Attack Power attribute. Active Physical Power uses ID 53.
	ATTACK_POWER = 32,
	## Reserved ID for retired Evasion.
	EVASION = 33,
	## Percentage of target Armor ignored by outgoing Physical damage before its reduction curve.
	ARMOR_PENETRATION = 34,
	## Reserved ID for the retired elemental damage bonus.
	ELEMENTAL_DAMAGE = 35,
	## Reserved slot with no active attribute.
	RESERVED_36 = 36,
	## Reserved ID for the retired Block Chance attribute.
	BLOCK_CHANCE = 37,
	## Inventory weight threshold for encumbrance, supplied by Strength and authored bonuses.
	CARRY_CAPACITY = 38,
	## Actual carried weight in weight units. Exceeding Carry Capacity causes encumbrance.
	CARRIED_WEIGHT = 39,
	## Action-specific flat rating from the governing primary and applicable modifiers.
	ACCURACY_RATING = 40,
	## Original alias of the shared active Accuracy Rating ID.
	HIT_RATING = 40,
	## Reserved ID for retired spell-only Accuracy.
	SPELL_ACCURACY = 41,
	## Flat offensive power for spells, supplied by Intellect and authored bonuses.
	MAGIC_POWER = 42,
	## Reserved ID for the retired global periodic damage bonus.
	DOT_DAMAGE = 43,
	## Percentage reduction to incoming Void magic damage; negative values amplify it.
	VOID_RESISTANCE = 44,
	## Reserved ID for the retired actor-wide absorption pool.
	ABSORPTION = 45,
	## Reserved ID for the retired actor-wide absorption capacity.
	MAX_ABSORPTION = 46,
	## Reserved ID for the retired actor-wide burn chance.
	BURN_CHANCE = 47,
	## Reserved ID for the retired actor-wide chill chance.
	CHILL_CHANCE = 48,
	## Reserved ID for the retired actor-wide lightning ailment chance.
	ZAPPED_CHANCE = 49,
	## Reserved ID for the retired actor-wide bleed chance.
	BLEED_CHANCE = 50,
	## Reserved ID for the retired actor-wide poison chance.
	POISON_CHANCE = 51,
	## Reserved ID for the retired actor-wide Void ailment chance.
	HOLLOWED_CHANCE = 52,
	## Flat physical power for the relevant Finesse or Brutality attack.
	PHYSICAL_POWER = 53,
	## Signed bonus percentage points to normal movement speed; zero is normal speed.
	MOVEMENT_SPEED = 54,
	## Additive percentage-point bonus to Attack animation playback.
	ATTACK_SPEED = 55,
	## Additive percentage-point bonus to Spell animation playback.
	CAST_SPEED = 56,
	## Points subtracted from the matching resistance for each Magic component of a spell hit.
	SPELL_PENETRATION = 57,
}

const MAX_LEVEL: int = 60
const REGISTRY_PATH := "res://combat/attributes/attributes.json"
const FIRST_CUSTOM_ID := 100
const MAX_ATTRIBUTE_ID := 2147483647
## Engine bindings remain usable if the authoring registry is unreadable.
const BUILTIN_IDS: Array[int] = [
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 18, 19, 20, 21, 22,
	34, 38, 39, 40, 42, 44, 53, 54, 55, 56, 57,
]
const RESISTANCE_IDS: Array[int] = [19, 20, 21, 22, 44]
const RETIRED_IDS: Array[int] = [
	13, 16, 17, 23, 24,
	25, 26, 27, 28, 29, 30, 31, 32, 33, 35, 36, 37, 41,
	43, 45, 46, 47, 48, 49, 50, 51, 52,
]

static var _loaded := false
static var _source := ""
static var _load_error := ""
static var _definitions: Dictionary[int, Dictionary] = {}
static var _ids: Array[int] = BUILTIN_IDS.duplicate()


static func all_ids() -> Array[int]:
	_ensure_loaded()
	return _ids.duplicate()


static func is_active(id: int) -> bool:
	_ensure_loaded()
	return _definitions.has(id) or (_definitions.is_empty() and id in BUILTIN_IDS)


static func resistance_ids() -> Array[int]:
	return RESISTANCE_IDS.duplicate()


static func is_resistance(id: int) -> bool:
	return id in RESISTANCE_IDS


static func uses_percentage_units(id: int) -> bool:
	_ensure_loaded()
	return _definitions.get(id, {}).get("unit", "") == "%"


static func inspector_hint(include_none: bool = false) -> String:
	if Engine.is_editor_hint():
		_refresh_registry()
	var choices := PackedStringArray()
	if include_none:
		choices.append("None:%d" % Id.NONE)
	for id: int in all_ids():
		choices.append("%s:%d" % [display_name(id), id])
	return ",".join(choices)


## Returns any catalogue error so authoring tools can refuse unsafe changes.
static func registry_error() -> String:
	_ensure_loaded()
	return _load_error


static func current_ids() -> Array[int]:
	return [Id.HEALTH, Id.STAMINA, Id.MANA]


static func is_current_resource(id: int) -> bool:
	return id in current_ids()


static func maximum_for(id: int) -> int:
	match id:
		Id.HEALTH:
			return Id.MAX_HEALTH
		Id.STAMINA:
			return Id.MAX_STAMINA
		Id.MANA:
			return Id.MAX_MANA
	return Id.NONE


static func regeneration_for(id: int) -> int:
	match id:
		Id.HEALTH:
			return Id.HEALTH_REGEN
		Id.STAMINA:
			return Id.STAMINA_REGEN
		Id.MANA:
			return Id.MANA_REGEN
	return Id.NONE


## Selects one primary from action tags; unspecified or conflicting weapon categories select NONE.
## Spellcasting uses Intellect even while a physical weapon tag is present.
static func governing_attribute(context_tags: PackedStringArray) -> int:
	var finesse := false
	var brutality := false
	for tag: String in context_tags:
		if tag == "Ability.Spell" or tag.begins_with("Ability.Spell."):
			return Id.INTELLECT
		finesse = finesse or tag == "Weapon.Finesse" or tag.begins_with("Weapon.Finesse.")
		brutality = brutality or tag == "Weapon.Brutality" or tag.begins_with("Weapon.Brutality.")
	if finesse == brutality:
		return Id.NONE
	return Id.DEXTERITY if finesse else Id.STRENGTH


static func display_name(id: int) -> String:
	if id == Id.NONE:
		return "None"
	if id in RETIRED_IDS:
		return "Retired Attribute %d" % id
	_ensure_loaded()
	if _definitions.has(id):
		return _definitions[id].name
	if id in BUILTIN_IDS:
		return String(Id.find_key(id)).to_lower().capitalize()
	return "Unknown"


## Designer-facing description from the authoring registry.
static func description(id: int) -> String:
	if id == Id.NONE:
		return "No attribute selected."
	if id in RETIRED_IDS:
		return "Retired identity reserved for old serialized data. It contributes zero."
	_ensure_loaded()
	return _definitions.get(id, {}).get("description", "")


static func clamp_value(id: int, value: float) -> float:
	if not is_active(id):
		return 0.0
	if is_resistance(id):
		return clampf(value, CombatRules.get_number("resistance_min_percent"),
				CombatRules.get_number("resistance_max_percent"))
	if id == Id.ARMOR_PENETRATION:
		return clampf(value, CombatRules.get_number("armor_penetration_min_percent"),
				CombatRules.get_number("armor_penetration_max_percent"))
	if id == Id.CRITICAL_CHANCE:
		return clampf(value, CombatRules.get_number("critical_chance_min_percent"),
				CombatRules.get_number("critical_chance_max_percent"))
	if id == Id.MOVEMENT_SPEED:
		return clampf(value, CombatRules.get_number("movement_speed_min_percent"),
				CombatRules.get_number("movement_speed_max_percent"))
	if id in [Id.ATTACK_SPEED, Id.CAST_SPEED]:
		return clampf(value, 0.0, CombatRules.get_number("action_speed_max_percent"))
	if id in [Id.MAX_HEALTH, Id.MAX_STAMINA, Id.MAX_MANA, Id.CARRY_CAPACITY]:
		return maxf(CombatRules.get_number("minimum_capacity"), value)
	return maxf(0.0, value)


static func _ensure_loaded() -> void:
	if not _loaded:
		_refresh_registry()


static func _refresh_registry() -> void:
	var source := FileAccess.get_file_as_string(REGISTRY_PATH)
	if _loaded and source == _source:
		return
	_loaded = true
	_source = source
	_load_error = _read_registry(source)
	if not _load_error.is_empty():
		push_error(_load_error)


static func _read_registry(source: String) -> String:
	var json := JSON.new()
	if json.parse(source) != OK:
		return "Invalid attribute registry at %s:%d: %s" % [
			REGISTRY_PATH, json.get_error_line(), json.get_error_message()]
	var data: Variant = json.data
	if not data is Dictionary or data.get("schema_version") != 1 or not data.get("attributes") is Array:
		return "Expected schema 1 and an attributes array in %s." % REGISTRY_PATH
	if not _is_integer_in_range(data.get("next_id"), FIRST_CUSTOM_ID, MAX_ATTRIBUTE_ID + 1):
		return "Invalid next attribute ID in %s." % REGISTRY_PATH

	var definitions: Dictionary[int, Dictionary] = {}
	var keys: Dictionary[String, bool] = {}
	var names: Dictionary[String, bool] = {}
	for index: int in data.attributes.size():
		var entry: Variant = data.attributes[index]
		if not _is_valid_entry(entry):
			return "Invalid attribute entry %d in %s." % [index + 1, REGISTRY_PATH]
		var id := int(entry.id)
		var key: String = entry.key
		var name: String = entry.name.to_lower()
		if definitions.has(id) or keys.has(key) or names.has(name):
			return "Duplicate attribute ID, key or name at entry %d in %s." % [index + 1, REGISTRY_PATH]
		if id in BUILTIN_IDS:
			if not entry.builtin or key != String(Id.find_key(id)):
				return "Attribute %d must retain its built-in binding in %s." % [id, REGISTRY_PATH]
			if entry.description.strip_edges().is_empty():
				return "Built-in attribute %d needs a description in %s." % [id, REGISTRY_PATH]
		elif entry.builtin or id < FIRST_CUSTOM_ID or id >= int(data.next_id):
			return "Invalid custom attribute ID %d in %s." % [id, REGISTRY_PATH]
		definitions[id] = entry
		keys[key] = true
		names[name] = true

	for id: int in BUILTIN_IDS:
		if not definitions.has(id):
			return "Missing built-in attribute %d in %s." % [id, REGISTRY_PATH]
	_definitions = definitions
	_ids = definitions.keys()
	_ids.sort()
	return ""


static func _is_valid_entry(entry: Variant) -> bool:
	if not entry is Dictionary or not _is_integer_in_range(entry.get("id"), 0, MAX_ATTRIBUTE_ID) \
			or not entry.get("builtin") is bool or not entry.get("description") is String \
			or not entry.get("key") is String or not entry.get("name") is String \
			or not entry.get("unit") is String or not entry.get("category") is String:
		return false
	var key: String = entry.key
	var name: String = entry.name
	return key.is_valid_ascii_identifier() and key[0] != "_" and key == key.to_upper() and key != "NONE" \
			and not name.is_empty() and name == name.strip_edges() and name.to_lower() != "none" \
			and not ":" in name and not "," in name and not "\n" in name and not "\r" in name \
			and not entry.unit.strip_edges().is_empty() and not entry.category.strip_edges().is_empty()


static func _is_integer_in_range(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and value >= minimum and value <= maximum \
			and value == floor(value)
