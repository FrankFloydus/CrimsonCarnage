extends SceneTree
## Exercises cue routing and presentation lifetimes without changing an actor's gameplay data.

class CueProbe extends Node:
	func handle_gameplay_cue(
			target: Node, tag: StringName, event: GameplayCueRouter.Event, parameters: Dictionary
	) -> void:
		var events: Array = target.get_meta(&"cue_events")
		events.append([get_instance_id(), tag, event, parameters["active_handle"]])
		if event == GameplayCueRouter.Event.EXECUTED and parameters["active_handle"] == 0:
			queue_free()


const SYSTEM = preload("res://combat/abilities/ability_system.gd")
const CUE_TAG: StringName = &"GameplayCue.Test.Impact"
const PARENT_TAG: StringName = &"GameplayCue.Test"
const CUE_EFFECT_ID := 266
const CUE_ABILITY_ID := 267

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var source := ActorAttributes.new()
	var target := Node.new()
	target.name = "CueTarget"
	var attributes := ActorAttributes.new()
	target.add_child(attributes)
	root.add_child(target)
	var spec := _make_spec(source)
	_test_handlers(spec, attributes)
	_test_effect_lifecycle(spec, attributes)
	await _test_scene_lifetimes(spec, attributes)
	await _test_startup_scene_cue()
	source.free()
	target.free()
	print("Gameplay Cue checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _make_spec(source: ActorAttributes) -> GameplayEffectSpec:
	var effect := GameplayEffectDefinition.new()
	effect.effect_id = CUE_EFFECT_ID
	effect.gameplay_cue_tags = PackedStringArray([String(CUE_TAG), String(CUE_TAG)])
	var context := GameplayEffectContext.capture(source, null)
	context.ability_id = CUE_ABILITY_ID
	var spec := GameplayEffectSpec.new(effect, context)
	spec.level = 3.0
	return spec


func _test_handlers(spec: GameplayEffectSpec, attributes: ActorAttributes) -> void:
	var cues := GameplayCueRouter.new()
	var parent_calls: Array[StringName] = []
	var seen_parameters: Array[Dictionary] = []
	var parent_handler := func(_target: Node, tag: StringName, _event: int, _data: Dictionary) -> void:
		parent_calls.append(tag)
	var mutating_handler := func(_target: Node, _tag: StringName, _event: int, data: Dictionary) -> void:
		data["effect_id"] = 268
	var exact_handler := func(target: Node, _tag: StringName, event: int, data: Dictionary) -> void:
		_check(target == attributes.get_parent() and event == GameplayCueRouter.Event.EXECUTED,
				"The callback receives the affected actor and event")
		seen_parameters.append(data)
	_check(not cues.register_handler(&"State.Test", parent_handler), "Cue handlers require GameplayCue tags")
	_check(cues.register_handler(PARENT_TAG, parent_handler), "A parent cue handler can be registered")
	cues.dispatch_effect(GameplayCueRouter.Event.EXECUTED, spec, attributes, 0)
	_check(parent_calls == [CUE_TAG], "A parent fallback receives the original tag once")
	_check(cues.register_handler(CUE_TAG, mutating_handler) and cues.register_handler(CUE_TAG, exact_handler),
			"Multiple distinct callbacks can subscribe to the same tag")
	_check(not cues.register_handler(CUE_TAG, exact_handler), "Duplicate callbacks are rejected")
	cues.dispatch_effect(GameplayCueRouter.Event.EXECUTED, spec, attributes, 0, {"health_damage": 15.0})
	_check(parent_calls.size() == 1, "Exact callbacks take precedence over a parent binding")
	_check(seen_parameters.size() == 1, "Each exact callback sees one dispatched event")
	if not seen_parameters.is_empty():
		var payload := seen_parameters[0]
		_check(payload["effect_id"] == CUE_EFFECT_ID and payload["ability_id"] == CUE_ABILITY_ID
				and payload["effect_level"] == 3.0 and payload["health_damage"] == 15.0,
				"Cue metadata comes from the spec and resolved details, isolated from other handlers")
	cues.unregister_handler(CUE_TAG, mutating_handler)
	cues.unregister_handler(CUE_TAG, exact_handler)
	cues.dispatch_effect(GameplayCueRouter.Event.EXECUTED, spec, attributes, 0)
	_check(parent_calls == [CUE_TAG, CUE_TAG], "Unregistering the last exact callback restores parent fallback")


func _test_effect_lifecycle(spec: GameplayEffectSpec, attributes: ActorAttributes) -> void:
	var tags := GameplayTagSet.new()
	var runtime := GameplayEffectRuntime.new(attributes, tags)
	var events: Array[int] = []
	var payloads: Array[Dictionary] = []
	var cancel_on_active := [false]
	var runtime_ref: WeakRef = weakref(runtime)
	runtime.cues.register_handler(CUE_TAG, func(_target: Node, _tag: StringName, event: int, data: Dictionary) -> void:
		events.append(event)
		payloads.append(data)
		if cancel_on_active[0] and event == GameplayCueRouter.Event.ACTIVE:
			(runtime_ref.get_ref() as GameplayEffectRuntime).remove_effect(data["active_handle"]))
	attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 100.0)
	attributes.set_base_value(CombatAttributes.Id.HEALTH, 100.0)
	var instant := spec.settings.duplicate() as GameplayEffectDefinition
	var execution := GameplayEffectDamageExecution.new()
	execution.amount = AmountDefinition.fixed(12.0)
	instant.executions = [execution]
	_check(runtime.apply_effect(instant, spec.context) > 0 and events == [GameplayCueRouter.Event.EXECUTED],
			"An instant effect dispatches only Executed")
	if not payloads.is_empty():
		_check(payloads[0]["active_handle"] == 0 and payloads[0]["health_damage"] == 12.0,
				"An instant damage cue receives the actual applied damage")
	events.clear()
	var period := GameplayEffectDefinition.new()
	period.timing = GameplayEffectDefinition.Timing.INFINITE
	period.period = 0.25
	period.gameplay_cue_tags = spec.settings.gameplay_cue_tags
	period.ongoing_required_target_tags = PackedStringArray(["State.Test.CueEnabled"])
	period.period_inhibition_policy = GameplayEffectDefinition.PeriodInhibitionPolicy.EXECUTE_AND_RESET_PERIOD
	var handle := runtime.apply_effect(period, spec.context)
	_check(handle > 0 and events.is_empty(), "An inhibited effect owns a handle before it begins presentation")
	tags.add_tag(&"State.Test.CueEnabled")
	_check(events == [GameplayCueRouter.Event.ACTIVE, GameplayCueRouter.Event.WHILE_ACTIVE,
			GameplayCueRouter.Event.EXECUTED], "Enabling starts presentation before the resumed execution")
	runtime.advance(0.25)
	_check(events.size() == 4 and events.back() == GameplayCueRouter.Event.EXECUTED,
			"A scheduled period dispatches Executed without repeating While Active")
	tags.remove_tag(&"State.Test.CueEnabled")
	_check(events.size() == 5 and events.back() == GameplayCueRouter.Event.REMOVED,
			"Inhibition ends presentation immediately")
	runtime.remove_effect(handle)
	_check(events.size() == 5, "Removing an already inhibited handle avoids a second Removed event")
	events.clear()
	cancel_on_active[0] = true
	period.period = 0.0
	period.ongoing_required_target_tags.clear()
	handle = runtime.apply_effect(period, spec.context)
	_check(not runtime.has_retained_effect(handle) and events == [GameplayCueRouter.Event.ACTIVE,
			GameplayCueRouter.Event.WHILE_ACTIVE, GameplayCueRouter.Event.REMOVED],
			"Reentrant removal publishes the committed start and cleans its presentation once")


func _test_scene_lifetimes(spec: GameplayEffectSpec, attributes: ActorAttributes) -> void:
	var target := attributes.get_parent()
	var scene_calls: Array = []
	target.set_meta(&"cue_events", scene_calls)
	var cues := GameplayCueRouter.new()
	cues.configure([_make_binding()])
	cues.dispatch_effect(GameplayCueRouter.Event.ACTIVE, spec, attributes, 1)
	cues.dispatch_effect(GameplayCueRouter.Event.WHILE_ACTIVE, spec, attributes, 1)
	cues.dispatch_effect(GameplayCueRouter.Event.EXECUTED, spec, attributes, 1)
	cues.dispatch_effect(GameplayCueRouter.Event.ACTIVE, spec, attributes, 2)
	await process_frame
	_check(scene_calls.size() == 4, "The authored scene receives all cue events")
	if scene_calls.size() == 4:
		_check(scene_calls[0][0] == scene_calls[1][0] and scene_calls[1][0] == scene_calls[2][0]
				and scene_calls[2][0] != scene_calls[3][0],
				"The scene instance is reused per active handle and independent across effects")
	cues.dispatch_effect(GameplayCueRouter.Event.REMOVED, spec, attributes, 1)
	cues.dispatch_effect(GameplayCueRouter.Event.REMOVED, spec, attributes, 1)
	await process_frame
	_check(target.get_child_count() == 2 and scene_calls.size() == 5,
			"Removing one handle cleans up its scene once and leaves the other cue")
	cues.dispatch_effect(GameplayCueRouter.Event.REMOVED, spec, attributes, 2)
	cues.dispatch_effect(GameplayCueRouter.Event.EXECUTED, spec, attributes, 0)
	await process_frame
	_check(target.get_child_count() == 1 and scene_calls.size() == 7,
			"Retained and one-shot scene lifetimes end independently")

	scene_calls.clear()
	cues.dispatch_effect(GameplayCueRouter.Event.ACTIVE, spec, attributes, 1)
	cues.dispatch_cast(true, attributes, spec.context, CUE_TAG, 1)
	await process_frame
	_check(scene_calls.size() == 3 and scene_calls[0][0] != scene_calls[1][0] \
			and scene_calls[1][0] == scene_calls[2][0],
			"Cast and effect cues have independent scenes even when their numeric handles match")
	cues.dispatch_cast(false, attributes, spec.context, CUE_TAG, 1)
	await process_frame
	_check(target.get_child_count() == 2 and scene_calls.size() == 4,
			"Releasing a cast leaves the matching retained effect cue intact")
	cues.dispatch_effect(GameplayCueRouter.Event.REMOVED, spec, attributes, 1)
	await process_frame
	_check(target.get_child_count() == 1 and scene_calls.size() == 5,
			"The remaining effect cue ends with its own lifetime")


func _test_startup_scene_cue() -> void:
	var actor := Node.new()
	var scene_calls: Array = []
	actor.set_meta(&"cue_events", scene_calls)
	var attributes := ActorAttributes.new()
	attributes.name = &"Attributes"
	actor.add_child(attributes)
	var effect := GameplayEffectDefinition.new()
	effect.timing = GameplayEffectDefinition.Timing.INFINITE
	effect.gameplay_cue_tags = PackedStringArray([String(CUE_TAG)])
	var system := SYSTEM.new()
	system.startup_effects = [effect]
	system.gameplay_cue_bindings = [_make_binding()]
	actor.add_child(system)
	root.add_child(actor)
	await process_frame
	_check(actor.get_child_count() == 3 and scene_calls.size() == 2,
			"A startup effect's binding spawns its scene after the actor enters the tree")
	actor.remove_child(system)
	system.free()
	await process_frame
	_check(actor.get_child_count() == 1 and scene_calls.size() == 3,
			"A standalone ASC teardown cleans the retained cue scene from its actor")
	actor.free()


func _make_binding() -> GameplayCueBinding:
	var scene := PackedScene.new()
	var probe := CueProbe.new()
	_check(scene.pack(probe) == OK, "The test cue scene packs successfully")
	probe.free()
	var binding := GameplayCueBinding.new()
	binding.cue_tag = PARENT_TAG
	binding.cue_scene = scene
	return binding


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
