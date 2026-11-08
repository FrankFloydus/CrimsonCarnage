extends SceneTree
## Headless Jolt regression checks for the saved controller and test-owned stair geometry.
## Run: godot --headless --path . --fixed-fps 60 --script res://tests/stair_traversal_test.gd

const CONTROLLER = preload("res://player/player.tscn")
const LOCOMOTION_FIXTURE = preload("res://tests/locomotion_fixture.gd")

var _world: Node3D
var _player: CharacterBody3D
var _movement: FirstPersonMovement
var _look: FirstPersonLook
var _camera: Camera3D
var _checks: int = 0
var _failures: int = 0
var _delta: float = 1.0 / Engine.physics_ticks_per_second


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	await _test_stair_flights()
	await _test_approaches()
	await _test_slow_oblique_approach()
	await _test_fast_compact_stairs()
	await _test_rejected_steps()
	await _test_parallel_motion()
	await _test_jump_on_stairs()
	await _test_camera_smoothing()
	await _test_camera_pitch_and_clearance()
	await _test_ramp_and_jump_smoothing()
	await _test_teleport_reset()
	print("Stair checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_stair_flights() -> void:
	for tall: bool in [false, true]:
		await _start_fixture(Vector3(0.0, 0.03, 1.0))
		var count := 32 if tall else 6
		_add_stairs(count, 0.25, 0.6, 3.0, 0.0)
		if tall:
			_add_box(Vector3(0.0, 7.75, -27.2), Vector3(3.0, 0.5, 16.0))
		await _settle()
		var top := count * 0.25
		var reached_top := false
		for tick in 300 if tall else 90:
			await _step(Vector2.UP)
			if _player.position.y > top - 0.03:
				reached_top = true
				break
		_check(reached_top, "%s stair flight can be climbed without jumping" % (
				"Tall" if tall else "Low"))
		if tall:
			for tick in 15:
				await _step(Vector2.UP)
			await _settle()
		var reached_ground := false
		for tick in 310 if tall else 100:
			await _step(Vector2.DOWN)
			if _player.position.z > 0.5 and _player.position.y < 0.03:
				reached_ground = true
				break
		_check(reached_ground, "%s stair flight descend to ground without jumping" % (
				"Tall" if tall else "Low"))
		await _end_fixture()


func _test_approaches() -> void:
	for angle: float in [0.0, 45.0, -60.0, 85.0]:
		await _start_fixture()
		_add_stairs(4, 0.25, 0.6, 100.0)
		_player.rotation.y = PI / 2.0
		await _settle()
		var radians := deg_to_rad(angle)
		var direction := Vector3(sin(radians), 0.0, -cos(radians))
		var axis := _axis_for_world_direction(direction)
		var reached_top := false
		for tick in 650:
			await _step(axis)
			if _player.position.y > 0.97:
				reached_top = true
				break
		_check(reached_top, "Stairs climb at %.0f degrees while looking sideways" % angle)
		_check(absf(_player.rotation.y - PI / 2.0) < 0.0001,
				"Stair traversal preserves the view heading at %.0f degrees" % angle)
		await _end_fixture()


func _test_slow_oblique_approach() -> void:
	await _start_fixture(Vector3(0.0, 0.03, -1.1))
	_add_stairs(2, 0.25, 0.375, 30.0)
	_movement.attributes.set_base_value(CombatAttributes.Id.MOVEMENT_SPEED, -87.5)
	_check(absf(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN) - 0.5) < 0.001,
			"The slow stair fixture's negative speed bonus produces 0.5 m/s")
	await _settle()
	var radians := deg_to_rad(85.0)
	var axis := Vector2(sin(radians), -cos(radians))
	var reached_top := false
	for tick in 1600:
		await _step(axis)
		if _player.position.y > 0.47:
			reached_top = true
			break
	_check(reached_top, "Slow 0.5 m/s movement climbs nearly parallel to the riser")
	await _end_fixture()


func _test_rejected_steps() -> void:
	for rejection: String in ["high_riser", "low_ceiling", "disabled"]:
		await _start_fixture()
		_add_stairs(4, 0.45 if rejection == "high_riser" else 0.25)
		if rejection == "low_ceiling":
			# Underside at 1.9 m cannot fit the 1.8 m body above a 0.25 m tread.
			_add_box(Vector3(0.0, 2.0, -3.0), Vector3(16.0, 0.2, 4.0))
		elif rejection == "disabled":
			_movement.settings.max_step_height = 0.0
		await _settle()
		var initial_y := _player.position.y
		for tick in 100:
			await _step(Vector2.UP)
		_check(_player.position.z > -1.5 and _player.position.y < initial_y + 0.15,
				"Step is rejected for %s" % rejection)
		await _end_fixture()


func _test_fast_compact_stairs() -> void:
	await _start_fixture()
	_add_stairs(16, 0.25, 0.375)
	_movement.settings.normal_run_speed = 8.0
	_movement.attributes.set_base_value(CombatAttributes.Id.MOVEMENT_SPEED, 0.0)
	_check(absf(_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN) - 8.0) < 0.001,
			"The fast stair fixture authors an 8 m/s baseline without exceeding the bonus cap")
	_look.settings.stair_smoothing_time = 0.2
	await _settle()
	var reached_top := false
	var largest_camera_lag := 0.0
	for tick in 120:
		await _step(Vector2.UP)
		largest_camera_lag = maxf(largest_camera_lag, -_camera.position.y)
		if _player.position.y > 3.95:
			reached_top = true
			break
	_check(reached_top, "Fast 8 m/s motion climbs sixteen compact treads")
	_check(largest_camera_lag > 0.55,
			"Fast compact stairs preserve accumulated camera compensation")
	await _end_fixture()


func _test_parallel_motion() -> void:
	await _start_fixture(Vector3(0.0, 0.03, -1.1))
	_add_stairs()
	await _settle()
	var start := _player.position
	for tick in 70:
		await _step(Vector2.RIGHT)
	_check(_player.position.x > start.x + 4.0
			and absf(_player.position.z - start.z) < 0.01
			and absf(_player.position.y - start.y) < 0.01,
			"Motion parallel to a riser neither climbs nor steers into it")
	await _end_fixture()


func _test_jump_on_stairs() -> void:
	await _start_fixture()
	_add_stairs()
	await _settle()
	var climbed := false
	for tick in 90:
		await _step(Vector2.UP)
		if _player.position.y > 0.2:
			climbed = true
			break
	_check(climbed, "Jump fixture reaches a stair tread")
	var height_before_jump := _player.position.y
	await _step(Vector2.UP, true)
	var launch_speed := sqrt(2.0 * _movement.settings.gravity * _movement.settings.jump_height)
	_check(absf(_player.velocity.y - launch_speed) < 0.001
			and _player.position.y > height_before_jump,
			"Jump remains available immediately after a stair lift")
	await _step(Vector2.UP, true)
	_check(_player.velocity.y < launch_speed,
			"Stair support grace does not allow a second airborne jump")
	await _end_fixture()


func _test_camera_smoothing() -> void:
	await _start_fixture()
	_add_stairs(6, 0.25, 0.6)
	await _settle()
	var previous_body_y := _player.position.y
	var previous_eye_y := _camera.global_position.y
	var largest_body_rise := 0.0
	var largest_eye_rise := 0.0
	var largest_offset := 0.0
	var reached_top := false
	for tick in 120:
		await _step(Vector2.UP)
		largest_body_rise = maxf(largest_body_rise, _player.position.y - previous_body_y)
		largest_eye_rise = maxf(largest_eye_rise, _camera.global_position.y - previous_eye_y)
		largest_offset = maxf(largest_offset, absf(_camera.position.y))
		previous_body_y = _player.position.y
		previous_eye_y = _camera.global_position.y
		if _player.position.y > 1.47:
			reached_top = true
			break
	_check(reached_top, "Camera smoothing fixture reaches the final tread")
	_check(largest_body_rise > 0.03 and largest_eye_rise < largest_body_rise * 0.85,
			"Camera compensation reduces abrupt stair elevation changes")
	_check(largest_offset > 0.01, "Saved scene connects movement to camera stair smoothing")
	for tick in 90:
		await _step()
	_check(_camera.position.length() < 0.0001,
			"Camera stair compensation settles back to its authored position")
	_look.advance_terrain(_delta, 0.25)
	_look._process(0.0)
	_check(_camera.position.y < -0.2, "A terrain rise produces downward camera compensation")
	_look.settings.stair_smoothing_time = 0.0
	_look._process(0.0)
	_check(_camera.position.length() < 0.0001,
			"Zero smoothing clears pending compensation without another movement tick")
	await _end_fixture()


func _test_ramp_and_jump_smoothing() -> void:
	await _start_fixture(Vector3(2.5, 1.4, 0.0))
	_add_box(Vector3(3.5, 0.64, 0.0), Vector3(5.2, 0.4, 12.0),
			Vector3(0.0, 0.0, deg_to_rad(15.0)))
	await _settle(40)
	var initial_y := _player.position.y
	var largest_offset := 0.0
	for tick in 25:
		await _step(Vector2.RIGHT)
		largest_offset = maxf(largest_offset, _camera.position.length())
	_check(_player.position.y > initial_y + 0.1, "Ramp fixture moves up a sloping support plane")
	_check(largest_offset < 0.01, "Continuous ramp travel bypasses stair smoothing")
	await _end_fixture()

	await _start_fixture()
	await _settle()
	await _step(Vector2.ZERO, true)
	largest_offset = _camera.position.length()
	for tick in 100:
		await _step()
		largest_offset = maxf(largest_offset, _camera.position.length())
	_check(_player.is_on_floor(), "Jump smoothing fixture lands again")
	_check(largest_offset < 0.01, "Jumping, falling, and landing bypass stair smoothing")
	await _end_fixture()


func _test_camera_pitch_and_clearance() -> void:
	await _start_fixture()
	await _settle()
	_look.rotation.x = deg_to_rad(60.0)
	var eye := _look.global_position
	_look.advance_terrain(_delta, 0.25)
	_look._process(0.0)
	var displacement := _camera.global_position - eye
	_check(absf(displacement.x) < 0.0001 and absf(displacement.z) < 0.0001
			and displacement.y < -0.2,
			"Stair camera translation follows world up while looking steeply upwards")
	_look.clear_stair_smoothing()
	_look.rotation.x = 0.0
	eye = _look.global_position
	_add_box(eye - Vector3.UP * 0.4, Vector3(1.6, 0.1, 1.6))
	await physics_frame
	_look.advance_terrain(_delta, 1.0)
	_look._process(0.0)
	_check(_camera.global_position.y >= eye.y - 0.301
			and _camera.global_position.y < eye.y - 0.2,
			"World collision limits camera compensation before its near clip reaches geometry")
	await _end_fixture()


func _test_teleport_reset() -> void:
	await _start_fixture()
	await _settle()
	_look.advance_terrain(_delta, 0.25)
	_check(_camera.position.y < -0.2, "Teleport fixture has pending stair compensation")
	_player.position += Vector3.UP * 5.0
	await _step(Vector2.ZERO, true)
	_check(_player.velocity.y < 0.0,
			"Teleporting a grounded player into the air cannot reuse stale floor contact to jump")
	_check(_camera.position.length() < 0.0001,
			"External teleport clears pending camera stair compensation")
	await _end_fixture()


func _start_fixture(spawn: Vector3 = Vector3(0.0, 0.03, 0.0)) -> void:
	_world = Node3D.new()
	root.add_child(_world)
	_add_box(Vector3(0.0, -0.5, 0.0), Vector3(200.0, 1.0, 200.0))
	_player = CONTROLLER.instantiate()
	LOCOMOTION_FIXTURE.install(_player)
	_player.position = spawn
	_world.add_child(_player)
	_player.set_physics_process(false)
	_movement = _player.get_node("Movement")
	_look = _player.get_node("Look")
	_look.set_process(false)
	_look.set_process_unhandled_input(false)
	_camera = _look.get_node("Camera3D")
	await physics_frame


func _end_fixture() -> void:
	_world.queue_free()
	await process_frame
	_world = null
	_player = null


func _step(direction: Vector2 = Vector2.ZERO, jump_requested: bool = false) -> void:
	await physics_frame
	(_player as Player).advance_locomotion(_delta, direction, jump_requested)
	_look._process(_delta)


func _settle(ticks: int = 10) -> void:
	for tick in ticks:
		await _step()


func _axis_for_world_direction(direction: Vector3) -> Vector2:
	var local := _player.global_basis.inverse() * direction
	return Vector2(local.x, local.z).normalized()


func _add_stairs(count: int = 6, rise: float = 0.25, tread: float = 0.6,
		width: float = 24.0, start_z: float = -1.5) -> void:
	for index in count:
		var height := (index + 1) * rise
		_add_box(Vector3(0.0, height * 0.5, start_z - (index + 0.5) * tread),
				Vector3(width, height, tread))


func _add_box(center: Vector3, size: Vector3, rotation: Vector3 = Vector3.ZERO) -> void:
	var obstacle := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	obstacle.position = center
	obstacle.rotation = rotation
	obstacle.add_child(collision)
	_world.add_child(obstacle)


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("%s; position=%s, velocity=%s" % [
				description, _player.position, _player.velocity])
