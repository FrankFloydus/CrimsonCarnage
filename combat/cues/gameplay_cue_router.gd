class_name GameplayCueRouter
extends RefCounted
## Routes presentation-only cue events to actor-scoped callbacks and saved scenes.

## Presentation notification sent for a committed effect lifetime or execution.
enum Event {
	## A retained cue became active.
	ACTIVE,
	## Start or restore the retained presentation once. This event is not a tick.
	WHILE_ACTIVE,
	## An instant effect or periodic execution took place.
	EXECUTED,
	## The retained cue was removed or inhibited.
	REMOVED,
}

var _handlers: Dictionary[StringName, Array] = {}
var _scenes: Dictionary[StringName, PackedScene] = {}
var _active_scenes: Dictionary[int, Dictionary] = {}
var _pending: Array[Dictionary] = []
var _dispatching: bool = false


func configure(bindings: Array[GameplayCueBinding]) -> void:
	for binding in bindings:
		if binding != null and not register_scene(binding.cue_tag, binding.cue_scene):
			push_warning("Invalid or duplicate Gameplay Cue binding: %s" % binding.cue_tag)


## Registers a callback taking (target, cue_tag, event, parameters).
func register_handler(cue_tag: StringName, handler: Callable) -> bool:
	if not is_cue_tag(cue_tag) or not handler.is_valid():
		return false
	var handlers: Array = _handlers.get_or_add(cue_tag, [])
	if handlers.has(handler):
		return false
	handlers.append(handler)
	return true


func unregister_handler(cue_tag: StringName, handler: Callable) -> void:
	if not _handlers.has(cue_tag):
		return
	var handlers := _handlers[cue_tag]
	handlers.erase(handler)
	if handlers.is_empty():
		_handlers.erase(cue_tag)


func register_scene(cue_tag: StringName, scene: PackedScene) -> bool:
	if not is_cue_tag(cue_tag) or scene == null or not scene.can_instantiate() or _scenes.has(cue_tag):
		return false
	_scenes[cue_tag] = scene
	return true


## Sends effect cues with detached parameters so presentation cannot mutate the effect spec.
## Instant executions use handle zero. Retained cue lifecycles use the owning effect handle.
func dispatch_effect(
		event: Event, spec: GameplayEffectSpec, attributes: ActorAttributes, handle: int,
		details: Dictionary = {}
) -> void:
	if spec == null or spec.settings == null or spec.context == null \
			or spec.settings.gameplay_cue_tags.is_empty() or not is_instance_valid(attributes):
		return
	var target := attributes.get_parent()
	if target == null:
		target = attributes
	var parameters := spec.context.create_combat_event(&"gameplay_cue", attributes, spec.settings)
	parameters.merge(details, true)
	parameters["effect_level"] = spec.level
	parameters["duration"] = spec.duration
	parameters["period"] = spec.period
	parameters["active_handle"] = handle
	var queued_tags: Dictionary[StringName, bool] = {}
	for cue_tag in spec.settings.gameplay_cue_tags:
		var tag := StringName(cue_tag)
		if not is_cue_tag(tag) or queued_tags.has(tag):
			continue
		queued_tags[tag] = true
		_pending.append({"target": weakref(target), "tag": tag,
				"event": event, "parameters": parameters})
	_flush()


static func is_cue_tag(tag: StringName) -> bool:
	var value := String(tag)
	return value.begins_with("GameplayCue.") and not value.ends_with(".") and not value.contains("..")


func _flush() -> void:
	if _dispatching:
		return
	_dispatching = true
	while not _pending.is_empty():
		var item: Dictionary = _pending.pop_front()
		var target: Node = item["target"].get_ref()
		if not is_instance_valid(target):
			continue
		var cue_tag: StringName = item["tag"]
		var event: Event = item["event"]
		var parameters: Dictionary = item["parameters"]
		var match_tag := _closest_match(cue_tag, _handlers)
		var handlers: Array = _handlers.get(match_tag, []).duplicate()
		for handler: Callable in handlers:
			if handler.is_valid() and is_instance_valid(target):
				handler.call(target, cue_tag, event, parameters.duplicate(true))
		if not _scenes.is_empty():
			_defer_scene(item["target"], cue_tag, event, parameters)
	_dispatching = false


func _defer_scene(target_ref: WeakRef, cue_tag: StringName, event: Event, parameters: Dictionary) -> void:
	# Startup effects can fire while the actor is still entering the tree. Retain the router until
	# delivery so a removal queued by an exiting AbilitySystem can also finish after the node is freed.
	var deliver := func(router: GameplayCueRouter) -> void:
		router._dispatch_scene(target_ref.get_ref() as Node, cue_tag, event, parameters)
	deliver.call_deferred(self)


func _dispatch_scene(target: Node, cue_tag: StringName, event: Event, parameters: Dictionary) -> void:
	var handle: int = parameters["active_handle"]
	var active: Dictionary = _active_scenes.get(handle, {})
	var instance: Node = active.get(cue_tag)
	if event == Event.REMOVED:
		active.erase(cue_tag)
		if active.is_empty():
			_active_scenes.erase(handle)
		if is_instance_valid(instance) and not instance.is_queued_for_deletion():
			if is_instance_valid(target):
				instance.call(&"handle_gameplay_cue", target, cue_tag, event, parameters.duplicate(true))
			if is_instance_valid(instance):
				instance.queue_free()
		return
	if not is_instance_valid(target):
		return
	if not is_instance_valid(instance) or instance.is_queued_for_deletion():
		var scene: PackedScene = _scenes.get(_closest_match(cue_tag, _scenes))
		if scene == null or not target.is_inside_tree() or target.is_queued_for_deletion():
			return
		instance = scene.instantiate()
		if not instance.has_method(&"handle_gameplay_cue"):
			push_warning("Gameplay Cue scene root must implement handle_gameplay_cue: %s" % cue_tag)
			instance.free()
			return
		if handle > 0:
			active[cue_tag] = instance
			_active_scenes[handle] = active
		target.add_child(instance)
	if is_instance_valid(instance) and is_instance_valid(target) and not instance.is_queued_for_deletion():
		instance.call(&"handle_gameplay_cue", target, cue_tag, event, parameters.duplicate(true))


static func _closest_match(cue_tag: StringName, routes: Dictionary) -> StringName:
	var candidate := String(cue_tag)
	while candidate.begins_with("GameplayCue."):
		var key := StringName(candidate)
		if routes.has(key):
			return key
		candidate = candidate.left(candidate.rfind("."))
	return &""
