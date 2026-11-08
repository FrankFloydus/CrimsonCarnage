extends SceneTree
## Verifies ownership, cleanup and ordering of per-activation tasks with test-owned timing.

class HeldExecution extends AbilityExecution:
	func begin(_cast: AbilityCast) -> void:
		pass


var _holder: Node
var _system: AbilitySystem
var _player: AnimationPlayer
var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_holder = Node.new()
	_holder.process_mode = Node.PROCESS_MODE_DISABLED
	var attributes := preload("res://tests/attribute_fixture.gd").new_attributes()
	_holder.add_child(attributes)
	_player = AnimationPlayer.new()
	var clip := Animation.new()
	clip.length = 1.0
	var animations := AnimationLibrary.new()
	animations.add_animation(&"test_clip", clip)
	_player.add_animation_library(&"", animations)
	_holder.add_child(_player)
	_system = AbilitySystem.new()
	_system.attributes = attributes
	_system.animation_player = _player
	_holder.add_child(_system)
	root.add_child(_holder)
	_test_timing_and_events()
	_test_input_release()
	_test_animation_lifetime()
	_holder.free()
	print("Ability task checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_timing_and_events() -> void:
	var cast := _activate(200)
	var events: Array[StringName] = []
	var wait := AbilityTaskWaitGameplayEvent.new(&"Event.Task", true, false)
	wait.event_received.connect(func(tag: StringName, payload: Dictionary) -> void:
		events.append(tag)
		_check(payload.get("value") == 7, "The matching event delivers its payload")
	)
	var delay := AbilityTaskWaitDelay.new(0.75)
	delay.finished.connect(func() -> void: events.append(&"delay"))
	_check(cast.start_task(wait) and cast.start_task(delay), "The cast starts distinct tasks")
	_check(not cast.start_task(wait), "A task instance cannot start twice")
	_system.advance(0.5)
	_system.send_gameplay_event(&"Event.Unrelated")
	_check(events.is_empty(), "Unrelated events and a partial interval do not fire tasks")
	_system.send_gameplay_event(&"Event.Task.Child", {"value": 7})
	_system.send_gameplay_event(&"Event.Task")
	_system.advance(0.25)
	_check(events == [&"Event.Task.Child", &"delay"], "Matching one-shot events and delay fire once")
	_check(not wait.is_active() and not delay.is_active(), "Finished tasks release their subscriptions")
	var pending := AbilityTaskWaitDelay.new(0.5)
	pending.finished.connect(func() -> void: events.append(&"late"))
	cast.start_task(pending)
	cast.cancel()
	_system.advance(1.0)
	_check(not pending.is_active() and not events.has(&"late"), "Cancellation drops pending delay callbacks")


func _test_input_release() -> void:
	var cast := _activate(201)
	var other := _activate(202)
	var releases: Array[StringName] = []
	var wait := AbilityTaskWaitInputRelease.new()
	wait.released.connect(func() -> void: releases.append(&"held"))
	cast.start_task(wait)
	var other_wait := AbilityTaskWaitInputRelease.new()
	other_wait.released.connect(func() -> void: releases.append(&"other"))
	other.start_task(other_wait)
	_system.release_ability_spec(cast.grant_spec.handle)
	_system.release_ability_spec(cast.grant_spec.handle)
	_check(releases == [&"held"], "Release reaches only the addressed grant and fires once")
	cast.finish()
	other.cancel()
	_system.release_ability_spec(other.grant_spec.handle)
	_check(not other_wait.is_active() and releases == [&"held"], "A cancelled grant cannot release later")


func _test_animation_lifetime() -> void:
	var cast := _activate(203)
	var results: Array[StringName] = []
	var animation := AbilityTaskPlayAnimationAndWait.new(&"test_clip")
	animation.completed.connect(func() -> void:
		results.append(&"completed")
		_check(_system.get_animation_cast() == null, "Completion releases playback before callbacks")
	)
	cast.start_task(animation)
	_system.advance_animation(1.01)
	_check(results == [&"completed"] and not cast.finished, "Playback completion can leave the ability active")
	var next := AbilityTaskPlayAnimationAndWait.new(&"test_clip")
	next.interrupted.connect(func() -> void: results.append(&"interrupted"))
	cast.start_task(next)
	_player.stop()
	_system.advance_animation(0.01)
	_check(results == [&"completed", &"interrupted"] and not next.is_active(),
			"Externally stopped playback reports interruption and clears its task")
	var last := AbilityTaskPlayAnimationAndWait.new(&"test_clip")
	last.cancelled.connect(func() -> void: results.append(&"cancelled"))
	cast.start_task(last)
	cast.cancel()
	_system.advance_animation(1.01)
	_check(results == [&"completed", &"interrupted", &"cancelled"] and not _player.is_playing(),
			"Cancelling the owning cast stops playback and emits cancellation only")


func _activate(ability_id: int) -> AbilityCast:
	var definition := AbilityDefinition.new()
	definition.ability_id = ability_id
	definition.execution = HeldExecution.new()
	_system.grant_ability(definition)
	_check(_system.try_activate(ability_id), "The fixture grant starts")
	return _system.get_active_cast(ability_id)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
