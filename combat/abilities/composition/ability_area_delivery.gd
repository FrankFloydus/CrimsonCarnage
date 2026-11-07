class_name AbilityAreaDelivery
extends Node3D
## Owns one placed or attached spatial delivery and its independent tick clock.

signal phase_reached(event: StringName, targets: AbilityTargetSet)

var _definition: AbilityDeliveryDefinition
var _cast: AbilityCast
var _anchor: AbilityTargetSet
var _elapsed: float = 0.0
var _tick_index: int = 1
var _occupants: Dictionary[int, AbilityTargetContact] = {}
var _active: bool = false


func start(
		definition: AbilityDeliveryDefinition, cast: AbilityCast, placement: AbilityTargetSet
) -> void:
	_definition = definition
	_cast = cast
	_anchor = AbilityTargetSet.new()
	_anchor.copy_origin(placement)
	_anchor.query_space = weakref(self)
	if not placement.contacts.is_empty():
		_anchor.transform.origin = placement.contacts[0].position
	global_transform = _anchor.transform
	_active = true


func _physics_process(delta: float) -> void:
	if not _active:
		return
	var caster := _cast.get_system()
	if _definition.kind == AbilityDeliveryDefinition.Kind.AURA:
		var actor := AbilityTargetingDefinition.actor_spatial(caster)
		if not is_instance_valid(actor) or not actor.is_inside_tree():
			_expire()
			return
		_anchor.transform = actor.global_transform.orthonormalized()
		global_transform = _anchor.transform
	_elapsed = minf(_elapsed + delta, _definition.lifetime)
	if _definition.kind == AbilityDeliveryDefinition.Kind.TRAP and _elapsed < _definition.arm_delay:
		return
	var targets := _definition.area_targeting.select(_cast, _anchor)
	if not targets.failure.is_empty():
		_expire()
		return
	if _definition.kind == AbilityDeliveryDefinition.Kind.TRAP:
		if not targets.contacts.is_empty():
			phase_reached.emit(&"delivery.impact", targets)
			_expire()
		elif _elapsed >= _definition.lifetime:
			_expire()
		return
	_update_occupants(targets)
	if _definition.period > 0.0:
		var deadline := _tick_index * _definition.period
		while _active and (deadline < _elapsed or is_equal_approx(deadline, _elapsed)) \
				and deadline < _definition.lifetime and not is_equal_approx(deadline, _definition.lifetime):
			phase_reached.emit(&"area.tick", targets)
			_tick_index += 1
			deadline = _tick_index * _definition.period
	if _elapsed >= _definition.lifetime:
		_expire()


func stop() -> void:
	_end(&"delivery.cancelled")


func _update_occupants(targets: AbilityTargetSet) -> void:
	var present: Dictionary[int, AbilityTargetContact] = {}
	for contact: AbilityTargetContact in targets.contacts:
		present[contact.actor_id] = contact
		if not _occupants.has(contact.actor_id):
			phase_reached.emit(&"target.entered", targets.with_contact(contact))
			if not _active:
				return
	for id: int in _occupants:
		if not present.has(id):
			phase_reached.emit(&"target.exited", targets.with_contact(_occupants[id]))
			if not _active:
				return
	_occupants = present


func _expire() -> void:
	_end(&"delivery.expired")


func _end(event: StringName) -> void:
	if not _active:
		return
	_active = false
	for id: int in _occupants:
		phase_reached.emit(&"target.exited", _anchor.with_contact(_occupants[id]))
	_occupants.clear()
	phase_reached.emit(event, _anchor)
	queue_free()
