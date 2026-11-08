extends SceneTree
## Headless behavioral checks using the saved controller and temporary collision fixtures.
## Run with: godot --headless --path . --script res://tests/first_person_controller_test.gd

const CONTROLLER = preload("res://player/player.tscn")
const LOCOMOTION_FIXTURE = preload("res://tests/locomotion_fixture.gd")

var _world: Node3D
var _player: CharacterBody3D
var _movement: FirstPersonMovement
var _failures: int = 0
var _checks: int = 0
var _delta: float = 1.0 / Engine.physics_ticks_per_second


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://tests/combat_rules_fixture.gd").install()
	_test_settings_inspector()
	_world = Node3D.new()
	root.add_child(_world)
	_add_floor(Vector3(0.0, -0.5, 0.0), Vector3(100.0, 1.0, 100.0))
	_add_floor(Vector3(200.0, 4.5, 0.0), Vector3(3.0, 1.0, 6.0))
	await _test_ground_movement()
	await _test_look()
	await _test_air_movement_and_gravity()
	await _test_jump_and_landing()
	await _test_coyote_jump()
	print("Controller checks: %d passed, %d failed." % [_checks - _failures, _failures])
	_world.queue_free()
	await process_frame
	quit(0 if _failures == 0 else 1)


func _test_settings_inspector() -> void:
	var look := FirstPersonLookSettings.new()
	look.full_tilt_speed = 7.0
	look.maximum_tilt = 0.0
	_check(_property_usage(look, &"full_tilt_speed") & PROPERTY_USAGE_EDITOR == 0,
			"Zero maximum tilt hides Full Tilt Speed")
	_check(_property_usage(look, &"tilt_response") & PROPERTY_USAGE_EDITOR != 0,
			"Tilt Response remains available to settle existing camera roll")
	var restored := look.duplicate() as FirstPersonLookSettings
	restored.maximum_tilt = 3.0
	_check(_property_usage(restored, &"full_tilt_speed") & PROPERTY_USAGE_EDITOR != 0,
			"Positive maximum tilt reveals Full Tilt Speed")
	_check_close(restored.full_tilt_speed, 7.0, "Duplicating a setting retains hidden tilt speed")

	var movement := FirstPersonMovementSettings.new()
	var gait_fields := [&"walk_speed_multiplier", &"sprint_speed_multiplier", &"crouch_speed_multiplier"]
	for field: StringName in gait_fields:
		movement.set(field, 0.75)
	movement.normal_run_speed = 0.0
	var copy := movement.duplicate() as FirstPersonMovementSettings
	copy.normal_run_speed = 4.0
	for field: StringName in gait_fields:
		_check(_property_usage(movement, field) & PROPERTY_USAGE_EDITOR == 0,
				"Zero baseline hides %s" % field)
		_check(_property_usage(copy, field) & PROPERTY_USAGE_EDITOR != 0,
				"Positive baseline reveals %s" % field)
		_check_close(float(copy.get(field)), 0.75, "Duplicating a setting retains hidden %s" % field)


func _property_usage(object: Object, name: StringName) -> int:
	for property: Dictionary in object.get_property_list():
		if property.name == name:
			return int(property.usage)
	return 0


func _test_ground_movement() -> void:
	await _spawn(Vector3(0.0, 0.03, 0.0))
	await _settle()
	_check(_player.is_on_floor(), "Controller settles onto a collidable floor")
	await _step(Vector2.RIGHT)
	_check_close(_horizontal_speed(), _movement.settings.ground_acceleration * _delta,
			"Ground acceleration changes speed gradually")
	for tick in 20:
		await _step(Vector2.RIGHT)
	_check_close(_horizontal_speed(), _movement.get_speed_for_gait(FirstPersonGait.Gait.RUN), "Ground speed is capped")
	await _step()
	_check_close(_horizontal_speed(),
			_movement.get_speed_for_gait(FirstPersonGait.Gait.RUN) - _movement.settings.ground_deceleration * _delta,
			"Ground braking uses the ground deceleration")
	for tick in 20:
		await _step(Vector2(1.0, -1.0))
	_check_close(_horizontal_speed(), _movement.get_speed_for_gait(FirstPersonGait.Gait.RUN),
			"Diagonal movement cannot exceed speed")
	_player.rotation.y = PI / 2.0
	for tick in 30:
		await _step(Vector2.UP)
	_check(absf(_player.velocity.x + _movement.get_speed_for_gait(FirstPersonGait.Gait.RUN)) < 0.01
			and absf(_player.velocity.z) < 0.01,
			"Forward movement follows body yaw")


func _test_air_movement_and_gravity() -> void:
	await _spawn(Vector3(0.0, 10.0, 0.0))
	_movement.settings.gravity = 10.0
	var original_gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	ProjectSettings.set_setting("physics/3d/default_gravity", 1000.0)
	await _step(Vector2.RIGHT)
	_check_close(_horizontal_speed(), _movement.settings.air_acceleration * _delta,
			"Air acceleration changes horizontal speed gradually")
	_check_close(_player.velocity.y, -10.0 * _delta,
			"Exported gravity works independently of project gravity")
	var previous_speed := _horizontal_speed()
	await _step()
	_check_close(_horizontal_speed(), previous_speed - _movement.settings.air_deceleration * _delta,
			"Air braking uses the air deceleration")
	ProjectSettings.set_setting("physics/3d/default_gravity", original_gravity)


func _test_look() -> void:
	await _spawn(Vector3(0.0, 0.03, 0.0))
	await _settle()
	var look: FirstPersonLook = _player.get_node("Look")
	var camera: Camera3D = look.get_node("Camera3D")
	if DisplayServer.get_name() == "headless":
		print("Mouse capture/look checks skipped: headless display does not support mouse capture.")
	else:
		_test_mouse_look(look)
	_player.rotation.y = 0.0
	look.rotation.x = 0.0
	for tick in 20:
		await _step(Vector2.RIGHT)
		look._process(_delta)
	_check(camera.rotation.z < 0.0
			and absf(camera.rotation.z) <= deg_to_rad(look.settings.maximum_tilt),
			"Right strafe tilts the camera right without exceeding maximum roll")
	for tick in 60:
		await _step()
		look._process(_delta)
	_check(absf(camera.rotation.z) < 0.001, "Camera roll returns to level after lateral motion stops")
	for tick in 20:
		await _step(Vector2.LEFT)
		look._process(_delta)
	_check(camera.rotation.z > 0.0, "Left strafe tilts the camera in the opposite direction")


func _test_mouse_look(look: FirstPersonLook) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "Mouse can be captured for aiming")
	var motion := InputEventMouseMotion.new()
	motion.screen_relative = Vector2(100.0, -50.0)
	motion.relative = Vector2(1.0, 1.0)
	look._unhandled_input(motion)
	_check_close(_player.rotation.y, -deg_to_rad(100.0 * look.settings.mouse_sensitivity),
			"Mouse yaw uses unscaled screen-relative motion")
	_check_close(look.rotation.x, deg_to_rad(50.0 * look.settings.mouse_sensitivity),
			"Mouse pitch uses unscaled screen-relative motion")
	motion.screen_relative = Vector2(0.0, -100000.0)
	look._unhandled_input(motion)
	_check_close(look.rotation.x, deg_to_rad(look.settings.pitch_limit),
			"Upward mouse pitch stops at the configured limit")
	motion.screen_relative.y = 100000.0
	look._unhandled_input(motion)
	_check_close(look.rotation.x, -deg_to_rad(look.settings.pitch_limit),
			"Downward mouse pitch stops at the configured limit")
	var release_event := InputEventAction.new()
	release_event.action = &"release_mouse"
	release_event.pressed = true
	look._unhandled_input(release_event)
	var previous_yaw := _player.rotation.y
	var previous_pitch := look.rotation.x
	motion.screen_relative = Vector2(100.0, -100.0)
	look._unhandled_input(motion)
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE
			and is_equal_approx(_player.rotation.y, previous_yaw)
			and is_equal_approx(look.rotation.x, previous_pitch),
			"Released mouse remains visible and mouse motion no longer rotates the view")
	var capture_event := InputEventAction.new()
	capture_event.action = &"capture_mouse"
	capture_event.pressed = true
	look._unhandled_input(capture_event)
	_check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "Capture action restores mouse aiming")


func _test_jump_and_landing() -> void:
	await _spawn(Vector3(0.0, 0.03, 0.0))
	await _settle()
	var starting_height := _player.position.y
	await _step(Vector2.ZERO, true)
	var launch_speed := sqrt(2.0 * _movement.settings.gravity * _movement.settings.jump_height)
	_check_close(_player.velocity.y, launch_speed, "Jump launch speed uses custom gravity and height")
	await _step(Vector2.ZERO, true)
	_check_close(_player.velocity.y, launch_speed - _movement.settings.gravity * _delta,
			"A second press cannot jump again in midair")
	var apex := _player.position.y
	for tick in 90:
		await _step()
		apex = maxf(apex, _player.position.y)
	_check(absf(apex - starting_height - _movement.settings.jump_height) < 0.12,
			"Jump reaches the configured height within fixed-tick integration tolerance")
	_check(_player.is_on_floor(), "Character lands after jumping")
	await _step(Vector2.ZERO, true)
	_check_close(_player.velocity.y, launch_speed, "Landing restores the ability to jump")


func _test_coyote_jump() -> void:
	await _spawn(Vector3(200.0, 5.03, 0.0))
	await _settle()
	await _walk_off_platform()
	await _step(Vector2.RIGHT)
	await _step(Vector2.RIGHT, true)
	_check(_player.velocity.y > 0.0, "Coyote jump succeeds shortly after leaving an edge")
	await _step(Vector2.RIGHT, true)
	var launch_speed := sqrt(2.0 * _movement.settings.gravity * _movement.settings.jump_height)
	_check(_player.velocity.y < launch_speed,
			"Coyote time is consumed by the first jump")

	await _spawn(Vector3(200.0, 5.03, 0.0))
	await _settle()
	await _walk_off_platform()
	for tick in ceili(_movement.settings.coyote_time / _delta) + 2:
		await _step(Vector2.RIGHT)
	await _step(Vector2.RIGHT, true)
	_check(_player.velocity.y < 0.0, "Jump is rejected after the coyote window expires")

	await _spawn(Vector3(0.0, 0.03, 0.0))
	_movement.settings.coyote_time = 0.0
	await _settle()
	await _step(Vector2.ZERO, true)
	_check(_player.velocity.y > 0.0, "Zero coyote time still allows jumping directly from the floor")


func _spawn(position: Vector3) -> void:
	if is_instance_valid(_player):
		_player.queue_free()
		await process_frame
	_player = CONTROLLER.instantiate()
	LOCOMOTION_FIXTURE.install(_player)
	_player.position = position
	_world.add_child(_player)
	_player.set_physics_process(false)
	_player.get_node("Look").set_process(false)
	_player.get_node("Look").set_process_unhandled_input(false)
	_movement = _player.get_node("Movement")
	await physics_frame


func _settle() -> void:
	for tick in 8:
		await _step()


func _step(direction: Vector2 = Vector2.ZERO, jump_requested: bool = false) -> void:
	await physics_frame
	(_player as Player).advance_locomotion(_delta, direction, jump_requested)


func _walk_off_platform() -> void:
	for tick in 60:
		await _step(Vector2.RIGHT)
		if not _player.is_on_floor():
			return
	_check(false, "Fixture allows the player to walk off its edge")


func _add_floor(position: Vector3, size: Vector3) -> void:
	var floor_body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	floor_body.position = position
	floor_body.add_child(collision)
	_world.add_child(floor_body)


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
