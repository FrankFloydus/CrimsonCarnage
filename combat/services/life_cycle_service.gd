class_name LifeCycleService
extends RefCounted
## Holds stable actor identity and resurrection entitlements independently of disposable bodies.

signal died(actor_id: StringName)
signal resurrection_offered(actor_id: StringName, entitlement_handle: int)
signal resurrected(actor_id: StringName, source_id: StringName, body: Node3D)

## Lifecycle stage associated with a stable actor ID.
enum State {
	## No actor has registered this ID.
	UNKNOWN,
	## The actor is alive and can begin a death transition.
	ALIVE,
	## Death was requested and can still be canceled before commitment.
	PENDING_DEATH,
	## Death was committed and the service emitted its death signal.
	DEAD,
	## The world has marked the dead actor's representation as a corpse.
	CORPSE,
	## The body was released while the actor ID and its entitlements remain registered.
	RELEASED,
	## A resurrection offer is active and can proceed to restoration under its policy.
	RESURRECTION_PENDING,
}


class ActorRecord extends RefCounted:
	var state: State = State.ALIVE
	var body: WeakRef
	var pending_handle: int
	var state_before_offer: State


class Entitlement extends RefCounted:
	var target_id: StringName
	var source_id: StringName
	var profile: ResurrectionProfile
	var expires_at: float
	var restoring: bool = false


var _actors: Dictionary[StringName, ActorRecord] = {}
var _entitlements: Dictionary[int, Entitlement] = {}
var _available_budgets: Dictionary[StringName, int] = {}
var _reserved_budgets: Dictionary[StringName, int] = {}
var _clock: float = 0.0
var _next_handle: int = 1


func register_actor(actor_id: StringName, body: Node3D) -> bool:
	if actor_id.is_empty() or _actors.has(actor_id) or not _valid_body(body):
		return false
	var actor := ActorRecord.new()
	actor.body = weakref(body)
	_actors[actor_id] = actor
	return true


func get_state(actor_id: StringName) -> State:
	var actor := _actors.get(actor_id) as ActorRecord
	return actor.state if actor != null else State.UNKNOWN


func get_body(actor_id: StringName) -> Node3D:
	var actor := _actors.get(actor_id) as ActorRecord
	var body: Node3D = actor.body.get_ref() as Node3D if actor != null and actor.body != null else null
	return body if _valid_body(body) else null


func begin_death(actor_id: StringName) -> bool:
	if get_state(actor_id) != State.ALIVE:
		return false
	_actors[actor_id].state = State.PENDING_DEATH
	return true


func cancel_death(actor_id: StringName) -> bool:
	if get_state(actor_id) != State.PENDING_DEATH or get_body(actor_id) == null:
		return false
	_actors[actor_id].state = State.ALIVE
	return true


func commit_death(actor_id: StringName) -> bool:
	if get_state(actor_id) != State.PENDING_DEATH:
		return false
	_actors[actor_id].state = State.DEAD
	for handle: int in _entitlements.keys():
		var entitlement := _entitlements[handle]
		if entitlement.source_id == actor_id and entitlement.profile.cancel_on_source_death:
			remove_entitlement(handle)
	died.emit(actor_id)
	return true


func mark_corpse(actor_id: StringName) -> bool:
	if get_state(actor_id) != State.DEAD or get_body(actor_id) == null:
		return false
	_actors[actor_id].state = State.CORPSE
	return true


## Drops the body reference while preserving stable identity and pending entitlements.
func release_body(actor_id: StringName) -> bool:
	var actor := _actors.get(actor_id) as ActorRecord
	if actor == null or (not _is_dead(actor.state) and actor.state != State.RESURRECTION_PENDING):
		return false
	actor.body = null
	if actor.state == State.RESURRECTION_PENDING:
		actor.state_before_offer = State.RELEASED
	else:
		actor.state = State.RELEASED
	return true


func set_encounter_budget(budget_id: StringName, uses: int) -> bool:
	if budget_id.is_empty() or uses < 0 or _reserved_budgets.has(budget_id):
		return false
	_available_budgets[budget_id] = uses
	return true


func get_encounter_budget(budget_id: StringName) -> int:
	return _available_budgets.get(budget_id, 0)


func grant_entitlement(target_id: StringName, source_id: StringName, profile: ResurrectionProfile) -> int:
	var state := get_state(target_id)
	if not _valid_profile(profile) or source_id.is_empty() \
			or (state != State.ALIVE and not (_is_dead(state) and profile.allow_grant_to_dead)) \
			or (profile.cancel_on_source_death and get_state(source_id) != State.ALIVE):
		return 0
	var entitlement := Entitlement.new()
	entitlement.target_id = target_id
	entitlement.source_id = source_id
	entitlement.profile = profile.duplicate() as ResurrectionProfile
	if profile.duration > 0.0:
		entitlement.expires_at = _clock + profile.duration
	var handle := _next_handle
	_next_handle += 1
	_entitlements[handle] = entitlement
	return handle


func remove_entitlement(handle: int) -> bool:
	var entitlement := _entitlements.get(handle) as Entitlement
	if entitlement == null or entitlement.restoring:
		return false
	_entitlements.erase(handle)
	var actor := _actors[entitlement.target_id]
	if actor.pending_handle == handle:
		_reset_offer(actor)
	return true


func offer(handle: int) -> bool:
	var entitlement := _entitlements.get(handle) as Entitlement
	if entitlement == null:
		return false
	var actor := _actors[entitlement.target_id]
	if not _is_dead(actor.state) or not _can_reserve(entitlement.profile.budget_id):
		return false
	actor.state_before_offer = actor.state
	actor.state = State.RESURRECTION_PENDING
	actor.pending_handle = handle
	resurrection_offered.emit(entitlement.target_id, handle)
	return true


func decline(handle: int) -> bool:
	var entitlement := _entitlements.get(handle) as Entitlement
	if entitlement == null or entitlement.restoring:
		return false
	var actor := _actors[entitlement.target_id]
	if actor.pending_handle != handle:
		return false
	_reset_offer(actor)
	if entitlement.profile.consume_on_decline:
		_entitlements.erase(handle)
	return true


## The synchronous world adapter validates a safe destination, restores representation and resources,
## and returns the live body. Null means no changes were applied. The profile passed is a copy.
func restore(handle: int, accepted_by_target: bool, restore_actor: Callable) -> bool:
	var entitlement := _entitlements.get(handle) as Entitlement
	if entitlement == null or entitlement.restoring or not restore_actor.is_valid() \
			or (entitlement.profile.requires_acceptance and not accepted_by_target):
		return false
	var actor := _actors[entitlement.target_id]
	var budget_id := entitlement.profile.budget_id
	if actor.pending_handle != handle or not _can_reserve(budget_id):
		return false
	entitlement.restoring = true
	if not budget_id.is_empty():
		_available_budgets[budget_id] -= 1
		_reserved_budgets[budget_id] = _reserved_budgets.get(budget_id, 0) + 1
	var body := restore_actor.call(entitlement.target_id, get_body(entitlement.target_id),
		entitlement.profile.duplicate()) as Node3D
	var restored := _valid_body(body)
	if not budget_id.is_empty():
		_reserved_budgets[budget_id] -= 1
		if _reserved_budgets[budget_id] == 0:
			_reserved_budgets.erase(budget_id)
		if not restored:
			_available_budgets[budget_id] += 1
	entitlement.restoring = false
	if not restored:
		_reset_offer(actor)
		return false
	_entitlements.erase(handle)
	actor.body = weakref(body)
	actor.state = State.ALIVE
	actor.pending_handle = 0
	resurrected.emit(entitlement.target_id, entitlement.source_id, body)
	return true


func advance(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	_clock += delta
	for handle: int in _entitlements.keys():
		var entitlement := _entitlements[handle]
		if entitlement.expires_at > 0.0 and entitlement.expires_at <= _clock:
			remove_entitlement(handle)
	for actor_id: StringName in _actors:
		if get_body(actor_id) == null:
			release_body(actor_id)


func _can_reserve(budget_id: StringName) -> bool:
	return budget_id.is_empty() or get_encounter_budget(budget_id) > 0


static func _reset_offer(actor: ActorRecord) -> void:
	actor.pending_handle = 0
	actor.state = actor.state_before_offer


static func _is_dead(state: State) -> bool:
	return state == State.DEAD or state == State.CORPSE or state == State.RELEASED


static func _valid_body(body: Node3D) -> bool:
	return is_instance_valid(body) and body.is_inside_tree() and not body.is_queued_for_deletion()


static func _valid_profile(profile: ResurrectionProfile) -> bool:
	return profile != null and profile.version > 0 and is_finite(profile.duration) \
		and profile.duration >= 0.0 and profile.health_fraction > 0.0 \
		and profile.health_fraction <= 1.0 and profile.stamina_fraction >= 0.0 \
		and profile.stamina_fraction <= 1.0 and profile.mana_fraction >= 0.0 \
		and profile.mana_fraction <= 1.0
