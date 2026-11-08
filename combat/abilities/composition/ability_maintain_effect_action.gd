class_name AbilityMaintainEffectAction
extends AbilityActionDefinition
## Maintains one independent effect on each selected actor until the activation ends.

## Infinite effect owned by this activation. Use independent stacking and disable transfer.
@export var effect: GameplayEffectDefinition


func get_validation_error() -> StringName:
	if effect == null:
		return &"missing_effect_payload"
	if effect.timing != GameplayEffectDefinition.Timing.INFINITE or effect.is_damage_effect() \
			or effect.stacking_type != GameplayEffectDefinition.StackingType.INDEPENDENT \
			or not effect.get_exclusive_owner_slot().is_empty() or effect.is_transferable():
		return &"maintained_effect_requires_independent_infinite_effect"
	return effect.get_validation_error()


func get_effect_payload() -> Array[GameplayEffectDefinition]:
	return [effect] if effect != null else []


func execute(context: AbilityPhaseContext, targets: AbilityTargetSet) -> int:
	var maintained := 0
	for contact: AbilityTargetContact in targets.contacts:
		if context.cast.finished:
			break
		var target := contact.get_target()
		if target == null or target.effects == null:
			continue
		if _find_handle(context, target) == null:
			var entry := MaintainedEffect.new(context.cast, target, effect, get_instance_id())
			context.own_handle(entry)
			entry.start()
		maintained += 1
	return maintained


func _find_handle(context: AbilityPhaseContext, target: AbilitySystem) -> MaintainedEffect:
	for handle: AbilityPhaseContext.OwnedHandle in context.owned_handles:
		var entry := handle as MaintainedEffect
		if entry != null and entry.action_id == get_instance_id() and entry.actor.get_ref() == target:
			return entry
	return null


class MaintainedEffect extends AbilityPhaseContext.OwnedHandle:
	var actor: WeakRef
	var action_id: int
	var _activation: WeakRef
	var _definition: GameplayEffectDefinition
	var _handle: int = 0
	var _applying: bool = false
	var _stopped: bool = false

	func _init(
			cast: AbilityCast, target: AbilitySystem, definition: GameplayEffectDefinition,
			owner_action_id: int
	) -> void:
		_activation = weakref(cast)
		actor = weakref(target)
		_definition = definition
		action_id = owner_action_id

	func start() -> void:
		var target := actor.get_ref() as AbilitySystem
		if not _stopped and is_instance_valid(target) and target.effects != null:
			target.effects.retained_effects_changed.connect(_refresh)
			_refresh()

	func advance(_cast: AbilityCast, _delta: float) -> void:
		_refresh()

	func remove() -> void:
		_stopped = true
		var target := actor.get_ref() as AbilitySystem
		if not is_instance_valid(target) or target.effects == null:
			return
		if target.effects.retained_effects_changed.is_connected(_refresh):
			target.effects.retained_effects_changed.disconnect(_refresh)
		if _handle > 0:
			target.remove_active_effect(_handle)
			_handle = 0

	func _refresh() -> void:
		if _stopped or _applying:
			return
		var cast := _activation.get_ref() as AbilityCast
		var target := actor.get_ref() as AbilitySystem
		if cast == null or cast.finished or not is_instance_valid(target) or target.effects == null:
			return
		var effects := target.effects
		if effects.is_clearing() or effects.has_retained_effect(_handle):
			return
		_handle = 0
		_applying = true
		var handle := effects.apply_effect_spec(cast.make_effect_spec(_definition))
		_applying = false
		if _stopped or cast.finished:
			if handle > 0:
				effects.remove_effect(handle)
		elif effects.has_retained_effect(handle):
			_handle = handle
