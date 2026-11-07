@tool
class_name BreakOnDamageEffectComponent
extends GameplayEffectComponent
## Removes an active status after a qualifying committed contact or damage transaction.

## Selects which committed outcome breaks the retained effect.
enum Predicate {
	## Requires positive Health loss after all defenses.
	HEALTH_DAMAGE,
	## Accepts a damage transaction that was not rejected by immunity.
	ANY_DAMAGE_TRANSACTION,
	## Accepts an eligible hit even if a shield absorbs all damage.
	CONFIRMED_HIT,
}

## Selects confirmed contact, any damage transaction, or positive actual Health loss.
@export var predicate: Predicate = Predicate.HEALTH_DAMAGE
## Ignore damage from the same original actor that applied this status.
@export var exclude_status_source: bool = false
## Ignore outcomes carrying any of these ability tags, including descendants.
@export var excluded_ability_tags: PackedStringArray = PackedStringArray()


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if definition.timing == GameplayEffectDefinition.Timing.INSTANT \
			or predicate not in Predicate.values():
		return &"Effect.InvalidBreakOnDamage"
	return &""
