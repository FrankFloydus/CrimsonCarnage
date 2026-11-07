class_name ResourceService
extends RefCounted
## Validates, clamps and commits Mana and Stamina changes against the actor's existing pools.


## Commits all requested pool debits together and returns the actual, immutable spend receipt.
static func commit_spend(
		recipient: ActorAttributes, costs: Dictionary[int, float]
) -> ResourceSpendReceipt:
	var spent: Dictionary[int, float] = {}
	if not is_instance_valid(recipient) or not recipient.commit_resource_spend(costs, spent):
		return null
	return ResourceSpendReceipt.from_amounts(spent)


static func resolve_and_commit(request: ResourceRequest) -> ResourceResult:
	if request == null or not is_instance_valid(request.recipient):
		return ResourceResult.new(request, 0.0, &"invalid_recipient")
	var attribute := AmountDefinition.pool_attribute(request.resource)
	if attribute == CombatAttributes.Id.HEALTH or attribute == CombatAttributes.Id.NONE:
		return ResourceResult.new(request, 0.0, &"invalid_resource")
	if not is_finite(request.delta) or not request.reason in ResourceRequest.Reason.values():
		return ResourceResult.new(request, 0.0, &"invalid_resource_delta")
	if (request.reason == ResourceRequest.Reason.DRAIN and request.delta > 0.0) \
			or (request.reason != ResourceRequest.Reason.DRAIN and request.delta < 0.0):
		return ResourceResult.new(request, 0.0, &"invalid_resource_direction")
	if not request.allow_dead_recipient and request.recipient.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return ResourceResult.new(request, 0.0, &"recipient_dead")
	var applied := request.recipient.modify_current(attribute, request.delta)
	return ResourceResult.new(request, applied)


## Clamped refunds for a cancelled activation, with actual deltas keyed by pool attribute.
## Health refunds cannot restore a dead payer and skip ordinary healing modifiers.
static func refund_spend(
		recipient: ActorAttributes, receipt: ResourceSpendReceipt
) -> Dictionary[int, float]:
	var refunded: Dictionary[int, float] = {}
	if receipt == null:
		return refunded
	for attribute: int in CombatAttributes.current_ids():
		var amount := receipt.get_spent(attribute)
		if amount <= 0.0 or not is_instance_valid(recipient):
			continue
		if attribute == CombatAttributes.Id.HEALTH:
			var request := HealingRequest.new(recipient, amount)
			request.mode = HealingRequest.Mode.SNAPSHOT_RESTORE
			var result := HealingResolver.resolve_and_commit(request)
			if result.committed:
				refunded[attribute] = result.actual_restoration
			continue
		var pool := AmountDefinition.Pool.MANA \
				if attribute == CombatAttributes.Id.MANA else AmountDefinition.Pool.STAMINA
		var request := ResourceRequest.new(recipient, amount, pool, ResourceRequest.Reason.REFUND)
		request.allow_dead_recipient = true
		request.publish_outcome = false
		var result := resolve_and_commit(request)
		if result.committed:
			refunded[attribute] = result.actual_delta
	return refunded
