class_name CombatAttributes
extends RefCounted
## Stable serialized identities and the thirty active Combat 2.0 attributes.
## Retired numeric slots remain reserved so older assets cannot silently change meaning.

enum Id {
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
	DAMAGE_BONUS = 13, # Retired Combat 1.0 identity.
	## Percentage chance for a successful direct damage hit to critically strike.
	CRITICAL_CHANCE = 14,
	## Uncapped bonus percentage points added to the base critical damage multiplier.
	CRITICAL_DAMAGE = 15,
	CRITICAL_MULTIPLIER = 15, # Legacy spelling of the same bonus-stat identity.
	HEALING_POWER = 16,
	RESERVED_17 = 17,
	## Nonnegative, uncapped rating that reduces incoming Physical damage with diminishing returns.
	ARMOR = 18,
	## Percentage reduction to incoming Fire magic damage; negative values amplify it.
	FIRE_RESISTANCE = 19,
	## Percentage reduction to incoming Cold magic damage; negative values amplify it.
	COLD_RESISTANCE = 20,
	FROST_RESISTANCE = 20,
	## Percentage reduction to incoming Lightning magic damage; negative values amplify it.
	LIGHTNING_RESISTANCE = 21,
	## Percentage reduction to incoming Necrotic magic damage; negative values amplify it.
	NECROTIC_RESISTANCE = 22,
	POISON_RESISTANCE = 22,
	BLOCK_EFFICIENCY = 23,
	RESOLVE = 24,
	CONTROL_DURATION_REDUCTION = 24,
	ATTACK_SPEED_RATING = 25,
	CAST_SPEED_RATING = 26,
	LEGACY_MOVEMENT_SPEED_PERCENT = 27, # Retired identity; does not participate in the live bonus stat.
	STAMINA_COST_EFFICIENCY = 28,
	MANA_COST_EFFICIENCY = 29,
	COOLDOWN_RECOVERY = 30,
	SPELL_POWER = 31,
	ATTACK_POWER = 32,
	EVASION = 33,
	## Percentage of target Armor ignored by outgoing Physical damage before its reduction curve.
	ARMOR_PENETRATION = 34,
	ELEMENTAL_DAMAGE = 35,
	RESERVED_36 = 36,
	BLOCK_CHANCE = 37,
	## Inventory weight threshold for encumbrance, supplied by Strength and authored bonuses.
	CARRY_CAPACITY = 38,
	## Actual carried weight in weight units. Exceeding Carry Capacity causes encumbrance.
	CARRIED_WEIGHT = 39,
	## Action-specific flat rating from the governing primary and applicable modifiers.
	ACCURACY_RATING = 40,
	HIT_RATING = 40, # Legacy spelling of the same saved slot.
	SPELL_ACCURACY = 41,
	## Flat offensive power for spells, supplied by Intellect and authored bonuses.
	MAGIC_POWER = 42,
	DOT_DAMAGE = 43,
	## Percentage reduction to incoming Void magic damage; negative values amplify it.
	VOID_RESISTANCE = 44,
	ABSORPTION = 45,
	MAX_ABSORPTION = 46,
	BURN_CHANCE = 47,
	CHILL_CHANCE = 48,
	ZAPPED_CHANCE = 49,
	BLEED_CHANCE = 50,
	POISON_CHANCE = 51,
	HOLLOWED_CHANCE = 52,
	## Flat physical power for the relevant Finesse or Brutality attack.
	PHYSICAL_POWER = 53,
	## Signed bonus percentage points to normal movement speed; zero is normal speed.
	MOVEMENT_SPEED = 54,
	## Additive percentage-point bonus to Attack animation playback.
	ATTACK_SPEED = 55,
	## Additive percentage-point bonus to Spell animation playback.
	CAST_SPEED = 56,
}

const MAX_LEVEL: int = 60
const ACTIVE_IDS: Array[int] = [
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 18, 19, 20, 21, 22,
	34, 38, 39, 40, 42, 44, 53, 54, 55, 56,
]
const RESISTANCE_IDS: Array[int] = [19, 20, 21, 22, 44]
const RETIRED_IDS: Array[int] = [
	13, 16, 17, 23, 24,
	25, 26, 27, 28, 29, 30, 31, 32, 33, 35, 36, 37, 41,
	43, 45, 46, 47, 48, 49, 50, 51, 52,
]


static func all_ids() -> Array[int]:
	return ACTIVE_IDS.duplicate()


static func is_active(id: int) -> bool:
	return id in ACTIVE_IDS


static func resistance_ids() -> Array[int]:
	return RESISTANCE_IDS.duplicate()


static func is_resistance(id: int) -> bool:
	return id in RESISTANCE_IDS


static func uses_percentage_units(id: int) -> bool:
	return is_resistance(id) or id in [Id.ARMOR_PENETRATION, Id.CRITICAL_CHANCE,
			Id.CRITICAL_DAMAGE, Id.MOVEMENT_SPEED, Id.ATTACK_SPEED, Id.CAST_SPEED]


static func inspector_hint(include_none: bool = false) -> String:
	var choices := PackedStringArray()
	if include_none:
		choices.append("None:%d" % Id.NONE)
	for id: int in ACTIVE_IDS:
		choices.append("%s:%d" % [display_name(id), id])
	return ",".join(choices)


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
	if id in RETIRED_IDS:
		return "Retired Attribute %d" % id
	if id == Id.NONE:
		return "None"
	if not is_active(id):
		return "Unknown"
	if id == Id.COLD_RESISTANCE:
		return "Cold Resistance"
	if id == Id.NECROTIC_RESISTANCE:
		return "Necrotic Resistance"
	if id == Id.CRITICAL_DAMAGE:
		return "Critical Damage"
	var key: Variant = Id.find_key(id)
	return String(key).to_lower().capitalize()


## Designer-facing meaning, units and contribution of every active attribute.
static func description(id: int) -> String:
	if id == Id.NONE:
		return "No attribute selected."
	if id in RETIRED_IDS:
		return "Retired identity reserved for old serialized data. It contributes zero."
	if is_resistance(id):
		return _resistance_description(display_name(id).trim_suffix(" Resistance"))
	match id:
		Id.HEALTH:
			return ("Current Health points, from zero to maximum Health. Zero Health means death. "
					+ "Damage removes Health directly; persistent modifiers change capacity or regeneration.")
		Id.MAX_HEALTH:
			return ("Health capacity: startup base plus the authored Vitality derivation and other flat "
					+ "bonuses, then increased and More modifiers. Minimum %s; no upper cap. "
					+ "Increasing capacity does not restore current Health.") % CombatRules.get_number("minimum_capacity")
		Id.STAMINA:
			return ("Current Stamina points, from zero to maximum Stamina. Abilities spend "
					+ "their authored costs. Active Sprint and Stamina Exhaustion pause Stamina recovery.")
		Id.MAX_STAMINA:
			return ("Stamina capacity: startup base plus the authored Vitality derivation and other "
					+ "flat bonuses, then increased and More modifiers. Minimum %s; no upper cap. "
					+ "Increasing capacity does not refill Stamina.") % CombatRules.get_number("minimum_capacity")
		Id.MANA:
			return ("Current Mana points, from zero to maximum Mana. Abilities spend their "
					+ "authored costs; the regeneration effect restores Mana while alive, even casting.")
		Id.MAX_MANA:
			return ("Mana capacity: startup base plus the authored Intellect derivation and other flat "
					+ "bonuses, then increased and More modifiers. Minimum %s; no upper cap. "
					+ "Increasing capacity does not refill Mana.") % CombatRules.get_number("minimum_capacity")
		Id.STRENGTH:
			return ("Primary for Brutality attacks. Each point grants %s Physical Power and %s "
					+ "Accuracy Rating to those attacks. Also contributes to Carry Capacity through the "
					+ "Attribute Derivations effect. Uses the full "
					+ "primary value, including gear bonuses. Nonnegative and uncapped.") % [
					CombatRules.get_number("strength_physical_power_per_point"),
					CombatRules.get_number("governing_accuracy_per_point")]
		Id.DEXTERITY:
			return ("Primary for Finesse attacks, including bow shots. Each point grants %s "
					+ "Physical Power and %s Accuracy Rating to those attacks. Uses the full "
					+ "primary value, including gear bonuses. Nonnegative and uncapped.") % [
					CombatRules.get_number("dexterity_physical_power_per_point"),
					CombatRules.get_number("governing_accuracy_per_point")]
		Id.INTELLECT:
			return ("Primary for spells. Each point grants %s spell Accuracy Rating. Magic Power "
					+ "and maximum Mana receive flat contributions from the Attribute Derivations effect. "
					+ "Nonnegative and uncapped.") % CombatRules.get_number("governing_accuracy_per_point")
		Id.VITALITY:
			return ("Survival primary. Grants flat maximum Health and maximum Stamina through the "
					+ "Attribute Derivations effect. Nonnegative and uncapped.")
		Id.HEALTH_REGEN:
			return _regeneration_description("Health")
		Id.STAMINA_REGEN:
			return _regeneration_description("Stamina") \
					+ " Active Sprint and Stamina Exhaustion pause this recovery."
		Id.MANA_REGEN:
			return _regeneration_description("Mana")
		Id.CRITICAL_CHANCE:
			return ("Percentage chance for a successful direct damage hit to critically strike. "
					+ "No primary or level contribution. Add Flat 20 adds twenty "
					+ "percentage points; increased and More scale the combined value before "
					+ "clamping to %s%%..%s%%. Applies to attacks and spells after Accuracy succeeds; "
					+ "it does not turn a miss or resist into a hit.") % [
					CombatRules.get_number("critical_chance_min_percent"),
					CombatRules.get_number("critical_chance_max_percent")]
		Id.CRITICAL_DAMAGE:
			return ("Bonus percentage points added to the base critical damage multiplier, "
					+ "not the total damage percentage. Minimum zero and no upper cap. "
					+ "Zero bonus deals %s%% total damage on a critical; +50 bonus deals %s%%. "
					+ "Flat bonuses add percentage points; increased and More scale the bonus value. "
					+ "No primary or level contribution. Applies to critical damage from attacks and spells.") % [
					CombatRules.get_number("base_critical_multiplier") * 100.0,
					CombatRules.get_number("base_critical_multiplier") * 100.0 + 50.0]
		Id.ARMOR:
			return ("Nonnegative, uncapped rating that reduces incoming Physical damage from attacks "
					+ "or spells. Flat bonuses apply before combined increased and independent More. "
					+ "No primary or level contribution. Damage reduction has diminishing returns and "
					+ "caps at %s%% at %s rating; extra rating remains available to offset later debuffs. "
					+ "Incoming Armor Penetration can reduce its effective rating for each Physical component. "
					+ "It does not reduce Magic damage or change Accuracy.") % [
					CombatRules.get_number("armor_max_reduction") * 100.0,
					CombatRules.get_number("armor_rating_at_cap")]
		Id.ARMOR_PENETRATION:
			return ("Percentage of the target's Armor ignored by outgoing Physical damage from "
					+ "attacks or spells, before the Armor reduction curve. No primary "
					+ "or level contribution. Add Flat 20 adds twenty percentage points; increased and "
					+ "More scale the combined value before clamping to %s%%..%s%%. "
					+ "Does not permanently reduce target Armor, affect Magic damage or change Accuracy.") % [
					CombatRules.get_number("armor_penetration_min_percent"),
					CombatRules.get_number("armor_penetration_max_percent")]
		Id.CARRY_CAPACITY:
			return ("Weight threshold for encumbrance. Startup base plus the authored Strength derivation "
					+ "and other flat bonuses, then increased and More modifiers. Minimum %s with "
					+ "no upper cap. Movement slows when Carried Weight exceeds this threshold.") % CombatRules.get_number("minimum_capacity")
		Id.CARRIED_WEIGHT:
			return ("Actual carried weight in weight units. Starts at zero, with no primary or level "
					+ "contribution. Flat weight adjustments apply before increased and More modifiers. "
					+ "The final weight is nonnegative and uncapped. Movement slows above Carry Capacity. "
					+ "Set Carried Weight in F3 to test loads above and below that threshold.")
		Id.ACCURACY_RATING:
			return ("Action-specific rating, not percentage points of hit chance. Each governing "
					+ "primary point grants %s rating: Strength for Brutality, Dexterity for Finesse, "
					+ "Intellect for spells. Nonnegative and uncapped. One shared attack/spell "
					+ "check uses level-based chance ceilings; a target ten levels higher caps at 10%%.") \
					% CombatRules.get_number("governing_accuracy_per_point")
		Id.MAGIC_POWER:
			return ("Flat offensive power for spells. The Attribute Derivations effect supplies Intellect's contribution before "
					+ "other flat bonuses, combined increased percentages and independent More "
					+ "multipliers. Authored effect coefficients convert power into damage. "
					+ "Nonnegative and uncapped.")
		Id.PHYSICAL_POWER:
			return ("Flat physical power for the relevant attack. Brutality receives %s per "
					+ "Strength; Finesse, including bows, receives %s per Dexterity. Only one "
					+ "primary contributes. Applicable modifiers follow the ordinary pipeline. "
					+ "An authored attack coefficient converts power into damage. Nonnegative and uncapped.") % [
					CombatRules.get_number("strength_physical_power_per_point"),
					CombatRules.get_number("dexterity_physical_power_per_point")]
		Id.MOVEMENT_SPEED:
			return ("Bonus percentage points to normal movement speed. Zero is normal, "
					+ "+20%% is twenty percent faster, and -100%% requests zero horizontal movement speed. "
					+ "Add Flat 1 adds one percentage point. Combined increased and independent More "
					+ "scale the accumulated bonus itself: 20 bonus with 20%% increased becomes 24, "
					+ "while zero bonus remains zero. Clamp only the final bonus to %s%%..+%s%%; "
					+ "underlying over-cap values remain available to offset later debuffs. "
					+ "No automatic primary/level contribution. Other gaits retain their authored proportions.") % [
					CombatRules.get_number("movement_speed_min_percent"),
					CombatRules.get_number("movement_speed_max_percent")]
		Id.ATTACK_SPEED, Id.CAST_SPEED:
			return ("Additive percentage bonus to %s animation playback. Add Flat 20 adds "
					+ "twenty percentage points. Zero is normal speed. The final bonus is capped "
					+ "at +%s%% and sampled when the ability starts.") % [
					display_name(id).get_slice(" ", 0).to_lower(),
					CombatRules.get_number("action_speed_max_percent")]
	return "Unknown attribute ID. No behavior is defined for this value."


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


static func _regeneration_description(resource_name: String) -> String:
	return ("%s points restored per second while alive. Startup base plus flat bonuses, then "
			+ "combined increased percentages and independent More multipliers. Minimum zero; "
			+ "no upper cap. Applies in and out of combat. "
			+ "Primary attributes and maximum capacity do not increase this rate. "
			+ "Stops at capacity; cannot resurrect a dead actor.") % resource_name


static func _resistance_description(school: String) -> String:
	return ("Percentage reduction to incoming %s magic damage from attacks or spells. "
			+ "No primary contribution. Apply flat percentage-point bonuses, "
			+ "combined increased and independent More modifiers before clamping to %s%%..%s%%. "
			+ "Zero is neutral, positive values reduce damage and negative values amplify it. "
			+ "It does not affect physical damage or the Accuracy check that can display RESIST.") % [
			school,
			CombatRules.get_number("resistance_min_percent"),
			CombatRules.get_number("resistance_max_percent")]
