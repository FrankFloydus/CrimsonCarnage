@tool
class_name AbilityResourceCost
extends Resource
## Reserves a fixed cost or spends up to a cap from the current pool at activation.

## Current resource that pays this cost. A Health cost can be lethal.
@export var pool: AmountDefinition.Pool = AmountDefinition.Pool.MANA
## Minimum required debit. With variable spending disabled this is the complete cost.
@export var amount: AmountDefinition
## Reserves as much as is available up to Maximum, subject to Minimum.
@export var spend_up_to_maximum: bool = false:
	set(value):
		spend_up_to_maximum = value
		notify_property_list_changed()
## Largest debit when variable spending is enabled.
@export_range(0.0, 100000.0, 0.01, "or_greater") var maximum: float = 0.0


func _validate_property(property: Dictionary) -> void:
	if property.name == &"maximum" and not spend_up_to_maximum:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func get_validation_error() -> StringName:
	if not pool in AmountDefinition.Pool.values():
		return &"invalid_cost_attribute"
	if amount == null or not amount.get_validation_error(AmountDefinition.Unit.POINTS).is_empty() \
			or amount.source not in [AmountDefinition.Source.FIXED, AmountDefinition.Source.STAT_PERCENT,
					AmountDefinition.Source.RESOURCE_PERCENT, AmountDefinition.Source.LEVEL_CURVE]:
		return &"invalid_cost_amount"
	if amount.source == AmountDefinition.Source.FIXED and amount.evaluate() < 0.0:
		return &"invalid_cost_amount"
	if spend_up_to_maximum and (not is_finite(maximum) or maximum < 0.0):
		return &"invalid_maximum_cost"
	if spend_up_to_maximum and amount.source == AmountDefinition.Source.FIXED \
			and maximum < amount.evaluate():
		return &"invalid_maximum_cost"
	return &""


## Resolves the selected pool to the actor attribute used by the payment transaction.
func get_attribute() -> int:
	return AmountDefinition.pool_attribute(pool)


func get_debit(available: float, context: AmountEvaluationContext) -> float:
	var minimum := amount.evaluate(context)
	if not is_finite(minimum) or minimum < 0.0 or available + minimum * 1.0e-9 < minimum:
		return NAN
	if spend_up_to_maximum:
		return minf(available, maximum) if maximum >= minimum else NAN
	return minf(available, minimum)
