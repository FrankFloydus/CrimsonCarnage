class_name AbilityChargePool
extends RefCounted
## Actor-owned charge state. A reservation and a spend are distinct.

var _capacity: int
var _recharge_seconds: float
var _parallel: bool
var _reserved: Dictionary[int, bool] = {}
var _spent: Dictionary[int, float] = {}
var _next_receipt: int = 1


func _init(definition: AbilityChargeDefinition) -> void:
	_capacity = definition.capacity
	_recharge_seconds = definition.recharge_seconds
	_parallel = definition.uses_parallel_recharge()


func matches(definition: AbilityChargeDefinition) -> bool:
	return (_capacity == definition.capacity and _recharge_seconds == definition.recharge_seconds
			and _parallel == definition.uses_parallel_recharge())


func available() -> int:
	return _capacity - _spent.size() - _reserved.size()


func reserve(cast_id: int) -> bool:
	if available() < 1 or _reserved.has(cast_id):
		return false
	_reserved[cast_id] = true
	return true


func release(cast_id: int) -> void:
	_reserved.erase(cast_id)


func spend(cast_id: int) -> int:
	if not _reserved.erase(cast_id):
		return 0
	var receipt := _next_receipt
	_next_receipt += 1
	_spent[receipt] = _recharge_seconds
	return receipt


func refund(receipt: int) -> bool:
	return _spent.erase(receipt)


func advance(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return
	var remaining := delta
	for receipt: int in _spent.keys():
		var clock := _spent[receipt] - (delta if _parallel else remaining)
		if clock > 1.0e-9:
			_spent[receipt] = clock
			if not _parallel:
				break
		else:
			_spent.erase(receipt)
			remaining = maxf(-clock, 0.0)


func get_remaining() -> float:
	if _spent.is_empty():
		return 0.0
	return _spent.values().min() if _parallel else _spent.values()[0]


## Saving a pool records recharge progress. In-flight reservations are cancelled on load.
func capture_recharge() -> Array[float]:
	var recharge: Array[float] = []
	recharge.assign(_spent.values())
	return recharge


## Rejects incompatible data atomically. Restoring requires no active reservations.
func restore_recharge(recharge: Array[float]) -> bool:
	if not _reserved.is_empty() or recharge.size() > _capacity:
		return false
	for remaining in recharge:
		if not is_finite(remaining) or remaining <= 0.0 or remaining > _recharge_seconds:
			return false
	_spent.clear()
	for remaining in recharge:
		_spent[_next_receipt] = remaining
		_next_receipt += 1
	return true
