@tool
class_name DamageDefenseEffectComponent
extends GameplayEffectComponent
## An ordered damage policy owned by one retained effect.

## Selects the resolution stage and effect of this damage defense.
enum Mode {
	## Rejects damage matching the configured categories.
	IMMUNITY,
	## Rejects a matching contact payload without redirecting it.
	DEFLECT,
	## Redirects a matching contact payload to its original source.
	REFLECT,
	## Reduces a fraction after Armor and Resistance.
	BLOCK,
	## Consumes a finite prevention budget after Block.
	ABSORB,
}

## Immunity rejects matching damage. Deflection rejects a contact. Reflection redirects a contact.
## Block reduces damage after Armor or Resistance. Absorb spends a separate finite budget.
@export var mode: Mode = Mode.ABSORB:
	set(value):
		mode = value
		notify_property_list_changed()
## Matches any canonical damage/context tag or descendant. Empty matches all damage.
@export var damage_tags: PackedStringArray = PackedStringArray()
## All owner tags required to use the policy, such as a granted off-hand shield tag.
@export var required_owner_tags: PackedStringArray = PackedStringArray()
## Any owner tag that temporarily disables this policy while retaining its state.
@export var blocked_owner_tags: PackedStringArray = PackedStringArray()
## Full facing arc centered on the owner's forward axis. Zero ignores facing.
@export_range(0.0, 360.0, 1.0, "suffix:°") var front_arc_degrees: float = 0.0
## Lower priorities run first within the same stage. Ties use effect and component order.
@export var priority: int = 0
## Fraction reduced by Block, or fraction absorbed per transaction before the budget limit.
@export_range(0.0, 1.0, 0.01) var fraction: float = 1.0
## Initial Health damage budget for an Absorb policy, in Health points.
@export_range(0.0, 100000.0, 0.1, "or_greater") var capacity: float = 0.0
## Maximum budget after recasts. Zero keeps the original budget and prevents refills.
@export_range(0.0, 100000.0, 0.1, "or_greater") var recast_capacity: float = 0.0
## Removes the whole owning effect as soon as the Absorb budget reaches zero.
@export var remove_when_depleted: bool = true
## Redirects attached status specs with the matching damage when a contact is reflected.
@export var reflect_attached_statuses: bool = true
## Number of contacts this deflection or reflection can stop. Zero uses the effect's lifetime.
@export_range(0, 1000, 1, "or_greater") var contact_uses: int = 0


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if definition.timing == GameplayEffectDefinition.Timing.INSTANT \
			or mode not in Mode.values() \
			or not is_finite(front_arc_degrees) or front_arc_degrees < 0.0 or front_arc_degrees > 360.0:
		return &"Effect.InvalidDamageDefense"
	if mode in [Mode.BLOCK, Mode.ABSORB] and (not is_finite(fraction) or fraction < 0.0 or fraction > 1.0):
		return &"Effect.InvalidDamageDefenseFraction"
	if mode == Mode.ABSORB and (not is_finite(capacity) or capacity <= 0.0 or fraction <= 0.0 \
			or not is_finite(recast_capacity) or recast_capacity < 0.0 \
			or (recast_capacity > 0.0 and recast_capacity < capacity)):
		return &"Effect.InvalidAbsorptionPool"
	if get_contact_uses() < 0:
		return &"Effect.InvalidDefenseContactUses"
	return &""


func get_contact_uses() -> int:
	return contact_uses if mode in [Mode.DEFLECT, Mode.REFLECT] else 0


func _validate_property(property: Dictionary) -> void:
	match StringName(property.name):
		&"priority":
			if mode == Mode.IMMUNITY:
				property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
		&"fraction":
			if mode not in [Mode.BLOCK, Mode.ABSORB]:
				property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
		&"capacity", &"recast_capacity", &"remove_when_depleted":
			if mode != Mode.ABSORB:
				property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
		&"reflect_attached_statuses":
			if mode != Mode.REFLECT:
				property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
		&"contact_uses":
			if mode not in [Mode.DEFLECT, Mode.REFLECT]:
				property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


func matches(spec: GameplayEffectSpec) -> bool:
	if not spec.settings.is_damage_effect():
		return false
	var tags := spec.settings.get_payload_context_tags(spec.context)
	for query in damage_tags:
		if AttributeModifier._has_match(tags, query):
			return true
	return damage_tags.is_empty()
