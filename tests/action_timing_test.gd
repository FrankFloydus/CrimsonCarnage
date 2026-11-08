extends SceneTree
## Verifies the saved Fireball wiring and tests playback and cooldown with controlled inputs.
## Run headless with --fixed-fps 60 --script res://tests/action_timing_test.gd.

const PLAYER_SCENE = preload("res://player/player.tscn")
const FIREBALL_FIXTURE = preload("res://tests/fireball_fixture.gd")
const FIREBALL_ID := FIREBALL_FIXTURE.FIREBALL

var _arena: Node3D
var _system: AbilitySystem
var _animation: AnimationPlayer
var _router: PlayerActionRouter
var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	for scenario: Callable in [_test_spell_release, _test_sampled_cast_speed,
			_test_near_muzzle_cover, _test_authored_cooldown, _test_press_hold_and_release_slots,
			_test_charged_slot_release]:
		if await _start_fixture():
			await scenario.call()
		await _end_fixture()
	print("Action timing checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _start_fixture() -> bool:
	_arena = Node3D.new()
	var player := PLAYER_SCENE.instantiate() as Player
	(player.get_node("Attributes") as ActorAttributes).initial_modifiers = []
	_arena.add_child(player)
	_system = player.get_node("AbilitySystem") as AbilitySystem
	preload("res://tests/attribute_fixture.gd").configure(_system)
	root.add_child(_arena)
	current_scene = _arena
	player.set_physics_process(false)
	_router = player.get_node("ActionRouter") as PlayerActionRouter
	_router.set_process_unhandled_input(false)
	_system.set_process(false)
	_system.set_physics_process(false)
	_system.attributes.set_base_value(CombatAttributes.Id.MAX_MANA, 100.0)
	_system.attributes.set_base_value(CombatAttributes.Id.MANA, 100.0)
	_animation = _system.animation_player
	await physics_frame
	await physics_frame
	var valid := FIREBALL_FIXTURE.install(_system)
	_check(valid, "The saved Fireball has valid playback, delivery and commit-effect wiring")
	return valid


func _end_fixture() -> void:
	_arena.queue_free()
	await process_frame


func _test_spell_release() -> void:
	_check(_system.try_activate(FIREBALL_ID), "The Fireball fixture begins")
	var cast := _system.get_active_cast(FIREBALL_ID)
	var execution := cast.definition.execution as PhasedAbilityExecution
	var clip := _animation.get_animation(execution.animation_name)
	_close(_animation.get_playing_speed(), 1.0, "Spell playback uses its authored animation timing")
	_system.advance_animation(FIREBALL_FIXTURE.RELEASE_TIME - 0.001)
	_check(not cast.released and _projectile_count() == 0,
			"Fireball cannot release before its animation method key")
	_system.advance_animation(0.002)
	_check(cast.released and _projectile_count() == 1,
			"Crossing the method key releases exactly one projectile")
	if cast.released and cast.data.has(&"projectile"):
		var projectile := (cast.data[&"projectile"] as WeakRef).get_ref() as AbilityProjectile
		_check(projectile.global_position.is_equal_approx(_system.cast_origin.global_position),
				"Fireball spawns at the saved projectile origin")
	_system.handle_animation_event(execution.release_event)
	_check(_projectile_count() == 1, "A duplicate release event cannot duplicate the projectile")
	_system.advance_animation(FIREBALL_FIXTURE.CLIP_LENGTH - FIREBALL_FIXTURE.RELEASE_TIME + 0.002)
	_check(cast.finished and _system.get_animation_cast() == null, "The same animation completes the action")
	_check(not _system.tags.has_tag(&"State.CombatAction"),
			"Completion removes the action's owned lock")
	_close(clip.length, FIREBALL_FIXTURE.CLIP_LENGTH, "Playback does not rewrite the animation duration")


func _test_sampled_cast_speed() -> void:
	_system.attributes.set_base_value(CombatAttributes.Id.ATTACK_SPEED, 100.0)
	_system.attributes.set_base_value(CombatAttributes.Id.CAST_SPEED, 50.0)
	_check(_system.try_activate(FIREBALL_ID), "Fireball starts with increased Cast Speed")
	var cast := _system.get_active_cast(FIREBALL_ID)
	var execution := cast.definition.execution as PhasedAbilityExecution
	var clip := _animation.get_animation(execution.animation_name)
	var windup := FIREBALL_FIXTURE.RELEASE_TIME / 1.5
	_close(_animation.get_playing_speed(), 1.5, "Fireball only samples Cast Speed")
	_system.attributes.set_base_value(CombatAttributes.Id.CAST_SPEED, 150.0)
	_system.advance_animation(windup * 0.5)
	_close(execution.get_windup_progress(cast), 0.5, "Windup progress uses the actual playback position")
	_system.advance_animation(windup * 0.5 - 0.001)
	_check(not cast.released and _projectile_count() == 0,
			"The sampled speed stays stable until the authored marker")
	_system.advance_animation(0.002)
	_check(cast.released and _projectile_count() == 1, "Faster playback crosses the same release key")
	_close(execution.get_windup_progress(cast), -1.0, "Release hides windup progress during recovery")
	_system.advance_animation(clip.length)
	_system.advance(_system.get_cooldown_remaining(FIREBALL_ID) + 0.001)
	_check(_system.try_activate(FIREBALL_ID), "The next Fireball samples the changed stat")
	cast = _system.get_active_cast(FIREBALL_ID)
	_close(_animation.get_playing_speed(), 2.0, "Cast Speed caps at twice the authored rate")
	_system.cancel_ability(FIREBALL_ID)
	_close(execution.get_windup_progress(cast), -1.0, "Cancellation hides windup progress")
	_check(not cast.released, "A cancelled cast never reaches its release")


func _test_near_muzzle_cover() -> void:
	var wall := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.0, 1.0, 0.1)
	collision.shape = shape
	wall.add_child(collision)
	_arena.add_child(wall)
	var view := _system.aim_origin.global_transform
	wall.global_transform = Transform3D(view.basis, view.origin - view.basis.z * 0.3)
	await physics_frame
	await physics_frame
	_check(_system.try_activate(FIREBALL_ID), "Close cover does not change cast eligibility")
	var cast := _system.get_active_cast(FIREBALL_ID)
	var execution := cast.definition.execution as PhasedAbilityExecution
	_system.advance_animation(FIREBALL_FIXTURE.RELEASE_TIME + 0.001)
	_check(cast.released and _projectile_count() == 0,
			"A crosshair hit between the camera and muzzle blocks the projectile")
	_close(execution.get_windup_progress(cast), -1.0, "Blocked release still ends the windup")


func _test_authored_cooldown() -> void:
	var before := _system.attributes.get_value(CombatAttributes.Id.MANA)
	_check(_system.try_activate(FIREBALL_ID), "An authored-cooldown ability starts")
	_close(_system.get_cooldown_remaining(FIREBALL_ID), FIREBALL_FIXTURE.COOLDOWN,
			"The cooldown starts with its authored duration")
	_close(before - _system.attributes.get_value(CombatAttributes.Id.MANA),
			FIREBALL_FIXTURE.COST,
			"Activation commits exactly the authored resource amount")
	var after := _system.attributes.get_value(CombatAttributes.Id.MANA)
	_check(not _system.try_activate(FIREBALL_ID), "An overlapping activation is rejected")
	_close(_system.attributes.get_value(CombatAttributes.Id.MANA), after,
			"A rejected activation does not charge another resource cost")
	_system.advance_animation(FIREBALL_FIXTURE.CLIP_LENGTH + 0.001)
	_system.advance(FIREBALL_FIXTURE.COOLDOWN / 2.0)
	_check(_system.get_active_cast(FIREBALL_ID) == null, "The action can finish before its cooldown")
	_check(_system.get_activation_failure(FIREBALL_ID) == &"no_charges",
			"Animation completion does not bypass the remaining cooldown")
	_close(_system.get_cooldown_remaining(FIREBALL_ID), FIREBALL_FIXTURE.COOLDOWN / 2.0,
			"Cooldown time advances independently of animation time")
	_system.advance(FIREBALL_FIXTURE.COOLDOWN / 2.0 + 0.001)
	_check(_system.try_activate(FIREBALL_ID), "The ability can start after the cooldown deadline")
	_system.cancel_ability(FIREBALL_ID)
	_check(_system.get_active_cast(FIREBALL_ID) == null, "Explicit interruption clears the active action")


func _test_press_hold_and_release_slots() -> void:
	var primary := PlayerActionRouter.PRIMARY_SLOT
	var secondary := &"ability_slot_2"
	_check(_router.get_slot_ability(primary) == 20 and _router.get_slot_ability(secondary) == FIREBALL_ID,
			"The saved loadout assigns the two independently bound combat slots")
	_check(_key(KEY_Q, true) and _system.get_active_cast(FIREBALL_ID) != null,
			"Press activates the ability assigned to Q immediately")
	_key(KEY_Q, false)
	_system.cancel_ability(FIREBALL_ID)

	var on_release := _grant_gesture(301, AbilityDefinition.InputGesture.RELEASE,
			PhasedAbilityExecution.CastMode.IMMEDIATE)
	var held := _grant_gesture(302, AbilityDefinition.InputGesture.HOLD,
			PhasedAbilityExecution.CastMode.SUSTAINED)
	_router.set_slot_ability(primary, on_release.ability_id)
	_router.set_slot_ability(secondary, held.ability_id)
	_key(KEY_F, true)
	_check(_system.get_active_cast(on_release.ability_id) == null, "Release arms without casting on button-down")
	_key(KEY_Q, true)
	var held_cast := _system.get_active_cast(held.ability_id)
	_check(held_cast != null and not held_cast.finished, "Hold starts a sustained cast on button-down")
	_key(KEY_Q, false)
	_check(held_cast != null and held_cast.finished, "Hold ends its sustained cast on button-up")
	_router.set_slot_ability(primary, held.ability_id)
	_key(KEY_F, false)
	_check(_system.get_active_cast(on_release.ability_id) != null
			and _system.get_active_cast(held.ability_id) == null,
			"Release activates the grant armed on button-down after a slot change")
	_system.cancel_ability(on_release.ability_id)
	_router.set_slot_ability(primary, on_release.ability_id)
	_key(KEY_F, true)
	_router.cancel_pending_input()
	_key(KEY_F, false)
	_check(_system.get_active_cast(on_release.ability_id) == null, "Cancellation clears an armed Release")


func _test_charged_slot_release() -> void:
	var definition := _system.get_ability_definition(FIREBALL_ID).duplicate() as AbilityDefinition
	definition.ability_id = 303
	definition.input_gesture = AbilityDefinition.InputGesture.HOLD_RELEASE
	_check(_system.grant_ability(definition)
			and _router.set_slot_ability(PlayerActionRouter.PRIMARY_SLOT, definition.ability_id),
			"A Hold + release animation ability can occupy the primary slot")
	_key(KEY_F, true)
	var cast := _system.get_active_cast(definition.ability_id)
	if cast == null:
		_check(false, "The charged cast begins on button-down")
		return
	_system.advance_animation(FIREBALL_FIXTURE.CLIP_LENGTH)
	_check(not cast.released and _projectile_count() == 0, "Holding does not start the release animation")
	_click(true)
	_key(KEY_F, false)
	_system.advance_animation(FIREBALL_FIXTURE.CLIP_LENGTH)
	_check(not cast.released and _projectile_count() == 0, "The second physical binding still holds the slot")
	_click(false)
	_system.advance_animation(FIREBALL_FIXTURE.RELEASE_TIME - 0.001)
	_check(not cast.released and _projectile_count() == 0, "Button-up starts the release animation before its marker")
	_system.advance_animation(0.002)
	_check(cast.released and _projectile_count() == 1, "The release marker launches exactly one charged projectile")
	_system.advance_animation(FIREBALL_FIXTURE.CLIP_LENGTH)
	_system.advance(FIREBALL_FIXTURE.COOLDOWN + 0.01)
	_key(KEY_F, true)
	var interrupted := _system.get_active_cast(definition.ability_id)
	_router.cancel_pending_input()
	_key(KEY_F, false)
	_check(interrupted != null and interrupted.finished and not interrupted.released and _projectile_count() == 1,
			"Losing input ownership cancels a held cast without launching another projectile")


func _grant_gesture(ability_id: int, gesture: AbilityDefinition.InputGesture,
		mode: PhasedAbilityExecution.CastMode) -> AbilityDefinition:
	var definition := AbilityDefinition.new()
	definition.ability_id = ability_id
	definition.input_gesture = gesture
	var execution := PhasedAbilityExecution.new()
	execution.cast_mode = mode
	execution.delivery = AbilityDeliveryDefinition.new()
	execution.delivery.kind = AbilityDeliveryDefinition.Kind.NONE
	definition.execution = execution
	_check(_system.grant_ability(definition), "The input fixture grants ability %d" % ability_id)
	return definition


func _key(code: Key, pressed: bool) -> bool:
	var event := InputEventKey.new()
	event.device = InputEvent.DEVICE_ID_KEYBOARD
	event.physical_keycode = code
	event.pressed = pressed
	return _router.handle_action_event(event)


func _click(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.device = InputEvent.DEVICE_ID_MOUSE
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	_router.handle_action_event(event)


func _projectile_count() -> int:
	var count := 0
	for child in _arena.get_children():
		if child is AbilityProjectile and not child.is_queued_for_deletion():
			count += 1
	return count


func _close(actual: float, expected: float, message: String) -> void:
	_check(absf(actual - expected) < 0.0001, "%s (%f / %f)" % [message, actual, expected])


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
