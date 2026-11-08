class_name PetCommandAdapter
extends RefCounted
## Coordinates command validation and payment around the owner domain's ability dispatch.

## Chooses when a validated pet command commits its resource cost.
enum PaymentMilestone {
	## Pay when accepting the command. A later dispatch failure leaves the cost spent.
	ACCEPTANCE,
	## Commit payment together with successful pet ability dispatch.
	EXECUTION,
}


class CommandRequest extends RefCounted:
	var ability_id: int
	var target_id: StringName
	var world_id: StringName
	var payer_id: StringName
	var executor_id: StringName
	var credited_owner_id: StringName
	var payment_milestone: PaymentMilestone = PaymentMilestone.EXECUTION

	func _copy() -> CommandRequest:
		var request := CommandRequest.new()
		request.ability_id = ability_id
		request.target_id = target_id
		request.world_id = world_id
		request.payer_id = payer_id
		request.executor_id = executor_id
		request.credited_owner_id = credited_owner_id
		request.payment_milestone = payment_milestone
		return request


var _ownership: PetOwnershipService
var _validate: Callable
var _pay_at_acceptance: Callable
var _dispatch: Callable
var _next_handle: int = 1
var _pending: Dictionary[int, CommandRequest] = {}
var _busy_owners: Dictionary[StringName, bool] = {}


## Validation checks actor availability, commandability, grant, target and payer permission.
## Dispatch owns the pet activation and, for execution payment, atomically commits the cost.
## Acceptance payment belongs to a distinct callback and is retained if a later command fails.
func _init(ownership: PetOwnershipService, validate: Callable, pay_at_acceptance: Callable,
		dispatch: Callable) -> void:
	_ownership = ownership
	_validate = validate
	_pay_at_acceptance = pay_at_acceptance
	_dispatch = dispatch


func accept(definition: CommandRequest) -> int:
	if _ownership == null or definition == null or not _validate.is_valid() or not _dispatch.is_valid() \
			or definition.ability_id <= 0 or definition.target_id.is_empty() \
			or definition.payer_id.is_empty() or definition.world_id.is_empty() \
			or definition.credited_owner_id.is_empty() \
			or not PaymentMilestone.values().has(definition.payment_milestone):
		return 0
	var request := definition._copy()
	var owner_id := request.credited_owner_id
	request.executor_id = _ownership.get_active_pet(owner_id, request.world_id)
	if request.executor_id.is_empty() or _busy_owners.has(owner_id):
		return 0
	_busy_owners[owner_id] = true
	var accepted := _is_valid(request)
	if accepted and request.payment_milestone == PaymentMilestone.ACCEPTANCE:
		accepted = _pay_at_acceptance.is_valid() and bool(_pay_at_acceptance.call(request._copy()))
	_busy_owners.erase(owner_id)
	if not accepted:
		return 0
	var handle := _next_handle
	_next_handle += 1
	_pending[handle] = request
	return handle


func execute(handle: int) -> bool:
	var request := _pending.get(handle) as CommandRequest
	if request == null or _busy_owners.has(request.credited_owner_id):
		return false
	_pending.erase(handle)
	_busy_owners[request.credited_owner_id] = true
	var executed := _is_valid(request) and bool(_dispatch.call(request._copy(),
		request.payment_milestone == PaymentMilestone.EXECUTION))
	_busy_owners.erase(request.credited_owner_id)
	return executed


func cancel(handle: int) -> bool:
	return _pending.erase(handle)


func cancel_owner(owner_id: StringName) -> void:
	for handle: int in _pending.keys():
		if _pending[handle].credited_owner_id == owner_id:
			cancel(handle)


func unload_world(world_id: StringName) -> void:
	for handle: int in _pending.keys():
		if _pending[handle].world_id == world_id:
			cancel(handle)


func _is_valid(request: CommandRequest) -> bool:
	return request.executor_id == _ownership.get_active_pet(request.credited_owner_id, request.world_id) \
		and bool(_validate.call(request._copy())) \
		and request.executor_id == _ownership.get_active_pet(request.credited_owner_id, request.world_id)
