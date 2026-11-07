extends SceneTree
## Headless stance and headroom checks using the saved controller and temporary obstacle fixtures.
## Run: godot --headless --path . --fixed-fps 60 --script res://tests/crouch_test.gd

const CONTROLLER = preload("res://player/first_person_controller.tscn")
const LOCOMOTION_FIXTURE = preload("res://tests/locomotion_fixture.gd")

var _world: Node3D
var _player: CharacterBody3D
var _movement: FirstPersonMovement
var _crouch: FirstPersonCrouch
var _look: FirstPersonLook
var _collision: CollisionShape3D
var _capsule: CapsuleShape3D
var _checks: int = 0
var _failures: int = 0
var _delta: float = 1.0 / Engine.physics_ticks_per_second


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_input_binding()
	await _test_toggle_and_shape_isolation()
	await _test_eye_transitions()
	await _test_one_shot()
	await _test_blocked_toggle()
	await _test_capsule_clearance_and_filters()
	await _test_airborne_entry()
	await _test_crouched_movement()
	await _test_crouched_jump()
	await _test_crouched_coyote_jump()
	await _test_crouch_on_stairs()
	await _test_tunnel_traversal()
	await _test_tunnel_transition_clearance()
	print("Crouch checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_input_binding() -> void:
	_check(InputMap.has_action(&"crouch") and not InputMap.action_get_events(&"crouch").is_empty(),
			"The project maps an input for crouch")


func _test_toggle_and_shape_isolation() -> void:
	await _start_fixture()
	var second: CharacterBody3D = CONTROLLER.instantiate()
	LOCOMOTION_FIXTURE.install(second)
	second.position = Vector3(4.0, 0.03, 0.0)
	_world.add_child(second)
	second.set_physics_process(false)
	second.get_node("Crouch").set_process(false)
	second.get_node("Look").set_process(false)
	second.get_node("Look").set_process_unhandled_input(false)
	var second_collision: CollisionShape3D = second.get_node("CollisionShape3D")
	var second_capsule := second_collision.shape as CapsuleShape3D
	var standing_height := _capsule.height
	var feet_height := _collision.position.y - standing_height * 0.5
	var eye_height := _look.position.y
	var player_position := _player.position
	_look.rotation.x = deg_to_rad(45.0)
	_look.advance_terrain(_delta, 0.2)
	var camera: Camera3D = _look.get_node("Camera3D")
	var camera_offset := camera.position
	(_player.get_node("AbilitySystem") as AbilitySystem).try_activate(&"crouch")
	_check(_crouch.is_crouching, "First toggle press enters crouch")
	_check_close(_capsule.height, _crouch.settings.crouched_height,
			"Crouching reduces the collision capsule to configured height")
	_check_close(_collision.position.y - _capsule.height * 0.5, feet_height,
			"Capsule resizing preserves its bottom")
	_check(_player.position.is_equal_approx(player_position),
			"Changing stance does not translate the player body")
	_check_close(_look.position.y, eye_height,
			"Starting a crouch transition does not snap the eye height")
	_crouch._process(_crouch.settings.transition_time)
	_check_close(_look.position.y, _crouch.settings.crouched_eye_height,
			"Completed crouch transition reaches the configured eye height")
	_check_close(_look.rotation.x, deg_to_rad(45.0), "Crouching preserves look pitch")
	_check(camera.position.is_equal_approx(camera_offset),
			"Changing stance preserves independent camera stair compensation")
	_check(_capsule != second_capsule
			and is_equal_approx(second_capsule.height, standing_height),
			"One controller's stance cannot resize another controller's capsule")
	await _step(Vector2.ZERO, false, true)
	await _step()
	_check(_crouch.is_crouching, "Holding and releasing crouch leave toggle crouch active")
	await _step(Vector2.ZERO, true, true)
	_check(not _crouch.is_crouching, "Second toggle press stands in open space")
	_check_close(_capsule.height, standing_height, "Standing restores authored capsule height")
	_check_close(_collision.position.y - _capsule.height * 0.5, feet_height,
			"Standing preserves the capsule bottom")
	_crouch._process(_crouch.settings.transition_time)
	_check_close(_look.position.y, eye_height,
			"Completed standing transition restores authored eye height")
	await _end_fixture()


func _test_eye_transitions() -> void:
	await _start_fixture()
	var standing_eye := _look.position.y
	var crouching_eye := _crouch.settings.crouched_eye_height
	var duration := _crouch.settings.transition_time
	_check(duration > 0.0, "Saved crouch settings enable a smooth visual transition")
	_crouch.try_set_crouched(not _crouch.is_crouching)
	_crouch._process(duration * 0.25)
	var first_quarter := _look.position.y
	_crouch._process(duration * 0.25)
	var halfway := _look.position.y
	_check(first_quarter < standing_eye and first_quarter > halfway
			and halfway > crouching_eye,
			"Crouching descends through intermediate eye heights")
	_check(standing_eye - first_quarter < first_quarter - halfway,
			"Crouch descent eases in instead of starting at full speed")
	_crouch._process(duration * 0.5)
	_check_close(_look.position.y, crouching_eye,
			"Crouch transition reaches its target in the configured duration")
	_crouch.try_set_crouched(not _crouch.is_crouching)
	_check_close(_look.position.y, crouching_eye, "Starting to stand does not snap the eyes")
	_crouch._process(duration * 0.5)
	var reversing_height := _look.position.y
	_check(reversing_height > crouching_eye and reversing_height < standing_eye,
			"Standing rises through intermediate eye heights")
	_crouch.try_set_crouched(not _crouch.is_crouching)
	_check_close(_look.position.y, reversing_height,
			"Reversing a transition starts from the displayed height without a jump")
	var reversal_stays_bounded := true
	for frame in 12:
		_crouch._process(duration / 6.0)
		reversal_stays_bounded = reversal_stays_bounded and (
				_look.position.y >= crouching_eye - 0.0001
				and _look.position.y <= reversing_height + 0.0001
		)
	_check(reversal_stays_bounded, "Reversed crouch transition cannot overshoot either endpoint")
	_check_close(_look.position.y, crouching_eye, "Reversed transition settles at the crouched target")
	_crouch.try_set_crouched(not _crouch.is_crouching)
	_crouch._process(duration)
	_check_close(_look.position.y, standing_eye, "Standing transition reaches its exact target")
	_crouch.try_set_crouched(not _crouch.is_crouching)
	_crouch._process(duration * 0.37)
	var single_frame_height := _look.position.y
	_crouch._process(duration)
	_crouch.try_set_crouched(not _crouch.is_crouching)
	_crouch._process(duration)
	_crouch.try_set_crouched(not _crouch.is_crouching)
	_crouch._process(duration * 0.1)
	_crouch._process(duration * 0.27)
	_check_close(_look.position.y, single_frame_height,
			"Equal elapsed render time produces the same height with different frame deltas")
	_crouch.settings.transition_time = 0.0
	_crouch.try_set_crouched(not _crouch.is_crouching)
	_check_close(_look.position.y, standing_eye, "Zero transition duration stands immediately")
	_crouch.try_set_crouched(not _crouch.is_crouching)
	_check_close(_look.position.y, crouching_eye, "Zero transition duration crouches immediately")
	await _end_fixture()


func _test_one_shot() -> void:
	await _start_fixture()
	_crouch.settings.mode = FirstPersonCrouchSettings.Mode.ONE_SHOT
	await _step(Vector2.ZERO, true, true)
	await _step(Vector2.ZERO, false, true)
	_check(_crouch.is_crouching, "One-shot mode remains crouched while C is held")
	await _step()
	_check(not _crouch.is_crouching, "Releasing C stands in one-shot mode when clear")
	await _step(Vector2.ZERO, true, true)
	_add_box(Vector3(0.0, 1.4, 0.0), Vector3(3.0, 0.2, 3.0))
	await _step()
	_check(_crouch.is_crouching, "One-shot release stays crouched under a low ceiling")
	_player.position.x = 4.0
	await _step()
	_check(not _crouch.is_crouching,
			"One-shot mode stands automatically after leaving the obstruction with C released")
	await _end_fixture()


func _test_blocked_toggle() -> void:
	await _start_fixture()
	await _step(Vector2.ZERO, true, true)
	_crouch._process(_crouch.settings.transition_time)
	var crouching_eye := _look.position.y
	_add_box(Vector3(0.0, 1.4, 0.0), Vector3(3.0, 0.2, 3.0))
	await _step()
	_check(not _crouch.can_stand(), "Standing capsule detects a low ceiling")
	await _step(Vector2.ZERO, true, true)
	_check(_crouch.is_crouching, "Toggle cannot expand the body into a low ceiling")
	_crouch._process(_crouch.settings.transition_time)
	_check_close(_look.position.y, crouching_eye,
			"Blocked stand request cannot begin raising the eye height")
	_player.position.x = 4.0
	await _step()
	_check(_crouch.is_crouching,
			"Blocked toggle stand attempt leaves stance crouched after exiting")
	await _step(Vector2.ZERO, true, true)
	_check(not _crouch.is_crouching, "A new toggle press stands once headroom is clear")
	await _end_fixture()


func _test_capsule_clearance_and_filters() -> void:
	await _start_fixture()
	await _step(Vector2.ZERO, true, true)
	var overhang := _add_box(Vector3(0.29, 1.45, 0.0), Vector3(0.18, 0.2, 1.0))
	await _step()
	_check(not _crouch.can_stand(),
			"Full-width clearance detects an off-center overhang that a head ray would miss")
	overhang.collision_layer = 2
	await _step()
	_check(_crouch.can_stand(), "Clearance ignores layers outside the player's collision mask")
	_player.collision_mask = 3
	await _step()
	_check(not _crouch.can_stand(), "Clearance respects newly included collision layers")
	_player.add_collision_exception_with(overhang)
	await _step()
	_check(_crouch.can_stand(), "Clearance respects the player's collision exceptions")
	await _end_fixture()


func _test_airborne_entry() -> void:
	for mode: FirstPersonCrouchSettings.Mode in [
			FirstPersonCrouchSettings.Mode.TOGGLE, FirstPersonCrouchSettings.Mode.ONE_SHOT]:
		await _start_fixture()
		_crouch.settings.mode = mode
		await _step(Vector2.ZERO, true, true, true)
		_check(not _crouch.is_crouching and _player.velocity.y > 0.0,
				"Simultaneous crouch and jump prioritizes the standing jump in mode %d" % mode)
		await _step(Vector2.ZERO, true, true)
		_check(not _crouch.is_crouching,
				"Ascending player cannot enter crouch in mode %d" % mode)
		for tick in 90:
			await _step(Vector2.ZERO, false, true)
			if _player.velocity.y < 0.0:
				break
		await _step(Vector2.ZERO, true, true)
		_check(not _crouch.is_crouching and not _movement.is_grounded(),
				"Descending player cannot enter crouch in mode %d" % mode)
		for tick in 120:
			await _step(Vector2.ZERO, false, true)
			if _movement.is_grounded():
				break
		await _step(Vector2.ZERO, false, true)
		_check(_movement.is_grounded(), "Airborne crouch fixture lands in mode %d" % mode)
		if mode == FirstPersonCrouchSettings.Mode.ONE_SHOT:
			_check(_crouch.is_crouching, "Held One Shot crouch becomes active after landing")
		else:
			_check(not _crouch.is_crouching, "Rejected airborne toggle is not queued for landing")
			await _step(Vector2.ZERO, true, true)
			_check(_crouch.is_crouching, "A fresh grounded toggle enters crouch after landing")
		await _end_fixture()
	await _start_fixture()
	_player.position.y += 6.0
	_check(not _movement.is_grounded(), "Teleporting off a floor invalidates stale grounded state")
	await _step(Vector2.ZERO, true, true)
	_check(not _crouch.is_crouching and _player.velocity.y < 0.0,
			"A falling player cannot crouch using floor contact from before a teleport")
	await _end_fixture()


func _test_crouched_movement() -> void:
	await _start_fixture()
	for tick in 20:
		await _step(Vector2.RIGHT)
	var standing_speed := _movement.get_speed_for_gait(FirstPersonGait.Gait.RUN)
	var crouching_speed := _movement.get_speed_for_gait(FirstPersonGait.Gait.CROUCH)
	_check(crouching_speed > 0.0 and crouching_speed < standing_speed,
			"Movement settings define a slower positive crouch speed")
	await _step(Vector2.RIGHT, true, true)
	_check_close(_horizontal_speed(), move_toward(standing_speed, crouching_speed,
			_movement.settings.ground_acceleration * _delta),
			"Entering crouch slows existing movement through ground acceleration")
	for tick in 25:
		await _step(Vector2.RIGHT)
	_check_close(_horizontal_speed(), crouching_speed, "Crouched movement reaches its reduced speed")
	for tick in 25:
		await _step(Vector2(1.0, -1.0))
	_check_close(_horizontal_speed(), crouching_speed, "Crouched diagonal motion obeys the speed limit")
	await _step()
	_check_close(_horizontal_speed(), maxf(0.0,
			crouching_speed - _movement.settings.ground_deceleration * _delta),
			"Crouched movement preserves configured ground braking")
	for tick in 25:
		await _step(Vector2.RIGHT)
	await _step(Vector2.RIGHT, true, true)
	_check_close(_horizontal_speed(), minf(standing_speed,
			crouching_speed + _movement.settings.ground_acceleration * _delta),
			"Standing restores speed through existing ground acceleration")
	for tick in 25:
		await _step(Vector2.RIGHT)
	_check_close(_horizontal_speed(), standing_speed, "Standing restores the normal maximum speed")
	await _end_fixture()


func _test_crouched_jump() -> void:
	await _start_fixture()
	await _step(Vector2.ZERO, true, true)
	var takeoff_height := _player.position.y
	var crouched_jump_height := _movement.settings.crouch_jump_height
	var crouched_launch := sqrt(2.0 * _movement.settings.gravity * crouched_jump_height)
	await _step(Vector2.ZERO, false, false, true)
	_check(_crouch.is_crouching and _player.velocity.y > 0.0, "A grounded crouched player can jump")
	_check_close(_player.velocity.y, crouched_launch,
			"Crouch jump height determines launch speed through the gravity formula")
	await _step(Vector2.ZERO, false, false, true)
	_check_close(_player.velocity.y, crouched_launch - _movement.settings.gravity * _delta,
			"Crouched jumping cannot trigger a second jump in the air")
	await _step(Vector2.ZERO, true, true)
	_check(not _crouch.is_crouching and not _movement.is_grounded(),
			"An already crouched player may stand while airborne when headroom is clear")
	var crouched_apex := _player.position.y
	for tick in 120:
		await _step()
		crouched_apex = maxf(crouched_apex, _player.position.y)
		if _movement.is_grounded():
			break
	_check(absf(crouched_apex - takeoff_height - crouched_jump_height) < 0.12,
			"Crouched takeoff reaches the reduced apex within fixed-tick integration tolerance")
	await _step(Vector2.ZERO, false, false, true)
	var standing_launch := sqrt(2.0 * _movement.settings.gravity * _movement.settings.jump_height)
	_check_close(_player.velocity.y, standing_launch, "Standing restores the normal jump launch speed")
	var standing_apex := _player.position.y
	for tick in 120:
		await _step()
		standing_apex = maxf(standing_apex, _player.position.y)
		if _movement.is_grounded():
			break
	_check(standing_apex > crouched_apex + 0.1, "Standing jump has a higher physical apex than crouched jump")
	await _end_fixture()


func _test_crouched_coyote_jump() -> void:
	await _start_fixture()
	_add_box(Vector3(0.0, 4.5, 0.0), Vector3(3.0, 1.0, 6.0))
	_player.position = Vector3(0.0, 5.03, 0.0)
	for tick in 10:
		await _step()
	await _step(Vector2.ZERO, true, true)
	for tick in 120:
		await _step(Vector2.RIGHT)
		if not _movement.is_grounded():
			break
	_check(not _movement.is_grounded() and _crouch.is_crouching,
			"Coyote fixture walks off a ledge while already crouched")
	await _step(Vector2.RIGHT, false, false, true)
	var expected_launch := sqrt(2.0 * _movement.settings.gravity * _movement.settings.crouch_jump_height)
	_check_close(_player.velocity.y, expected_launch, "Crouched coyote jump retains the reduced jump height")
	await _end_fixture()


func _test_crouch_on_stairs() -> void:
	await _start_fixture(Vector3(0.0, 0.03, 1.0))
	for index in 6:
		var height := (index + 1) * 0.25
		_add_box(Vector3(0.0, height * 0.5, -(index + 0.5) * 0.6),
				Vector3(3.0, height, 0.6))
	var crouched_on_step := false
	for tick in 120:
		await _step(Vector2.UP)
		if _player.position.y > 0.15 and _movement.is_grounded():
			await _step(Vector2.UP, true, true)
			crouched_on_step = _crouch.is_crouching
			break
	_check(crouched_on_step, "Supported stair traversal permits entering crouch")
	for tick in 120:
		await _step(Vector2.UP)
		if _player.position.y > 1.47:
			break
	_check(_player.position.y > 1.47, "Reduced crouch speed still climbs the stairs")
	await _end_fixture()


func _test_tunnel_traversal() -> void:
	for lane_x: float in [0.0, 5.0]:
		await _start_fixture(Vector3(lane_x, 0.03, 4.5))
		_add_tunnel(lane_x, 1.25 if lane_x == 0.0 else 1.45)
		for tick in 35:
			await _step(Vector2.UP)
		_check(_player.position.z > 2.8,
				"Standing player cannot enter fixture tunnel at x=%.0f" % lane_x)
		await _step(Vector2.UP, true, true)
		for tick in 45:
			await _step(Vector2.UP)
			if _player.position.z < 1.0:
				break
		_check(_player.position.z < 2.0 and _player.position.z > -2.0,
				"Crouched player enters fixture tunnel at x=%.0f" % lane_x)
		await _step(Vector2.UP, true, true)
		_check(_crouch.is_crouching,
				"Fixture tunnel blocks an uncrouch attempt at x=%.0f" % lane_x)
		for tick in 180:
			await _step(Vector2.UP)
			if _player.position.z < -3.6:
				break
		_check(_player.position.z < -3.5,
				"Crouched player traverses the complete fixture tunnel at x=%.0f" % lane_x)
		await _step(Vector2.ZERO, true, true)
		_check(not _crouch.is_crouching,
				"Player can stand after exiting fixture tunnel at x=%.0f" % lane_x)
		await _end_fixture()


func _test_tunnel_transition_clearance() -> void:
	await _start_fixture(Vector3(0.0, 0.03, 4.5))
	_add_tunnel(0.0, 1.25)
	_crouch.settings.transition_time = 1.0
	for tick in 35:
		await _step(Vector2.UP)
	await _step(Vector2.UP, true, true)
	var entered := false
	var eye_stays_clear := true
	var enters_before_transition_finishes := false
	var elapsed := _delta
	for tick in 25:
		await _step(Vector2.UP)
		elapsed += _delta
		if _player.position.z < 2.95 and _player.position.z > -2.95:
			entered = true
			eye_stays_clear = eye_stays_clear and _look.global_position.y < 1.25
			enters_before_transition_finishes = enters_before_transition_finishes or (
					elapsed < _crouch.settings.transition_time
			)
	_check(entered, "Slow crouch transition fixture enters the low tunnel")
	_check(enters_before_transition_finishes,
			"Tunnel clearance is exercised while the eye transition is still in progress")
	_check(eye_stays_clear, "Animated eye height stays below the tunnel roof during entry")
	await _end_fixture()


func _start_fixture(spawn: Vector3 = Vector3(0.0, 0.03, 0.0)) -> void:
	_world = Node3D.new()
	root.add_child(_world)
	_add_box(Vector3(0.0, -0.5, 0.0), Vector3(100.0, 1.0, 100.0))
	_player = CONTROLLER.instantiate()
	LOCOMOTION_FIXTURE.install(_player)
	_player.position = spawn
	_world.add_child(_player)
	_player.set_physics_process(false)
	_movement = _player.get_node("Movement")
	_crouch = _player.get_node("Crouch")
	_crouch.set_process(false)
	_look = _player.get_node("Look")
	_look.set_process(false)
	_look.set_process_unhandled_input(false)
	_collision = _player.get_node("CollisionShape3D")
	_capsule = _collision.shape as CapsuleShape3D
	for tick in 10:
		await _step()


func _end_fixture() -> void:
	_world.queue_free()
	await process_frame
	_world = null
	_player = null


func _step(direction: Vector2 = Vector2.ZERO, pressed: bool = false, held: bool = false,
		jump_requested: bool = false) -> void:
	await physics_frame
	(_player as FirstPersonController).advance_locomotion(
			_delta, direction, jump_requested, pressed, held
	)
	_crouch._process(_delta)
	_look._process(_delta)


func _add_tunnel(x: float, clearance: float) -> void:
	_add_box(Vector3(x, clearance + 0.15, 0.0), Vector3(2.6, 0.3, 6.0))
	for side: float in [-1.0, 1.0]:
		_add_box(Vector3(x + side * 1.15, clearance * 0.5, 0.0),
				Vector3(0.3, clearance, 6.0))


func _add_box(center: Vector3, size: Vector3) -> StaticBody3D:
	var obstacle := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	obstacle.position = center
	obstacle.add_child(collision)
	_world.add_child(obstacle)
	return obstacle


func _check_close(actual: float, expected: float, description: String) -> void:
	_check(absf(actual - expected) < 0.001,
			"%s (actual %.4f, expected %.4f)" % [description, actual, expected])


func _horizontal_speed() -> float:
	return Vector2(_player.velocity.x, _player.velocity.z).length()


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(description)
