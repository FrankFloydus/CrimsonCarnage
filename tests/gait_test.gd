extends SceneTree
## Headless gait selection and physical movement checks using the saved controller.
## Run: godot --headless --path . --fixed-fps 60 --script res://tests/gait_test.gd

const CONTROLLER = preload("res://player/first_person_controller.tscn")
const SPRINT_FIXTURE = preload("res://tests/sprint_fixture.gd")

var _world: Node3D
var _player: CharacterBody3D
var _movement: FirstPersonMovement
var _has_authored_movement_settings := false
var _gait: FirstPersonGait
var _crouch: FirstPersonCrouch
var _look: FirstPersonLook
var _checks: int = 0
var _failures: int = 0
var _delta: float = 1.0 / 60.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	Engine.physics_ticks_per_second = 60
	_test_bindings()
	await _test_selection_and_overrides()
	await _test_instance_isolation()
	await _test_exhaustion_and_release()
	await _test_movement_speeds()
	await _test_crouch_and_obstruction()
	await _test_jump_heights()
	print("Gait checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_bindings() -> void:
	_check(_has_physical_key(&"sprint", KEY_SHIFT), "Sprint is bound to physical Shift")
	_check(_has_physical_key(&"walk", KEY_CTRL), "Walk is bound to physical Ctrl")
	_check(not _has_physical_key(&"walk", KEY_CAPSLOCK), "Walk does not use Caps Lock")


func _test_selection_and_overrides() -> void:
	await _start_fixture()
	_check(_has_authored_movement_settings and _movement.attributes == _player.get_node("Attributes")
			and not _player.has_node("Gait") and _gait is RefCounted,
			"Movement binds the saved actor while gait remains a per-controller runtime helper")
	_check(_gait.current_gait == FirstPersonGait.Gait.RUN, "Standing defaults to running")
	_gait.advance(true, false, false)
	_check(_gait.current_gait == FirstPersonGait.Gait.SPRINT,
			"Holding Shift selects affordable sprint")
	for tick in 5:
		_gait.advance(true, false, false)
	_check(_gait.current_gait == FirstPersonGait.Gait.SPRINT,
			"A continuing hold keeps sprint selected without repeated press events")
	_gait.advance(false, false, false)
	_check(_gait.current_gait == FirstPersonGait.Gait.RUN,
			"Releasing Shift immediately selects ordinary running")
	_gait.advance(true, true, false)
	_check(_gait.current_gait == FirstPersonGait.Gait.WALK and not _gait.sprint_requires_release,
			"Holding Ctrl temporarily walks while Shift remains held")
	for tick in 10:
		await _step(Vector2.RIGHT, true, true)
	_check_close(_horizontal_speed(), _movement.get_speed_for_gait(FirstPersonGait.Gait.WALK),
			"Selected walking moves at the speed authored on Movement")
	_gait.advance(true, false, false)
	_check(_gait.current_gait == FirstPersonGait.Gait.SPRINT,
			"Releasing Ctrl resumes sprint when Shift is still held")
	_gait.advance(false, true, false)
	_check(_gait.current_gait == FirstPersonGait.Gait.WALK,
			"Releasing Shift while holding Ctrl keeps walking")
	_gait.advance(false, false, false)
	_check(_gait.current_gait == FirstPersonGait.Gait.RUN,
			"Releasing both modifiers selects ordinary running")
	_gait.advance(true, false, false)
	_gait.advance(true, false, false, false)
	_check(_gait.current_gait == FirstPersonGait.Gait.RUN and not _gait.sprint_requires_release,
			"Inactive controls prevent sprint even while Shift is held")
	_gait.advance(false, false, false)
	_check(_gait.current_gait == FirstPersonGait.Gait.RUN,
			"Resuming controls without Shift cannot retain a previous sprint request")
	_gait.advance(true, true, true, false)
	_check(_gait.current_gait == FirstPersonGait.Gait.CROUCH and not _gait.sprint_requires_release,
			"Inactive controls preserve actual crouch without accepting gait input")
	await _end_fixture()


func _test_instance_isolation() -> void:
	await _start_fixture()
	var second: CharacterBody3D = CONTROLLER.instantiate()
	second.position = Vector3(8.0, 0.03, 0.0)
	_world.add_child(second)
	_disable_automatic_processing(second)
	var other_gait: FirstPersonGait = (second as FirstPersonController)._gait
	_gait.advance(true, false, false, true, false)
	other_gait.advance(true, false, false)
	_check(_gait != other_gait and _gait.sprint_requires_release
			and not other_gait.sprint_requires_release,
			"The exhaustion release latch belongs to each controller instance")
	_check(_gait.current_gait == FirstPersonGait.Gait.RUN
			and other_gait.current_gait == FirstPersonGait.Gait.SPRINT,
			"One exhausted player cannot suppress another player's held sprint")
	var other_attributes := second.get_node("Attributes") as ActorAttributes
	var other_stamina := other_attributes.get_value(CombatAttributes.Id.STAMINA)
	_movement.attributes.modify_current(CombatAttributes.Id.STAMINA, -25.0)
	_check_close(other_attributes.get_value(CombatAttributes.Id.STAMINA), other_stamina,
			"Each saved controller owns an independent Stamina pool")
	await _end_fixture()


func _test_exhaustion_and_release() -> void:
	await _start_fixture()
	var attributes := _movement.attributes
	var system := _player.get_node("AbilitySystem") as AbilitySystem
	system.set_process(false)
	attributes.set_base_value(CombatAttributes.Id.STAMINA, 2.0)
	for tick in 6:
		await _step(Vector2.RIGHT, true)
	await _step(Vector2.RIGHT, true)
	_check(_gait.sprint_requires_release and _movement.effective_gait == FirstPersonGait.Gait.RUN,
			"Draining Sprint switches to running and requires Shift release")
	system.advance(SPRINT_FIXTURE.EXHAUSTION_DURATION + 0.1)
	attributes.advance_regeneration(1.0)
	await _step(Vector2.RIGHT, true)
	_check(system.get_activation_failure(&"sprint").is_empty() and _gait.sprint_requires_release
			and _movement.effective_gait == FirstPersonGait.Gait.RUN,
			"Recovered Stamina cannot automatically restart a held exhausted sprint")
	await _step(Vector2.RIGHT)
	await _step(Vector2.RIGHT, true)
	_check(not _gait.sprint_requires_release and _movement.effective_gait == FirstPersonGait.Gait.SPRINT,
			"Releasing and pressing Shift again restarts affordable sprint")
	_gait.advance(true, false, false, true, false)
	_gait.advance(true, true, false)
	_check(_gait.sprint_requires_release and _gait.current_gait == FirstPersonGait.Gait.WALK,
			"An existing exhaustion latch survives temporary walking")
	_gait.advance(false, true, false)
	_check(not _gait.sprint_requires_release,
			"Releasing Shift clears the exhaustion latch even while Ctrl is held")
	_gait.advance(true, false, false, true, false)
	_gait.advance(false, false, true)
	_check(not _gait.sprint_requires_release,
			"Releasing Shift clears the exhaustion latch even while crouched")
	await _end_fixture()


func _test_movement_speeds() -> void:
	await _start_fixture()
	var run_speed := _movement.settings.normal_run_speed
	var sprint_speed := run_speed * _movement.settings.sprint_speed_multiplier
	var walk_speed := run_speed * _movement.settings.walk_speed_multiplier
	for tick in 25:
		await _step(Vector2.RIGHT)
	_check_close(_horizontal_speed(), run_speed, "Ordinary movement reaches authored normal run speed")
	await _step(Vector2.RIGHT, true)
	_check_close(_horizontal_speed(), run_speed + _movement.settings.ground_acceleration * _delta,
			"Holding Shift accelerates through the existing ground response")
	for tick in 30:
		await _step(Vector2.RIGHT, true)
	_check_close(_horizontal_speed(), sprint_speed,
			"Holding Shift reaches the authored sprint multiple of normal run speed")
	for tick in 30:
		await _step(Vector2(1.0, -1.0), true)
	_check_close(_horizontal_speed(), sprint_speed,
			"Sprint diagonal movement obeys the sprint speed limit")
	await _step(Vector2.ZERO, true)
	_check_close(_horizontal_speed(), sprint_speed - _movement.settings.ground_deceleration * _delta,
			"No movement input brakes normally while Shift remains held")
	for tick in 30:
		await _step(Vector2.RIGHT, true, true)
	_check_close(_horizontal_speed(), walk_speed,
			"Holding Ctrl slows physical movement to walk speed")
	for tick in 30:
		await _step(Vector2.RIGHT, true)
	_check_close(_horizontal_speed(), sprint_speed,
			"Releasing Ctrl restores physical sprint speed while Shift is still held")
	for tick in 30:
		await _step(Vector2.RIGHT)
	_check_close(_horizontal_speed(), run_speed,
			"Releasing Shift restores physical run speed")
	await _end_fixture()


func _test_crouch_and_obstruction() -> void:
	await _start_fixture()
	await _step(Vector2.ZERO, true)
	await _step(Vector2.ZERO, true, false, true)
	_check(_crouch.is_crouching and _gait.current_gait == FirstPersonGait.Gait.CROUCH
			and not _gait.sprint_requires_release, "Entering crouch prevents held sprint without exhaustion")
	for tick in 10:
		await _step(Vector2.RIGHT, true)
	_check_close(_horizontal_speed(), _movement.get_speed_for_gait(FirstPersonGait.Gait.CROUCH),
			"Selected crouch moves at the speed authored on Movement")
	_add_box(Vector3(0.0, 1.4, 0.0), Vector3(3.0, 0.2, 3.0))
	await _step(Vector2.ZERO, true)
	_check(_crouch.is_crouching and _gait.current_gait == FirstPersonGait.Gait.CROUCH,
			"Holding Shift while crouched cannot stand the player")
	await _step(Vector2.ZERO, true, false, true)
	_check(_crouch.is_crouching and _gait.current_gait == FirstPersonGait.Gait.CROUCH,
			"A blocked stand request with Shift cannot select sprint under a roof")
	for tick in 30:
		await _step(Vector2.RIGHT, true, true)
	_check(_gait.current_gait == FirstPersonGait.Gait.CROUCH_WALK,
			"Holding Ctrl while crouched selects crouch walking")
	_check_close(_horizontal_speed(), _movement.get_speed_for_gait(FirstPersonGait.Gait.CROUCH_WALK),
			"Crouch walking moves at its slower authored speed")
	for tick in 30:
		await _step(Vector2.RIGHT, true)
	_check_close(_horizontal_speed(), _movement.get_speed_for_gait(FirstPersonGait.Gait.CROUCH),
			"Releasing Ctrl restores the ordinary crouch speed")
	_player.position.x = 10.0
	await _step(Vector2.ZERO, true, false, true)
	_check(not _crouch.is_crouching and _gait.current_gait == FirstPersonGait.Gait.SPRINT,
			"Standing in open space while Shift remains held resumes sprint")
	await _step()
	_check(_gait.current_gait == FirstPersonGait.Gait.RUN,
			"Releasing Shift after standing returns to ordinary running")
	await _end_fixture()


func _test_jump_heights() -> void:
	await _start_fixture()
	await _step(Vector2.ZERO, true)
	await _step(Vector2.ZERO, true, false, false, true)
	_check_close(_player.velocity.y, 0.0, "Active Sprint blocks Jump while standing still")
	await _step(Vector2.ZERO, false, false, false, true)
	_check_close(_player.velocity.y,
			sqrt(2.0 * _movement.settings.gravity * _movement.settings.jump_height),
			"Releasing Sprint before Jump restores the authored standing jump height")
	await _end_fixture()
	await _start_fixture()
	await _step(Vector2.ZERO, false, false, true)
	await _step(Vector2.ZERO, false, true, false, true)
	_check(_gait.current_gait == FirstPersonGait.Gait.CROUCH_WALK,
			"Crouch walking remains selected for a crouched jump")
	_check_close(_player.velocity.y,
			sqrt(2.0 * _movement.settings.gravity * _movement.settings.crouch_jump_height),
			"Crouch walking retains the reduced crouched jump height")
	await _end_fixture()


func _start_fixture() -> void:
	_world = Node3D.new()
	root.add_child(_world)
	_add_box(Vector3(0.0, -0.5, 0.0), Vector3(200.0, 1.0, 200.0))
	_player = CONTROLLER.instantiate()
	_player.position = Vector3(0.0, 0.03, 0.0)
	var system := _player.get_node("AbilitySystem") as AbilitySystem
	SPRINT_FIXTURE.configure(system)
	var attributes := _player.get_node("Attributes") as ActorAttributes
	attributes.initial_modifiers = []
	_world.add_child(_player)
	_disable_automatic_processing(_player)
	_movement = _player.get_node("Movement")
	_gait = (_player as FirstPersonController)._gait
	_has_authored_movement_settings = _movement.settings != null
	_movement.settings = FirstPersonMovementSettings.new()
	_crouch = _player.get_node("Crouch")
	_crouch.settings = FirstPersonCrouchSettings.new()
	_look = _player.get_node("Look")
	attributes.set_base_value(CombatAttributes.Id.MAX_STAMINA, 100.0)
	attributes.set_base_value(CombatAttributes.Id.STAMINA_REGEN, 10.0)
	attributes.set_base_value(CombatAttributes.Id.CARRIED_WEIGHT, 0.0)
	attributes.set_base_value(CombatAttributes.Id.MOVEMENT_SPEED, 0.0)
	attributes.restore_resources()
	for tick in 10:
		await _step()


func _end_fixture() -> void:
	_world.queue_free()
	await process_frame
	_world = null
	_player = null


func _disable_automatic_processing(player: CharacterBody3D) -> void:
	player.set_physics_process(false)
	player.get_node("Attributes").set_physics_process(false)
	player.get_node("Crouch").set_process(false)
	player.get_node("Look").set_process(false)
	player.get_node("Look").set_process_unhandled_input(false)


func _step(direction: Vector2 = Vector2.ZERO, sprint_held: bool = false,
		walk_held: bool = false, crouch_pressed: bool = false, jump_requested: bool = false) -> void:
	await physics_frame
	(_player as FirstPersonController).advance_locomotion(
			_delta, direction, jump_requested, crouch_pressed, crouch_pressed, sprint_held, walk_held
	)
	_movement.attributes.advance_regeneration(_delta)
	_crouch._process(_delta)
	_look._process(_delta)


func _add_box(center: Vector3, size: Vector3) -> void:
	var obstacle := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	obstacle.position = center
	obstacle.add_child(collision)
	_world.add_child(obstacle)


func _has_physical_key(action: StringName, key: Key) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey and event.physical_keycode == key:
			return true
	return false


func _horizontal_speed() -> float:
	return Vector2(_player.velocity.x, _player.velocity.z).length()


func _check_close(actual: float, expected: float, description: String) -> void:
	_check(absf(actual - expected) < 0.001,
			"%s (actual %.4f, expected %.4f)" % [description, actual, expected])


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)
