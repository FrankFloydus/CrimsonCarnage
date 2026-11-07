extends SceneTree
## Exercises saved locomotion abilities, Fireball and the load status on one player.
## Run headless with --fixed-fps 60 --script res://tests/player_ability_integration_test.gd.

class EventProbeExecution extends MaintainEffectExecution:
	func handle_gameplay_event(cast: AbilityCast, event_tag: StringName, payload: Dictionary) -> void:
		super.handle_gameplay_event(cast, event_tag, payload)
		match event_tag:
			&"Event.TestAction.Queue":
				cast.data["event_order"] = []
				var system := cast.get_system()
				system.send_gameplay_event(&"Event.TestAction.Message", {"value": 42})
				system.send_gameplay_event(&"Event.TestAction.Message", {"value": 43})
				cast.data["event_order"].append(0)
			&"Event.TestAction.Message":
				cast.data["event_order"].append(payload.get("value"))


const PLAYGROUND = preload("res://levels/playground/playground.tscn")
const ENCUMBERED = preload("res://player/encumbered_effect.tres")
const SPRINT_FIXTURE = preload("res://tests/sprint_fixture.gd")
const FIREBALL_FIXTURE = preload("res://tests/fireball_fixture.gd")
const ENCUMBERED_TAG: StringName = &"State.Encumbered"
const ENCUMBERED_ACTION: StringName = &"encumbered"
const FIREBALL: StringName = &"fireball"
const SPRINT: StringName = &"sprint"
const CROUCH: StringName = &"crouch"
const JUMP: StringName = &"jump"
const FORWARD := Vector2(0.0, -1.0)
const STEP: float = 1.0 / 60.0

var _arena: Node3D
var _player: FirstPersonController
var _system: AbilitySystem
var _movement: FirstPersonMovement
var _crouch: FirstPersonCrouch
var _dummy: DamageDummy
var _animation: AnimationPlayer
var _fireball_hits: int = 0
var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	await _start_fixture()
	await _test_saved_caster_stamina_regeneration()
	await _end_fixture()
	await _start_fixture()
	await _test_sprint_through_fireball()
	await _end_fixture()
	await _start_fixture()
	await _test_crouch_and_jump_during_fireball()
	await _end_fixture()
	await _start_fixture()
	await _test_encumbrance_interrupts_sprint()
	await _end_fixture()
	await _start_fixture(100.0001)
	_test_startup_and_revive_encumbrance()
	_test_revoke_encumbered_grant()
	await _end_fixture()
	await _start_fixture()
	await _test_interrupt_encumbrance_application()
	_test_reusable_gameplay_events()
	await _end_fixture()
	print("Player ability integration checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _start_fixture(starting_weight: float = 0.0) -> void:
	_arena = PLAYGROUND.instantiate() as Node3D
	_player = _arena.get_node("Player") as FirstPersonController
	_dummy = _arena.get_node("Dummy") as DamageDummy
	_player.position = Vector3(0.0, 0.05, 6.0)
	_player.rotation = Vector3.ZERO
	_dummy.position = Vector3(0.0, 0.0, -2.0)
	for course_name in ["Parkour", "LowStairs", "HighStairs", "CrouchTunnels"]:
		_arena.get_node(course_name).free()
	for path in ["Player/Attributes", "Dummy/Attributes"]:
		var attributes := _arena.get_node(path) as ActorAttributes
		attributes.initial_modifiers = []
		attributes.level = 1
	var player_attributes := _player.get_node("Attributes") as ActorAttributes
	player_attributes.set_base_value(CombatAttributes.Id.CARRY_CAPACITY, 100.0)
	player_attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, starting_weight)
	(_player.get_node("Movement") as FirstPersonMovement).settings = FirstPersonMovementSettings.new()
	SPRINT_FIXTURE.configure(_player.get_node("AbilitySystem") as AbilitySystem)
	root.add_child(_arena)
	current_scene = _arena
	_player.set_physics_process(false)
	_player.get_node("AbilityInput").set_process(false)
	_system = _player.get_node("AbilitySystem") as AbilitySystem
	_check(FIREBALL_FIXTURE.install(_system), "The saved Fireball grant has valid authoring")
	_system.set_process(false)
	_system.set_physics_process(false)
	_system.attributes.set_physics_process(false)
	_system.attributes.set_base_value(CombatAttributes.Id.ACCURACY_RATING, 30.0)
	_movement = _player.get_node("Movement") as FirstPersonMovement
	_crouch = _player.get_node("Crouch") as FirstPersonCrouch
	_dummy.ability_system.set_process(false)
	_dummy.attributes.set_physics_process(false)
	_dummy.attributes.set_base_value(CombatAttributes.Id.MAX_HEALTH, 1000.0)
	_dummy.attributes.restore_resources()
	_fireball_hits = 0
	_dummy.ability_system.combat_event.connect(_on_dummy_combat_event)
	_animation = _player.get_node("CastingAnimation") as AnimationPlayer
	for interval in 20:
		await _step()
		if _movement.is_grounded():
			break
	_check(_movement.is_grounded(), "The saved caster settles on the arena floor")


func _end_fixture() -> void:
	_arena.queue_free()
	await process_frame


func _test_saved_caster_stamina_regeneration() -> void:
	var attributes := _system.attributes
	attributes.set_base_value(CombatAttributes.Id.STAMINA, 50.0)
	attributes.set_base_value(CombatAttributes.Id.STAMINA_REGEN, 30.0)
	await _step(Vector2.ZERO, true)
	attributes.set_physics_process(true)
	for interval in 6:
		await _step(Vector2.ZERO, true)
	_check(_system.get_active_cast(SPRINT) != null
			and is_equal_approx(attributes.get_value(CombatAttributes.Id.STAMINA), 50.0),
			"Idle Sprint suppresses positive Stamina recovery on the saved Playground player")
	for interval in 6:
		await _step(FORWARD, true)
	_check(_system.get_active_cast(SPRINT) != null
			and is_equal_approx(attributes.get_value(CombatAttributes.Id.STAMINA), 48.0),
			"Moving Sprint on the saved Playground player applies upkeep without recovery")
	attributes.set_base_value(CombatAttributes.Id.STAMINA, 3.0)
	for interval in 12:
		await _step(FORWARD, true)
	_check(_system.get_active_cast(SPRINT) == null
			and _system.tags.has_tag(&"State.Stamina.Exhausted")
			and is_zero_approx(attributes.get_value(CombatAttributes.Id.STAMINA)),
			"After Sprint empties Stamina, the saved Playground player waits out exhaustion")
	var duration := SPRINT_FIXTURE.EXHAUSTION_DURATION
	_system.advance(duration * 0.9)
	await _step()
	_check(is_zero_approx(attributes.get_value(CombatAttributes.Id.STAMINA)),
			"The saved Playground player stays exhausted until the authored duration elapses")
	_system.advance(duration * 0.11)
	await _step()
	await _step()
	_check(attributes.get_value(CombatAttributes.Id.STAMINA) > 0.0,
			"Stamina recovery resumes on the saved Playground player after exhaustion")


func _test_sprint_through_fireball() -> void:
	var stamina := _system.attributes.get_value(CombatAttributes.Id.STAMINA)
	for interval in 6:
		await _step(FORWARD, true)
	var sprint := _system.get_active_cast(SPRINT)
	_check(sprint != null and _system.get_animation_cast() == null,
			"Holding Sprint starts its cast and leaves the animation player available")
	_check(_system.attributes.get_value(CombatAttributes.Id.STAMINA) < stamina,
			"Moving in Sprint drains the shared Stamina pool")
	_check(_system.try_activate(FIREBALL), "The saved Fireball begins during Sprint")
	var cast := _system.get_active_cast(FIREBALL)
	if cast == null:
		return
	_check(cast == _system.get_animation_cast() and sprint == _system.get_active_cast(SPRINT),
			"Fireball owns the animation player while Sprint keeps its separate cast")
	var execution := cast.definition.execution as ProjectileCastExecution
	var clip := _animation.get_animation(execution.animation_name)
	_check(clip != null, "The saved caster has the animation configured by Fireball")
	if clip == null:
		return
	var release_at := _event_position(clip, execution.release_event)
	_check(release_at > 0.001, "Fireball has an authored release event after the cast begins")
	if release_at <= 0.001:
		return
	_system.advance_animation(release_at - 0.001)
	_check(not cast.released and _projectile_count() == 0,
			"Sprint does not release Fireball before the animation reaches its method key")
	stamina = _system.attributes.get_value(CombatAttributes.Id.STAMINA)
	for interval in 6:
		await _step(FORWARD, true)
	_check(_system.attributes.get_value(CombatAttributes.Id.STAMINA) < stamina,
			"Sprint still drains Stamina while Fireball winds up")
	_system.advance_animation(0.002)
	_check(cast.released and _projectile_count() == 1,
			"The animation method key releases one real Fireball projectile during Sprint")
	for interval in 50:
		await _step(FORWARD, true)
		if _fireball_hits > 0:
			break
	_check(_fireball_hits == 1 and _dummy.attributes.get_value(CombatAttributes.Id.HEALTH) < 1000.0,
			"The projectile lands one Fireball hit and damages the saved dummy")
	_system.advance_animation(clip.length - release_at + 0.002)
	_check(cast.finished and _system.get_animation_cast() == null and _system.get_active_cast(SPRINT) == sprint,
			"Finishing the combat animation preserves the same Sprint activation")
	await _step(Vector2.ZERO, true, true)
	_check(_movement.is_grounded() and _player.velocity.y <= 0.0, "Active Sprint prevents takeoff, including while idle")
	await _step(FORWARD, false, true)
	_check(_system.get_active_cast(SPRINT) == null and _player.velocity.y > 0.0,
			"Releasing Sprint before processing Jump permits takeoff in the same tick")


func _test_crouch_and_jump_during_fireball() -> void:
	_check(_system.try_activate(FIREBALL), "Fireball can start while grounded")
	var cast := _system.get_active_cast(FIREBALL)
	await _step(Vector2.ZERO, false, false, true, true)
	var crouch := _system.get_active_cast(CROUCH)
	_check(crouch != null and _crouch.is_crouching and cast != null and _system.get_animation_cast() == cast,
			"The saved Crouch ability enters its stance without replacing Fireball")
	await _step(Vector2.ZERO, false, true, false, true)
	_check(_player.velocity.y > 0.0 and cast != null and _system.get_animation_cast() == cast,
			"The saved Jump ability physically launches without replacing Fireball")
	_check(_system.get_active_cast(JUMP) == null, "Jump completes after the physical takeoff")
	_system.cancel_ability(FIREBALL)
	_check(_system.get_animation_cast() == null and _system.get_active_cast(CROUCH) == crouch
			and _crouch.is_crouching,
			"Canceling Fireball by ID preserves the independent Crouch stance")
	_system.release_ability(CROUCH)
	_check(_system.get_active_cast(CROUCH) == null and not _crouch.is_crouching,
			"Releasing the Crouch cast leaves its stance with clear overhead space")


func _test_encumbrance_interrupts_sprint() -> void:
	await _step(FORWARD, true)
	var sprint := _system.get_active_cast(SPRINT)
	_check(sprint != null and _system.try_activate(FIREBALL), "Sprint and Fireball can start before overloading")
	var cast := _system.get_active_cast(FIREBALL)
	var attributes := _system.attributes
	var capacity := attributes.get_value(CombatAttributes.Id.CARRY_CAPACITY)
	var stamina := attributes.get_value(CombatAttributes.Id.STAMINA)
	attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, capacity)
	_check(_system.get_active_cast(SPRINT) == sprint and _system.get_active_cast(ENCUMBERED_ACTION) == null
			and _system.tags.get_count(ENCUMBERED_TAG) == 0,
			"Exactly reaching capacity leaves Sprint running and Encumbered inactive")
	attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, capacity + 0.0001)
	var encumbered := _system.get_active_cast(ENCUMBERED_ACTION)
	var effects := _system.effects.get_retained_effects()
	_check(encumbered != null and effects.size() == 1 and effects.values()[0] == ENCUMBERED
			and _system.tags.get_count(ENCUMBERED_TAG) == 1,
			"A fractional overload activates the granted action and applies one authored effect")
	_check(_system.get_active_cast(SPRINT) == null and sprint != null and sprint.finished
			and cast != null and _system.get_animation_cast() == cast,
			"The encumbrance tag interrupts Sprint while the combat cast remains active")
	_check(_system.get_activation_failure(SPRINT) == &"blocked_by_tags" and not _system.try_activate(SPRINT),
			"The same tag prevents a new Sprint activation")
	_check(attributes.get_value(CombatAttributes.Id.STAMINA) == stamina,
			"Encumbered activation and blocked Sprint requests leave Stamina unchanged")
	var load := capacity + 50.0
	attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, load)
	_check(_system.get_active_cast(ENCUMBERED_ACTION) == encumbered
			and _system.effects.get_retained_effects() == effects,
			"Further weight changes above capacity keep the same cast and effect handle")
	attributes.set_base_value(CombatAttributes.Id.CARRY_CAPACITY, load)
	_check(encumbered != null and encumbered.finished
			and _system.get_active_cast(ENCUMBERED_ACTION) == null
			and _system.effects.get_retained_effects().is_empty()
			and _system.tags.get_count(ENCUMBERED_TAG) == 0,
			"Raising capacity to the current weight ends the action and removes its effect immediately")
	await _step(FORWARD, true)
	_check(_system.get_active_cast(SPRINT) == null, "A held Sprint key stays latched after the interruption")
	await _step(FORWARD)
	await _step(FORWARD, true)
	_check(_system.get_active_cast(SPRINT) != null and cast != null and _system.get_animation_cast() == cast,
			"A fresh Sprint press works after load recovery while Fireball continues")


func _test_startup_and_revive_encumbrance() -> void:
	var attributes := _system.attributes
	var capacity := attributes.get_value(CombatAttributes.Id.CARRY_CAPACITY)
	var load := attributes.get_value(CombatAttributes.Id.CARRIED_WEIGHT)
	var definition := _system.get_ability_definition(ENCUMBERED_ACTION)
	_check(definition != null and _system.granted_abilities.has(definition)
			and not "encumbered_effect" in _system,
			"The saved actor grants Encumbered through the same list as its other actions")
	_check(load > capacity and _system.get_active_cast(ENCUMBERED_ACTION) != null
			and _system.tags.get_count(ENCUMBERED_TAG) == 1
			and _system.effects.active_count(ENCUMBERED.effect_id) == 1,
			"A saved actor with starting overload activates Encumbered without a later attribute change")
	var other_handle := _system.effects.apply_effect(ENCUMBERED, _system.create_effect_context())
	_check(_system.effects.has_retained_effect(other_handle) and _system.tags.get_count(ENCUMBERED_TAG) == 2,
			"Two instances of the same effect may each own the counted tag")
	attributes.set_base_value(CombatAttributes.Id.CARRY_CAPACITY, load)
	_check(_system.get_active_cast(ENCUMBERED_ACTION) == null
			and _system.effects.active_count(ENCUMBERED.effect_id) == 1
			and _system.effects.has_retained_effect(other_handle)
			and _system.tags.get_count(ENCUMBERED_TAG) == 1,
			"Resolving overload removes only the effect handle owned by the Encumbered action")
	_system.effects.remove_effect(other_handle)
	attributes.set_base_value(CombatAttributes.Id.CARRY_CAPACITY, capacity)
	var encumbered := _system.get_active_cast(ENCUMBERED_ACTION)
	_check(_system.tags.get_count(ENCUMBERED_TAG) == 1 and _system.try_activate(FIREBALL)
			and _system.get_animation_cast() == _system.get_active_cast(FIREBALL),
			"Fireball can take animation ownership while the player is already encumbered")
	attributes.set_base_value(CombatAttributes.Id.HEALTH, 0.0)
	_check(_system.tags.has_tag(&"State.Dead") and _system.tags.get_count(ENCUMBERED_TAG) == 0
			and encumbered != null and encumbered.finished and _system.get_active_cast(ENCUMBERED_ACTION) == null
			and _system.effects.get_retained_effects().is_empty() and _system.get_animation_cast() == null,
			"Dying clears Fireball and Encumbered even while the load remains above capacity")
	attributes.restore_resources()
	var revived := _system.get_active_cast(ENCUMBERED_ACTION)
	_check(not _system.tags.has_tag(&"State.Dead") and _system.tags.get_count(ENCUMBERED_TAG) == 1
			and revived != null and revived != encumbered
			and _system.effects.active_count(ENCUMBERED.effect_id) == 1,
			"Reviving with the same overloaded weight starts a fresh Encumbered action")


func _test_revoke_encumbered_grant() -> void:
	var attributes := _system.attributes
	var encumbered := _system.get_active_cast(ENCUMBERED_ACTION)
	var definition := _system.get_ability_definition(ENCUMBERED_ACTION)
	_system.revoke_ability(ENCUMBERED_ACTION)
	attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT,
			attributes.get_value(CombatAttributes.Id.CARRY_CAPACITY) + 50.0)
	_check(_system.get_ability_definition(ENCUMBERED_ACTION) == null
			and encumbered != null and encumbered.finished and _system.get_active_cast(ENCUMBERED_ACTION) == null
			and _system.effects.get_retained_effects().is_empty() and _system.tags.get_count(ENCUMBERED_TAG) == 0,
			"Revoking Encumbered removes its effect and prevents a new cast on another load change")
	_check(_system.grant_ability(definition) and _system.get_active_cast(ENCUMBERED_ACTION) != null
			and _system.tags.get_count(ENCUMBERED_TAG) == 1,
			"Regranting Encumbered re-evaluates the existing load and activates immediately")


func _test_interrupt_encumbrance_application() -> void:
	var attributes := _system.attributes
	var capacity := attributes.get_value(CombatAttributes.Id.CARRY_CAPACITY)
	var interrupted: Array[AbilityCast] = []
	var interrupt_on_apply := func(tag: StringName, present: bool) -> void:
		if tag == ENCUMBERED_TAG and present and interrupted.is_empty():
			interrupted.append(_system.get_active_cast(ENCUMBERED_ACTION))
			_system.cancel_ability(ENCUMBERED_ACTION)
			attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, capacity)
	_system.tags.changed.connect(interrupt_on_apply)
	attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, capacity + 1.0)
	await process_frame
	_system.tags.changed.disconnect(interrupt_on_apply)
	_check(interrupted.size() == 1 and interrupted[0] != null and interrupted[0].finished
			and _system.get_active_cast(ENCUMBERED_ACTION) == null
			and _system.effects.get_retained_effects().is_empty() and _system.tags.get_count(ENCUMBERED_TAG) == 0,
			"Resolving load during the tag notification cancels the cast without leaking the in-flight effect")
	attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, capacity + 1.0)
	_check(_system.get_active_cast(ENCUMBERED_ACTION) != null
			and _system.effects.active_count(ENCUMBERED.effect_id) == 1
			and _system.tags.get_count(ENCUMBERED_TAG) == 1,
			"A later overload can activate normally after an interrupted application")


func _test_reusable_gameplay_events() -> void:
	var test_action := &"test_event_action"
	var test_tag := &"State.TestEventAction"
	var activation_event := &"Event.TestAction.Entered"
	var child_activation_event := &"Event.TestAction.Entered.Child"
	var finish_event := &"Event.TestAction.Exited"
	var effect := GameplayEffectDefinition.new()
	effect.effect_id = &"Effect.TestEventAction"
	effect.kind = GameplayEffectDefinition.Kind.MODIFIERS
	effect.timing = GameplayEffectDefinition.Timing.DURATION
	effect.granted_tags = PackedStringArray([String(test_tag)])
	var execution := EventProbeExecution.new()
	execution.effect = effect
	execution.end_on_event_tag = finish_event
	var definition := AbilityDefinition.new()
	definition.ability_id = test_action
	definition.ability_tags = PackedStringArray(["Ability.Status.TestEventAction"])
	definition.activation_event_tag = activation_event
	definition.execution = execution
	_check(_system.grant_ability(definition), "The ASC accepts an unrelated gameplay event action")
	_check(_system.get_activation_failure(test_action) == &"requires_gameplay_event"
			and not _system.try_activate(test_action),
			"An event-triggered grant requires its gameplay event for activation")
	_system.send_gameplay_event(&"Event.OtherAction.Entered")
	_system.send_gameplay_event(&"Event.TestAction")
	_check(_system.get_active_cast(test_action) == null and _system.tags.get_count(test_tag) == 0,
			"Unrelated events and parent tags do not activate a more specific trigger")
	var payload := {"threshold": {"value": 10.0}}
	_system.send_gameplay_event(child_activation_event, payload)
	payload["threshold"]["value"] = 11.0
	var cast := _system.get_active_cast(test_action)
	_check(cast != null and cast.trigger_event_tag == child_activation_event
			and cast.trigger_event_payload.get("threshold", {}).get("value") == 10.0
			and _system.tags.get_count(test_tag) == 1,
			"A child event activates the parent trigger and the cast keeps a detached tag and payload")
	_system.send_gameplay_event(activation_event)
	_check(_system.get_active_cast(test_action) == cast and _system.tags.get_count(test_tag) == 1,
			"Another matching activation event preserves the running cast and its one effect")
	_system.send_gameplay_event(&"Event.TestAction.Queue")
	_check(cast != null and cast.data.get("event_order") == [0, 42, 43],
			"Nested gameplay events reach the active execution in order after the current callback finishes")
	_system.send_gameplay_event(finish_event)
	_check(cast != null and cast.finished and _system.get_active_cast(test_action) == null
			and _system.tags.get_count(test_tag) == 0,
			"The authored finish event ends the action and releases its effect")
	_system.send_gameplay_event(activation_event)
	_check(_system.get_active_cast(test_action) != null and _system.tags.get_count(test_tag) == 1,
			"A later matching event can start a fresh activation")
	_system.revoke_ability(test_action)
	_system.send_gameplay_event(activation_event)
	_check(_system.get_active_cast(test_action) == null and _system.tags.get_count(test_tag) == 0
			and _system.get_active_cast(ENCUMBERED_ACTION) != null
			and _system.tags.get_count(ENCUMBERED_TAG) == 1,
			"Revoking one event grant unsubscribes its events and preserves the independent Encumbered action")


func _step(
		movement_input: Vector2 = Vector2.ZERO,
		sprint_held: bool = false,
		jump_pressed: bool = false,
		crouch_pressed: bool = false,
		crouch_held: bool = false
) -> void:
	await physics_frame
	_player.advance_locomotion(STEP, movement_input, jump_pressed, crouch_pressed, crouch_held, sprint_held)


func _event_position(clip: Animation, event_name: StringName) -> float:
	for track in clip.get_track_count():
		if clip.track_get_type(track) != Animation.TYPE_METHOD:
			continue
		for key in clip.track_get_key_count(track):
			var event: Dictionary = clip.track_get_key_value(track, key)
			if event.get("method") == &"handle_animation_event" and event.get("args") == [event_name]:
				return clip.track_get_key_time(track, key)
	return -1.0


func _projectile_count() -> int:
	var count := 0
	for child in _arena.get_children():
		if child is AbilityProjectile and not child.is_queued_for_deletion():
			count += 1
	return count


func _on_dummy_combat_event(event: Dictionary) -> void:
	if event.get("type") == &"hit_outcome" and event.get("ability_id") == FIREBALL and event.get("outcome") == &"hit":
		_fireball_hits += 1


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
