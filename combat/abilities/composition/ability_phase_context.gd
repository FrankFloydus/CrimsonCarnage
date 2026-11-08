class_name AbilityPhaseContext
extends RefCounted
## Invocation data for one ability phase; never stored on an authored Resource.

var cast: AbilityCast
var effect_context: GameplayEffectContext
var event_key: StringName
var event_payload: Dictionary = {}
## Detached outgoing specs prepared from the caster at release, keyed by authored action.
var prepared_payloads: Dictionary = {}
## Actor IDs with a confirmed hit from this invocation.
var confirmed_targets: Dictionary[int, bool] = {}
var owned_handles: Array[OwnedHandle] = []


func _init(
		activation: AbilityCast, event: StringName, payloads: Dictionary,
		provenance: GameplayEffectContext
) -> void:
	cast = activation
	event_key = event
	prepared_payloads = payloads
	effect_context = provenance


## Registers a retained effect for cast cleanup, including synchronous interruption during setup.
func own_effect(target: AbilitySystem, handle: int) -> void:
	if not is_instance_valid(target) or handle == 0 or not target.effects.has_retained_effect(handle):
		return
	var entry := OwnedEffect.new()
	entry.actor = weakref(target)
	entry.handle = handle
	own_handle(entry)


## Attaches runtime work to the activation and cleans up even if setup interrupted it.
func own_handle(handle: OwnedHandle) -> void:
	if cast.finished:
		handle.remove()
	else:
		owned_handles.append(handle)


class OwnedHandle extends RefCounted:
	func advance(_cast: AbilityCast, _delta: float) -> void:
		pass

	func physics_advance(_cast: AbilityCast, _delta: float) -> void:
		pass

	func remove() -> void:
		pass


class OwnedEffect extends OwnedHandle:
	var actor: WeakRef
	var handle: int

	func remove() -> void:
		var target := actor.get_ref() as AbilitySystem
		if is_instance_valid(target):
			target.remove_active_effect(handle)
