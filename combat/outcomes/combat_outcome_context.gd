class_name CombatOutcomeContext
extends RefCounted
## Detached execution attribution. Derivation preserves the root and changes only the local scope.

## When the payload was produced, independent of the delivery mechanism.
enum Timing {
	## The payload was produced by an immediate action or impact.
	DIRECT,
	## The payload was produced by a scheduled tick of a retained effect.
	PERIODIC,
	## The payload was produced by one pulse of an active channel.
	CHANNEL_PULSE,
}

## Combinable flags recording how the payload was produced or redirected.
enum Provenance {
	## Marks the execution's original attribution before any additional provenance flags are added.
	ORIGINAL = 1,
	## The payload copies another payload or one of its committed amount bases.
	COPIED = 2,
	## A reflection sent the payload back to another recipient.
	REFLECTED = 4,
	## An effect or payload moved between recipients while retaining its existing attribution.
	TRANSFERRED = 8,
	## An effect or reaction produced a follow-up in response to another outcome.
	RETALIATION = 16,
	## A pet produced the payload, independently of which owner receives credit.
	PET = 32,
}

## Actor roles recorded independently so detached or redirected actions preserve attribution.
enum Role {
	## The actor who requested the action.
	REQUESTER,
	## The actor who performed the action and supplies its execution-side stats.
	EXECUTING_ACTOR,
	## The actor from whom the payload first originated.
	ORIGINAL_SOURCE,
	## The actor credited with the result, such as a pet's owner.
	CREDITED_OWNER,
	## The actor whose resources paid for the activation.
	RESOURCE_PAYER,
	## The actor who owns the delivery, such as the creator of a detached projectile.
	DELIVERY_OWNER,
	## The actor against whom the current outcome was resolved.
	TARGET,
	## The actor selected to receive a follow-up transaction.
	REACTION_RECIPIENT,
}

static var _next_id: int = 1

var root_execution_id: int:
	get:
		return _execution.id if _execution != null else 0
var parent_event_id: int:
	get:
		return _parent_event_id
var attack_execution_id: int:
	get:
		return _attack_execution_id if _attack_execution_id > 0 else root_execution_id
var contact_id: int:
	get:
		return _contact_id
var tick_id: int:
	get:
		return _tick_id
var timing: Timing:
	get:
		return _timing
var delivery: StringName:
	get:
		return _delivery
var provenance: int:
	get:
		return _provenance
var depth: int:
	get:
		return _depth

var _execution: ExecutionScope
var _parent_event_id: int = 0
var _attack_execution_id: int = 0
var _contact_id: int = 0
var _tick_id: int = 0
var _timing: Timing = Timing.DIRECT
var _delivery: StringName = &""
var _provenance: int = Provenance.ORIGINAL
var _depth: int = 0
var _actor_ids: Dictionary[int, int] = {}


static func create(source: ActorAttributes = null) -> CombatOutcomeContext:
	var context := CombatOutcomeContext.new()
	context._execution = ExecutionScope.new()
	context._execution.id = allocate_id()
	if is_instance_valid(source):
		for role in [Role.REQUESTER, Role.EXECUTING_ACTOR, Role.ORIGINAL_SOURCE,
				Role.CREDITED_OWNER, Role.RESOURCE_PAYER, Role.DELIVERY_OWNER]:
			context._actor_ids[role] = source.get_instance_id()
	return context


static func allocate_id() -> int:
	var id := _next_id
	_next_id += 1
	return id


## Copies the attributed identity while allowing the actor to disappear independently.
func with_role(role: Role, actor: ActorAttributes) -> CombatOutcomeContext:
	return with_role_id(role, actor.get_instance_id() if is_instance_valid(actor) else 0)


func with_role_id(role: Role, id: int) -> CombatOutcomeContext:
	var context := _copy()
	context._actor_ids[role] = id
	return context


func actor_id(role: Role) -> int:
	return _actor_ids.get(role, 0)


func actor(role: Role) -> ActorAttributes:
	return resolve_actor(actor_id(role))


static func resolve_actor(id: int) -> ActorAttributes:
	if id > 0 and is_instance_id_valid(id):
		var attributes := instance_from_id(id) as ActorAttributes
		if attributes != null and not attributes.is_queued_for_deletion():
			return attributes
	return null


static func resolve_system(actor: ActorAttributes) -> AbilitySystem:
	if not is_instance_valid(actor):
		return null
	var system := AbilitySystem.find_for(actor)
	return system if system != null and system.attributes == actor else null


## A multi-contact attack can assign an attack identity before deriving its individual contacts.
func for_attack() -> CombatOutcomeContext:
	var context := _copy()
	context._attack_execution_id = allocate_id()
	context._contact_id = 0
	context._tick_id = 0
	return context


func for_contact(target: ActorAttributes = null) -> CombatOutcomeContext:
	var context := _copy()
	context._contact_id = allocate_id()
	context._tick_id = 0
	if is_instance_valid(target):
		context._actor_ids[Role.TARGET] = target.get_instance_id()
	return context


func with_timing(value: Timing) -> CombatOutcomeContext:
	var context := _copy()
	context._timing = value
	context._tick_id = allocate_id() if value != Timing.DIRECT else 0
	return context


func with_delivery(value: StringName) -> CombatOutcomeContext:
	var context := _copy()
	context._delivery = value
	return context


func with_provenance(added_flags: int) -> CombatOutcomeContext:
	var context := _copy()
	context._provenance |= added_flags
	return context


func for_child(
		outcome: CombatOutcome, recipient: ActorAttributes, added_provenance: int = 0
) -> CombatOutcomeContext:
	var context := with_role(Role.REACTION_RECIPIENT, recipient)
	context._parent_event_id = outcome.id
	context._provenance |= added_provenance
	context._depth += 1
	return context


func set_execution_reactions(definitions: Array[ReactionDefinition]) -> void:
	_execution.reactions = definitions.duplicate()


func get_execution_reactions() -> Array[ReactionDefinition]:
	return _execution.reactions.duplicate()


func set_execution_identity(ability_id: StringName, ability_name: String) -> void:
	_execution.ability_id = ability_id
	_execution.ability_name = ability_name


## Captures the source and other roles before any outcome in the batch can cause a stat change.
func capture_amount_basis(tags: PackedStringArray = PackedStringArray(), rank: int = 1) -> void:
	_execution.scope_tags = tags.duplicate()
	_execution.rank = rank
	_execution.amount_snapshot = _make_amount_context(actor(Role.TARGET),
			actor(Role.CREDITED_OWNER)).capture()


func set_spend_receipt(receipt: ResourceSpendReceipt) -> void:
	_execution.receipt = receipt


func make_amount_context(
		outcome: CombatOutcome, recipient: ActorAttributes
) -> AmountEvaluationContext:
	var evaluation := _make_amount_context(resolve_actor(outcome.target_id), recipient)
	evaluation.outcome = outcome
	evaluation.snapshot = _execution.amount_snapshot
	var data := outcome.get_event()
	evaluation.accumulator = float(data.get("accumulator", NAN))
	evaluation.stack_count = int(data.get("stack_count", 0))
	return evaluation


func make_payload_amount_context(target: ActorAttributes) -> AmountEvaluationContext:
	var evaluation := _make_amount_context(target, target)
	evaluation.snapshot = _execution.amount_snapshot
	return evaluation


func add_attribution(event: Dictionary) -> void:
	event["root_execution_id"] = root_execution_id
	event["parent_event_id"] = parent_event_id
	event["attack_execution_id"] = attack_execution_id
	event["contact_id"] = contact_id
	event["tick_id"] = tick_id
	event["timing"] = timing
	event["delivery"] = delivery
	event["provenance"] = provenance
	event["requester_id"] = actor_id(Role.REQUESTER)
	event["executing_actor_id"] = actor_id(Role.EXECUTING_ACTOR)
	event["original_source_id"] = actor_id(Role.ORIGINAL_SOURCE)
	event["credited_owner_id"] = actor_id(Role.CREDITED_OWNER)
	event["resource_payer_id"] = actor_id(Role.RESOURCE_PAYER)
	event["delivery_owner_id"] = actor_id(Role.DELIVERY_OWNER)
	event["reaction_recipient_id"] = actor_id(Role.REACTION_RECIPIENT)
	if not event.has("source_id"):
		event["source_id"] = actor_id(Role.ORIGINAL_SOURCE)
	if not event.has("ability_id"):
		event["ability_id"] = _execution.ability_id
	if not event.has("ability_name"):
		event["ability_name"] = _execution.ability_name
	if not event.has("ability_tags"):
		event["ability_tags"] = _execution.scope_tags


func _make_amount_context(target: ActorAttributes, recipient: ActorAttributes) -> AmountEvaluationContext:
	var evaluation := AmountEvaluationContext.new()
	evaluation.source = actor(Role.EXECUTING_ACTOR)
	evaluation.target = target
	evaluation.recipient = recipient
	evaluation.payer = actor(Role.RESOURCE_PAYER)
	evaluation.scope_tags = _execution.scope_tags
	evaluation.rank = _execution.rank
	evaluation.spend_receipt = _execution.receipt
	return evaluation


func _copy() -> CombatOutcomeContext:
	var context := CombatOutcomeContext.new()
	context._execution = _execution
	context._parent_event_id = _parent_event_id
	context._attack_execution_id = _attack_execution_id
	context._contact_id = _contact_id
	context._tick_id = _tick_id
	context._timing = _timing
	context._delivery = _delivery
	context._provenance = _provenance
	context._depth = _depth
	context._actor_ids = _actor_ids.duplicate()
	return context


class ExecutionScope extends RefCounted:
	var id: int
	var reactions: Array[ReactionDefinition] = []
	var reaction_fires: Dictionary[String, int] = {}
	var reaction_claims: Dictionary[String, bool] = {}
	var reaction_count: int = 0
	var receipt: ResourceSpendReceipt
	var amount_snapshot: AmountEvaluationContext
	var rank: int = 1
	var scope_tags: PackedStringArray = PackedStringArray()
	var ability_id: StringName
	var ability_name: String
