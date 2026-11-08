class_name ResourceSpendReceipt
extends RefCounted
## The immutable actual amounts spent by one committed activation transaction.

var _amounts: Dictionary[int, float] = {}


func _init() -> void:
	_amounts.make_read_only()


static func from_amounts(amounts: Dictionary[int, float]) -> ResourceSpendReceipt:
	var committed: Dictionary[int, float] = {}
	for attribute: int in amounts:
		if not CombatAttributes.is_current_resource(attribute) or not is_finite(amounts[attribute]) \
				or amounts[attribute] < 0.0:
			return null
		if amounts[attribute] > 0.0:
			committed[attribute] = amounts[attribute]
	committed.make_read_only()
	var receipt := ResourceSpendReceipt.new()
	receipt._amounts = committed
	return receipt


func get_spent(attribute: int) -> float:
	return _amounts.get(attribute, 0.0)


func get_amounts() -> Dictionary[int, float]:
	return _amounts
