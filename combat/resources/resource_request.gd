class_name ResourceRequest
extends RefCounted
## One signed Mana or Stamina transaction with an explicit reason and event policy.

## Classifies why Mana or Stamina changes and determines the allowed delta direction.
enum Reason {
	## Adds points as ordinary resource recovery, up to the pool's capacity.
	RESTORE,
	## Returns points from prior spending, up to the pool's current capacity.
	REFUND,
	## Removes points from the pool, down to zero.
	DRAIN,
}

var recipient: ActorAttributes
var delta: float
var resource: AmountDefinition.Pool
var reason: Reason
var allow_dead_recipient: bool = false
var publish_outcome: bool = true


func _init(
		recipient_attributes: ActorAttributes,
		requested_delta: float,
		pool: AmountDefinition.Pool = AmountDefinition.Pool.MANA,
		transaction_reason: Reason = Reason.RESTORE
) -> void:
	recipient = recipient_attributes
	delta = requested_delta
	resource = pool
	reason = transaction_reason
