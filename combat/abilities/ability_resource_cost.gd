@tool
class_name AbilityResourceCost
extends Resource
## Reserves a fixed cost or spends up to a cap from the current pool at activation.

## Unit required for the amount drawn from the pool.
const AMOUNT_UNIT := AmountDefinition.Unit.POINTS
## Amount sources that can be evaluated before the cast spends its resources.
const AMOUNT_SOURCES := [
	AmountDefinition.Source.FIXED,
	AmountDefinition.Source.STAT_PERCENT,
	AmountDefinition.Source.RESOURCE_PERCENT,
	AmountDefinition.Source.LEVEL_CURVE,
]

## Current resource that pays this cost. A Health cost can be lethal.
@export var pool: AmountDefinition.Pool = AmountDefinition.Pool.MANA
## Minimum required debit. With variable spending disabled this is the complete cost.
@export var amount: AmountDefinition:
	set(value):
		if amount == value:
			return
		if Engine.is_editor_hint() and amount != null:
			amount.property_list_changed.disconnect(notify_property_list_changed)
		amount = value
		if Engine.is_editor_hint() and amount != null:
			amount.property_list_changed.connect(notify_property_list_changed)
		notify_property_list_changed()
## For Resource Percent, calculate from the payer's live payment pool and the selected resource basis.
@export var use_payment_pool: bool = false
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
	elif property.name == &"use_payment_pool" \
			and (amount == null or amount.source != AmountDefinition.Source.RESOURCE_PERCENT):
		property.usage &= ~PROPERTY_USAGE_EDITOR


func get_validation_error() -> StringName:
	if not pool in AmountDefinition.Pool.values():
		return &"invalid_cost_attribute"
	if amount == null or amount.source not in AMOUNT_SOURCES:
		return &"invalid_cost_amount"
	var payer_pool: int = pool if uses_payment_pool() else -1
	if not amount.get_validation_error(AMOUNT_UNIT, payer_pool).is_empty():
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


## Reports whether Resource Percent reads the payer's live payment pool.
func uses_payment_pool() -> bool:
	return use_payment_pool and amount != null and amount.source == AmountDefinition.Source.RESOURCE_PERCENT


func get_debit(available: float, context: AmountEvaluationContext) -> float:
	var payer_pool: int = pool if uses_payment_pool() else -1
	var minimum := amount.evaluate(context, payer_pool)
	if not is_finite(minimum) or minimum < 0.0 or available + minimum * 1.0e-9 < minimum:
		return NAN
	if spend_up_to_maximum:
		return minf(available, maximum) if maximum >= minimum else NAN
	return minf(available, minimum)
