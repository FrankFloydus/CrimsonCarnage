class_name CombatOutcomeDispatcher
extends RefCounted
## Main-thread commit queue shared by actor systems. Child outcomes run after the current event.

const MAX_REACTION_DEPTH: int = 8
const MAX_SECONDARY_FIRES_PER_EXECUTION: int = 4096

static var _queue: Array[Delivery] = []
static var _subscribers: Dictionary[int, Subscription] = {}
static var _batch_depth: int = 0
static var _dispatching: bool = false


## Opens a synchronous commit group. The caller must close it on every exit path.
static func begin_batch() -> void:
	_batch_depth += 1


static func end_batch() -> void:
	assert(_batch_depth > 0, "An outcome batch was ended without being opened.")
	_batch_depth -= 1
	_flush()


static func publish(
		context: CombatOutcomeContext, event: Dictionary,
		reactions: Array[ReactionDefinition] = [], attachment_id: int = 0
) -> CombatOutcome:
	var attribution := context if context != null else CombatOutcomeContext.create()
	if event.has("target_id"):
		attribution = attribution.with_role_id(CombatOutcomeContext.Role.TARGET, int(event["target_id"]))
	var outcome := CombatOutcome.new(attribution, event)
	publish_committed(outcome, reactions, attachment_id)
	return outcome


## Queues a committed identity once even when a delivery callback is replayed.
static func publish_committed(
		outcome: CombatOutcome, reactions: Array[ReactionDefinition] = [], attachment_id: int = 0
) -> void:
	if outcome == null or outcome._published:
		return
	outcome._published = true
	var delivery := Delivery.new()
	delivery.outcome = outcome
	delivery.reactions = reactions.duplicate()
	delivery.attachment_id = attachment_id
	_queue.append(delivery)
	_flush()


## Active-effect observers own this handle and should unsubscribe at removal.
static func subscribe(owner: Object, callback: Callable) -> int:
	if not is_instance_valid(owner) or not callback.is_valid():
		return 0
	var handle := CombatOutcomeContext.allocate_id()
	var subscription := Subscription.new()
	subscription.owner = weakref(owner)
	subscription.callback = callback
	_subscribers[handle] = subscription
	return handle


## Adds an effect-owned reaction attachment without redelivering the originating outcome.
static func enqueue_scoped(
		outcome: CombatOutcome, reactions: Array[ReactionDefinition], attachment_id: int,
		owner_active: Callable = Callable(), attack_use: Callable = Callable()
) -> void:
	if outcome == null or attachment_id <= 0 or outcome._scoped_deliveries.has(attachment_id):
		return
	outcome._scoped_deliveries[attachment_id] = true
	var delivery := Delivery.new()
	delivery.outcome = outcome
	delivery.reactions = reactions.duplicate()
	delivery.attachment_id = attachment_id
	delivery.scoped = true
	delivery.owner_active = owner_active
	delivery.attack_use = attack_use
	_queue.append(delivery)
	_flush()


static func unsubscribe(handle: int) -> void:
	_subscribers.erase(handle)


static func _flush() -> void:
	if _dispatching or _batch_depth > 0:
		return
	_dispatching = true
	var cursor := 0
	while cursor < _queue.size() and _batch_depth == 0:
		var delivery := _queue[cursor]
		cursor += 1
		_dispatch(delivery)
	if cursor == _queue.size():
		_queue.clear()
	else:
		_queue = _queue.slice(cursor)
	_dispatching = false


static func _dispatch(delivery: Delivery) -> void:
	var outcome := delivery.outcome
	if delivery.scoped:
		if delivery.owner_active.is_null() or (delivery.owner_active.is_valid() \
				and bool(delivery.owner_active.call())):
			_run_reactions(outcome, delivery.reactions, "owned_effect", delivery.attachment_id,
					delivery.attack_use)
		return
	if outcome.kind == CombatOutcome.Kind.HEALING or outcome.kind == CombatOutcome.Kind.RESOURCE:
		_emit_transaction(outcome)
	for handle: int in _subscribers.keys():
		var subscription: Subscription = _subscribers.get(handle)
		if subscription == null:
			continue
		if subscription.owner.get_ref() == null or not subscription.callback.is_valid():
			unsubscribe(handle)
			continue
		subscription.callback.call(outcome)
	_run_reactions(outcome, delivery.reactions, "payload", delivery.attachment_id)
	_run_reactions(outcome, outcome.context.get_execution_reactions(), "execution", 0)


static func _run_reactions(
		outcome: CombatOutcome, reactions: Array[ReactionDefinition], origin: String, attachment_id: int,
		attack_use: Callable = Callable()
) -> void:
	var scope := outcome.context._execution
	for index in reactions.size():
		var reaction := reactions[index]
		if reaction == null or not reaction.matches(outcome):
			continue
		var reason := reaction.get_validation_error()
		if reason.is_empty() and outcome.context.depth >= MAX_REACTION_DEPTH:
			reason = &"reaction_depth"
		if reason.is_empty() and outcome.context.depth > 0 \
				and scope.reaction_count >= MAX_SECONDARY_FIRES_PER_EXECUTION:
			reason = &"execution_reaction_budget"
		if not reason.is_empty():
			_trace_suppressed(outcome, reaction, origin, reason)
			continue
		var recipients := reaction.resolve_recipients(outcome)
		if recipients.is_empty():
			_trace_suppressed(outcome, reaction, origin, &"recipient_unavailable")
			continue
		var definition_id := attachment_id if attachment_id > 0 else reaction.get_instance_id()
		var attachment_key := "%s:%d:%d" % [origin, definition_id, index]
		reason = reaction.claim(outcome, attachment_key, attack_use)
		if not reason.is_empty():
			_trace_suppressed(outcome, reaction, origin, reason)
			continue
		if outcome.context.depth > 0:
			scope.reaction_count += 1
		for recipient in recipients:
			if not is_instance_valid(recipient) or recipient.is_queued_for_deletion():
				continue
			var flags := CombatOutcomeContext.Provenance.RETALIATION \
					if outcome.kind == CombatOutcome.Kind.EFFECT_THRESHOLD else 0
			var context := outcome.context.for_child(outcome, recipient, flags)
			for action in reaction.actions:
				if not is_instance_valid(recipient) or recipient.is_queued_for_deletion():
					break
				action.execute(outcome, context, recipient)


static func _emit_transaction(outcome: CombatOutcome) -> void:
	var target := CombatOutcomeContext.resolve_actor(outcome.target_id)
	var system := CombatOutcomeContext.resolve_system(target)
	if system == null:
		return
	var event := outcome.get_event().duplicate(true)
	var source := CombatOutcomeContext.resolve_actor(outcome.source_id)
	event["source_name"] = GameplayEffectContext.actor_name(source)
	event["target_name"] = GameplayEffectContext.actor_name(target)
	system.combat_event.emit(event)


static func _trace_suppressed(
		outcome: CombatOutcome, reaction: ReactionDefinition, origin: String, reason: StringName
) -> void:
	var system := CombatOutcomeContext.resolve_system(
			outcome.context.actor(CombatOutcomeContext.Role.CREDITED_OWNER))
	if system == null:
		system = CombatOutcomeContext.resolve_system(CombatOutcomeContext.resolve_actor(outcome.target_id))
	if system == null:
		return
	var event := outcome.get_event().duplicate(true)
	event["type"] = &"reaction_suppressed"
	event["event_id"] = CombatOutcomeContext.allocate_id()
	event["parent_event_id"] = outcome.id
	event["reason"] = reason
	event["reaction_trigger"] = reaction.trigger
	event["reaction_attachment"] = StringName(origin)
	system.combat_event.emit(event)


class Delivery extends RefCounted:
	var outcome: CombatOutcome
	var reactions: Array[ReactionDefinition] = []
	var attachment_id: int
	var scoped: bool = false
	var owner_active: Callable
	var attack_use: Callable


class Subscription extends RefCounted:
	var owner: WeakRef
	var callback: Callable
