@tool
class_name DamageAccumulatorEffectComponent
extends GameplayEffectComponent
## Tracks qualifying committed damage and publishes one threshold outcome for its owner.

## Selects the numerical stage accumulated from a committed damage outcome.
enum AmountBasis {
	## Stores only the actual Health lost by the recipient.
	ACTUAL_HEALTH_LOSS,
	## Stores the resolved damage offered to Health before clamping to the current pool.
	AFTER_DEFENSES,
	## Stores the damage offered to prevention after Armor and Resistance.
	BEFORE_DEFENSES,
}

## Restricts which damage sources can contribute to this retained instance.
enum SourceScope {
	## Accepts any source that passes the remaining provenance filters.
	ANY,
	## Accepts only the original actor that applied this effect.
	APPLYING_SOURCE,
}

## Committed damage quantity added to this retained effect's total.
@export var amount_basis: AmountBasis = AmountBasis.ACTUAL_HEALTH_LOSS
## Optionally restrict contributions to damage attributed to the original effect source.
@export var source_scope: SourceScope = SourceScope.APPLYING_SOURCE
## Positive stored damage needed to publish On Effect Threshold. Zero waits for expiry.
@export_range(0.0, 1000000.0, 0.1, "or_greater") var threshold: float = 0.0:
	set(value):
		threshold = value
		notify_property_list_changed()
## Maximum positive transactions accumulated. Zero allows any count.
@export_range(0, 1000000, 1) var contribution_limit: int = 0
## Publish the remaining stored amount once when the effect naturally expires.
@export var publish_on_expiry: bool = false
## Allow copied, reflected, transferred or retaliation damage to contribute.
@export var allow_derived_damage: bool = false
## Remove the effect after publishing the threshold outcome.
@export var remove_on_threshold: bool = true


func get_validation_error(definition: GameplayEffectDefinition) -> StringName:
	if definition.timing == GameplayEffectDefinition.Timing.INSTANT \
			or amount_basis not in AmountBasis.values() or source_scope not in SourceScope.values() \
			or not is_finite(threshold) or threshold < 0.0 or contribution_limit < 0 \
			or (threshold <= 0.0 and not publish_on_expiry) \
			or (publish_on_expiry and definition.timing != GameplayEffectDefinition.Timing.DURATION):
		return &"Effect.InvalidDamageAccumulator"
	return &""


func _validate_property(property: Dictionary) -> void:
	if property.name == &"remove_on_threshold" and threshold <= 0.0:
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR
