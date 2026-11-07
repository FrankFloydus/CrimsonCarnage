@tool
class_name GameplayEffectDefinition
extends Resource
## Immutable direct-damage or retained modifier and tag payload.

## Direct Health damage or a set of owned stat adjustments.
enum Kind {
	## Applies the explicitly authored direct damage to Health once.
	DAMAGE = 0,
	## Retains an independently owned set of stat modifiers and optional tags.
	MODIFIERS = 2,
}
## Immediate damage or a retained modifier instance.
enum Timing {
	## Executes direct damage once on delivery.
	INSTANT = 0,
	## Retains modifiers for the authored duration or until explicitly removed.
	DURATION = 1,
}
## Selects Physical Power or Magic Power independently of the action's delivery.
enum DamageType {
	## Uses the action's applicable Physical Power contribution.
	PHYSICAL = 0,
	## Uses Magic Power from Intellect and other applicable bonuses.
	MAGIC = 1,
}
## The school of a Magic damage component, selecting its matching target Resistance.
enum MagicSchool {
	## Fire damage is reduced by Fire Resistance.
	FIRE = 0,
	## Cold damage is reduced by Cold Resistance.
	COLD = 1,
	## Lightning damage is reduced by Lightning Resistance.
	LIGHTNING = 2,
	## Void damage is reduced by Void Resistance.
	VOID = 3,
	## Necrotic damage is reduced by Necrotic Resistance.
	NECROTIC = 4,
}
## Chooses which player HUD strip shows a retained effect.
enum HudCategory {
	## Hides this effect from the HUD.
	NONE = 0,
	## Shows its icon in the left-to-right buff strip.
	BUFF = 1,
	## Shows its icon in the right-to-left debuff strip.
	DEBUFF = 2,
}

const DAMAGE_IDENTITY_TAGS: Array[String] = [
	"Damage.Physical", "Damage.Magic", "Damage.Fire", "Damage.Cold",
	"Damage.Lightning", "Damage.Void", "Damage.Necrotic",
]

## Stable identity for telemetry and locating authored modifier effects.
@export var effect_id: StringName = &""
## Human-readable name used in combat feedback and the log.
@export var display_name: String = ""
## Optional icon for this effect while it is retained on the player.
## Assign a HUD category to display it.
@export var icon: Texture2D
## Display group for the retained icon. This choice affects presentation only.
@export var hud_category: HudCategory = HudCategory.NONE
## Direct damage changes Health; Modifiers retains owned stat adjustments and optional tags.
@export var kind: Kind = Kind.DAMAGE
## Direct damage must be Instant; modifier payloads must use Duration.
@export var timing: Timing = Timing.INSTANT
## Flat direct damage before adding the applicable Power contribution, in Health units.
@export_range(0.0, 100000.0, 0.1, "or_greater") var base_magnitude: float = 0.0
## Damage added per point of applicable Power. Weapon payloads use their base-cycle coefficient.
## Authored per effect; this is not a universal spell-damage conversion rate.
@export_range(0.0, 100.0, 0.01, "or_greater") var power_coefficient: float = 0.0
## Adds the bound physical weapon's rolled damage and Physical Power contribution.
## Requires an instant Physical damage payload on a physical weapon Attack.
@export var use_weapon_damage: bool = false
## Share of the entire weapon contribution assigned to this component. An ordinary hit uses 1.0.
## Split this value between components when authoring a multi-component weapon hit.
@export_range(0.0, 100.0, 0.01, "or_greater") var weapon_power_share: float = 1.0
## Physical uses Physical Power; Magic uses Magic Power and its matching school Resistance.
## Neither damage type applies a hidden status or changes the attack/spell Accuracy check.
@export var damage_type: DamageType = DamageType.PHYSICAL
## School used only by Magic damage, selecting Fire/Cold/Lightning/Void/Necrotic Resistance.
## Physical damage and retained modifiers ignore this field. Fire is the default for existing spells.
@export var magic_school: MagicSchool = MagicSchool.FIRE
## Additional effect/damage tags used to select applicable stat modifiers for this payload.
## Ability/Weapon hierarchies are reserved; damage identity tags must match the type/school fields.
@export var damage_tags: PackedStringArray = PackedStringArray()
## Counted tags granted for the lifetime of a retained modifier instance.
@export var granted_tags: PackedStringArray = PackedStringArray()
## All listed tags must be present on the target before application.
@export var required_target_tags: PackedStringArray = PackedStringArray()
## Any matching target tag prevents application; parent tags match descendants.
@export var blocked_target_tags: PackedStringArray = PackedStringArray(["State.Dead"])
## Modifier lifetime in seconds. Zero retains the instance until explicitly removed.
@export_range(0.0, 3600.0, 0.1, "or_greater") var duration: float = 0.0
## Owned flat, increased, more or Set Base stat adjustments retained by a modifier instance.
## Current resources use their explicit APIs rather than persistent modifiers.
@export var modifiers: Array[AttributeModifier] = []


func get_validation_error() -> StringName:
	for tag in damage_tags:
		if AttributeModifier._has_match(PackedStringArray([tag]), "Ability") \
				or AttributeModifier._has_match(PackedStringArray([tag]), "Weapon"):
			return &"Effect.ReservedContextTag"
		if kind == Kind.DAMAGE:
			var identity := _damage_identity(tag)
			var type_tag := "Damage.Physical" if damage_type == DamageType.PHYSICAL else "Damage.Magic"
			if not identity.is_empty() and identity != type_tag and identity != get_magic_school_tag():
				return &"Effect.ConflictingDamageTag"
	if kind not in [Kind.DAMAGE, Kind.MODIFIERS]:
		return &"Effect.InvalidKind"
	if damage_type not in [DamageType.PHYSICAL, DamageType.MAGIC]:
		return &"Effect.InvalidDamageType"
	if not is_finite(base_magnitude) or base_magnitude < 0.0:
		return &"Effect.InvalidMagnitude"
	if not is_finite(power_coefficient) or power_coefficient < 0.0:
		return &"Effect.InvalidPowerCoefficient"
	if not is_finite(weapon_power_share) or weapon_power_share < 0.0:
		return &"Effect.InvalidWeaponShare"
	if not is_finite(duration) or duration < 0.0:
		return &"Effect.InvalidDuration"
	if kind == Kind.DAMAGE:
		if timing != Timing.INSTANT:
			return &"Effect.DamageRequiresInstant"
		if damage_type == DamageType.MAGIC and magic_school not in MagicSchool.values():
			return &"Effect.InvalidMagicSchool"
		if use_weapon_damage and damage_type != DamageType.PHYSICAL:
			return &"Effect.WeaponDamageRequiresPhysicalHit"
		if not granted_tags.is_empty() or not modifiers.is_empty():
			return &"Effect.DamageCannotRetainModifiers"
	else:
		if timing != Timing.DURATION or use_weapon_damage:
			return &"Effect.ModifiersRequireDuration"
		for modifier in modifiers:
			if modifier == null or not CombatAttributes.is_active(modifier.attribute) \
					or CombatAttributes.is_current_resource(modifier.attribute) \
					or not is_finite(modifier.value) \
					or modifier.operation not in AttributeModifier.Operation.values():
				return &"Effect.InvalidModifier"
	return &""


## Maps this component's authored school to one Resistance; Physical/modifier effects select none.
func get_resistance_attribute() -> int:
	if kind != Kind.DAMAGE or damage_type != DamageType.MAGIC:
		return CombatAttributes.Id.NONE
	match magic_school:
		MagicSchool.FIRE:
			return CombatAttributes.Id.FIRE_RESISTANCE
		MagicSchool.COLD:
			return CombatAttributes.Id.COLD_RESISTANCE
		MagicSchool.LIGHTNING:
			return CombatAttributes.Id.LIGHTNING_RESISTANCE
		MagicSchool.VOID:
			return CombatAttributes.Id.VOID_RESISTANCE
		MagicSchool.NECROTIC:
			return CombatAttributes.Id.NECROTIC_RESISTANCE
	return CombatAttributes.Id.NONE


## Canonical school tag for this Magic damage component; other effect kinds/types have none.
func get_magic_school_tag() -> String:
	if get_resistance_attribute() == CombatAttributes.Id.NONE:
		return ""
	match magic_school:
		MagicSchool.FIRE:
			return "Damage.Fire"
		MagicSchool.COLD:
			return "Damage.Cold"
		MagicSchool.LIGHTNING:
			return "Damage.Lightning"
		MagicSchool.VOID:
			return "Damage.Void"
		MagicSchool.NECROTIC:
			return "Damage.Necrotic"
	return ""


## Copies delivery tags and adds this effect's damage type, Magic school and direct timing.
func get_context_tags(ability_tags: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var result := ability_tags.duplicate()
	if kind == Kind.DAMAGE:
		# Each component owns its identity; a hybrid action cannot label every component as one school.
		for index in range(result.size() - 1, -1, -1):
			if not _damage_identity(result[index]).is_empty():
				result.remove_at(index)
	for tag in damage_tags:
		if not result.has(tag):
			result.append(tag)
	if kind == Kind.DAMAGE:
		var type_tag := "Damage.Physical" if damage_type == DamageType.PHYSICAL else "Damage.Magic"
		for tag in [type_tag, "Damage.Direct"]:
			if not result.has(tag):
				result.append(tag)
		var school_tag := get_magic_school_tag()
		if not school_tag.is_empty() and not result.has(school_tag):
			result.append(school_tag)
	return result


static func _damage_identity(tag: String) -> String:
	for identity: String in DAMAGE_IDENTITY_TAGS:
		if tag == identity or tag.begins_with(identity + "."):
			return identity
	return ""
