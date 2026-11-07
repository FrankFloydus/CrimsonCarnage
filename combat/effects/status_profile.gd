@tool
class_name StatusProfile
extends Resource
## Application rules for an independent status. Control state is authored with counted Granted Tags.

## Classifies status outcomes independently from the tags and modifiers that implement control.
enum Category {
	## An effect without a specific control classification.
	GENERAL,
	## Restricts movement while allowing actions that do not require movement.
	ROOT,
	## Reduces movement or another authored rate.
	SLOW,
	## Suppresses abilities configured to react to silence.
	SILENCE,
	## Prevents abilities and movement that honor the authored stun state.
	STUN,
	## Classifies fear for control rules and an actor's AI adapter.
	FEAR,
	## Classifies incapacitation that can optionally break on a qualifying hit.
	INCAPACITATION,
	## Blocks a selected cast school through its authored school-specific state.
	SCHOOL_LOCKOUT,
}

## Selects the single status quantity changed by its resistance attribute.
enum ResistanceEffect {
	## Applies the authored status without resistance scaling.
	NONE,
	## Reduces the status's probability of application.
	CHANCE,
	## Reduces the time a finite status remains on the target.
	DURATION,
	## Reduces the magnitude of the status's modifiers.
	MAGNITUDE,
}

## Identifies the control category independently from damage identity.
@export var category: Category = Category.GENERAL
## Chance to apply once requirements and immunity checks pass, as a fraction from zero to one.
@export_range(0.0, 1.0, 0.01) var chance: float = 1.0
## Any matching target tag rejects this status as immune.
@export var immunity_tags: PackedStringArray = PackedStringArray()
## Selects the one status quantity affected by Resistance. Damage always resolves separately.
@export var resistance_effect: ResistanceEffect = ResistanceEffect.NONE:
	set(value):
		resistance_effect = value
		notify_property_list_changed()
## Resistance attribute used in percentage points when a resistance effect is selected.
@export var resistance_attribute: CombatAttributes.Id = CombatAttributes.Id.NONE


func get_validation_error() -> StringName:
	if category not in Category.values() or resistance_effect not in ResistanceEffect.values() \
			or not is_finite(chance) or chance < 0.0 or chance > 1.0:
		return &"Effect.InvalidStatusProfile"
	if resistance_effect != ResistanceEffect.NONE \
			and not CombatAttributes.is_active(resistance_attribute):
		return &"Effect.InvalidStatusResistance"
	return &""


func get_resistance_fraction(target: ActorAttributes, tags: PackedStringArray) -> float:
	if resistance_effect == ResistanceEffect.NONE:
		return 0.0
	return clampf(target.get_value(resistance_attribute, tags) / 100.0, 0.0, 1.0)


func _validate_property(property: Dictionary) -> void:
	if property.name == &"resistance_attribute" and resistance_effect == ResistanceEffect.NONE:
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
