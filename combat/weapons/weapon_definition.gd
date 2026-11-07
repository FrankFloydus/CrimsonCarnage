@tool
class_name WeaponDefinition
extends Resource
## Editable weapon identity and physical attack profile; caster weapons remain casting-only.
## Finesse physical attacks use Dexterity; Brutality physical attacks use Strength. Both use
## Physical Power. Caster weapons use Intellect for spells and cannot supply a physical attack.
## A shield is defensive equipment, outside this weapon catalogue. No implicit bonuses are added.

## Established weapon families. Family determines category and delivery without separate overrides.
enum Kind {
	## One-handed Finesse melee dagger; uses Dexterity and Physical Power.
	DAGGER_ONE_HAND = 0,
	## One-handed Finesse melee sword; uses Dexterity and Physical Power.
	SWORD_ONE_HAND = 1,
	## Two-handed Finesse melee sword; uses Dexterity and Physical Power.
	SWORD_TWO_HAND = 2,
	## Finesse projectile weapon; physical arrows use Dexterity and the full base firing cycle.
	BOW = 3,
	## One-handed Brutality melee mace; uses Strength and Physical Power.
	MACE_ONE_HAND = 4,
	## One-handed Brutality melee axe; uses Strength and Physical Power.
	AXE_ONE_HAND = 5,
	## Two-handed Brutality melee mace; uses Strength and Physical Power.
	MACE_TWO_HAND = 6,
	## Two-handed Brutality melee axe; uses Strength and Physical Power.
	AXE_TWO_HAND = 7,
	## Caster-specific ritual dagger. Its spells use Intellect; it has no physical melee profile.
	RITUAL_DAGGER = 8,
	## Caster-specific scepter. Its spells use Intellect; it has no physical melee profile.
	SCEPTER = 9,
	## Caster-specific staff. Its spells use Intellect; it has no physical melee profile.
	STAFF = 10,
	## Caster-specific focus. Its spells use Intellect; it has no physical melee profile.
	FOCUS = 11,
}

## Governing weapon category. A physical action uses exactly one of Finesse or Brutality.
enum Category {
	## Dexterity-governed physical weapons: daggers, swords and bows.
	FINESSE,
	## Strength-governed physical weapons: one-handed and two-handed axes and maces.
	BRUTALITY,
	## Casting-only weapons outside Finesse and Brutality; spells use Intellect.
	CASTER,
	## Unknown weapon family. Validation rejects use as a weapon profile.
	INVALID,
}

## How this weapon family delivers its ordinary action; independent of its damage amount.
enum Delivery {
	## Physical attack delivered by a melee execution and its contact window.
	MELEE,
	## Physical bow attack delivered by a projectile; flight time does not increase its Power.
	PROJECTILE,
	## Spellcasting with a caster weapon. This does not give the weapon a physical attack.
	SPELL,
	## Unknown family with no valid delivery.
	INVALID,
}

## Authored identifier for this weapon profile; does not grant abilities or equip an item.
@export var weapon_id: StringName = &""

## Human-readable weapon name shown by testing and authoring tools.
@export var display_name: String = "Weapon"

## Weapon family selects Finesse/Dexterity, Brutality/Strength, or casting/Intellect.
## Ritual dagger, scepter, staff and focus cannot supply a physical weapon attack.
@export var kind: Kind = Kind.SWORD_ONE_HAND:
	set(value):
		kind = value
		notify_property_list_changed()

## Minimum physical damage before adding the Physical Power contribution.
## Used only by Finesse and Brutality weapons.
@export_range(0.0, 10000.0, 0.1, "or_greater") var physical_damage_min: float = 0.0

## Maximum physical damage before Physical Power; must be at least the minimum damage.
## Used only by Finesse and Brutality weapons.
@export_range(0.0, 10000.0, 0.1, "or_greater") var physical_damage_max: float = 0.0

## Complete authored base attack cycle in seconds; physical animations fit this duration.
## It also supplies the ordinary Physical Power coefficient. Bow flight and extra holding time
## are excluded. Used only by Finesse and Brutality weapons.
@export_range(0.001, 60.0, 0.001, "or_greater") var base_attack_cycle: float = 1.0


func _validate_property(property: Dictionary) -> void:
	if property.name in [&"physical_damage_min", &"physical_damage_max", &"base_attack_cycle"] \
			and not is_physical_weapon():
		property.usage &= ~PROPERTY_USAGE_EDITOR


## Returns the family-derived category; unknown serialized kinds return INVALID.
func get_category() -> Category:
	match kind:
		Kind.DAGGER_ONE_HAND, Kind.SWORD_ONE_HAND, Kind.SWORD_TWO_HAND, Kind.BOW:
			return Category.FINESSE
		Kind.MACE_ONE_HAND, Kind.AXE_ONE_HAND, Kind.MACE_TWO_HAND, Kind.AXE_TWO_HAND:
			return Category.BRUTALITY
		Kind.RITUAL_DAGGER, Kind.SCEPTER, Kind.STAFF, Kind.FOCUS:
			return Category.CASTER
	return Category.INVALID


## Returns melee for physical melee families, projectile for bows and spell for caster weapons.
func get_delivery() -> Delivery:
	if kind == Kind.BOW:
		return Delivery.PROJECTILE
	match get_category():
		Category.FINESSE, Category.BRUTALITY:
			return Delivery.MELEE
		Category.CASTER:
			return Delivery.SPELL
	return Delivery.INVALID


## Returns Dexterity for Finesse, Strength for Brutality, Intellect for casters, or NONE if invalid.
func get_governing_attribute() -> CombatAttributes.Id:
	match get_category():
		Category.FINESSE:
			return CombatAttributes.Id.DEXTERITY
		Category.BRUTALITY:
			return CombatAttributes.Id.STRENGTH
		Category.CASTER:
			return CombatAttributes.Id.INTELLECT
	return CombatAttributes.Id.NONE


## Returns the category scope used by Power and accuracy queries, plus Weapon.Bow for bows.
## These weapon tags describe the profile; the ability supplies its Attack or Spell action tags.
func get_context_tags() -> PackedStringArray:
	var tags := PackedStringArray()
	match get_category():
		Category.FINESSE:
			tags.append("Weapon.Finesse")
		Category.BRUTALITY:
			tags.append("Weapon.Brutality")
		Category.CASTER:
			tags.append("Weapon.Caster")
	if kind == Kind.BOW:
		tags.append("Weapon.Bow")
	return tags


## True only for Finesse and Brutality families that can supply a physical attack profile.
func is_physical_weapon() -> bool:
	return get_category() in [Category.FINESSE, Category.BRUTALITY]


## The coefficient uses immutable authored timing, never current playback or projectile travel.
func get_power_coefficient() -> float:
	return base_attack_cycle if is_physical_weapon() else 0.0


## Returns an authoring error for an unknown family or invalid physical range/cycle; empty is valid.
## Caster-only profiles ignore hidden physical fields and remain ineligible for physical attacks.
func get_validation_error() -> String:
	if get_category() == Category.INVALID:
		return "Weapon has an unknown family."
	if not is_physical_weapon():
		return ""
	if not is_finite(physical_damage_min) or physical_damage_min < 0.0:
		return "Weapon minimum physical damage must be finite and nonnegative."
	if not is_finite(physical_damage_max) or physical_damage_max < physical_damage_min:
		return "Weapon maximum physical damage must be finite and at least the minimum."
	if not is_finite(base_attack_cycle) or base_attack_cycle <= 0.0:
		return "Weapon base attack cycle must be finite and positive."
	return ""


## Validates a physical attack's weapon reference, rejecting caster-only profiles explicitly.
func get_physical_attack_error() -> String:
	var error := get_validation_error()
	if not error.is_empty():
		return error
	if not is_physical_weapon():
		return "Caster weapons cannot supply a physical weapon attack."
	return ""
