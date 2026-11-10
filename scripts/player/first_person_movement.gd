class_name FirstPersonMovement
extends Node
## Accelerates a character, applies custom gravity, and resolves jumping and collisions.

## Advances camera compensation after a physics tick, with only supported terrain height changes.
signal terrain_advanced(delta: float, height_change: float)
## Clears terrain presentation when an external position change invalidates stair contacts.
signal terrain_reset

## Character whose velocity and collision movement this component owns.
@export var body: CharacterBody3D
## Gait, jump, acceleration, gravity and terrain settings.
@export var settings: FirstPersonMovementSettings

## Gait used by the last movement step.
var effective_gait: FirstPersonGait.Gait:
	get:
		return _effective_gait

var _effective_gait: FirstPersonGait.Gait = FirstPersonGait.Gait.RUN
var _moving: bool = false
var _coyote_time_remaining: float = 0.0
var _stair_stepper := FirstPersonStairStepper.new()
var _stepped_last_tick: bool = false
var _last_position: Vector3
var _has_last_position: bool = false
var _airborne_sprint_takeoff_speed: float = 0.0


## Advances locomotion once per physics tick. Input uses X for strafe and negative Y for forward.
## A jump press requires current floor or coyote support and a non-sprint gait.
func move(
		delta: float,
		movement_input: Vector2,
		gait: FirstPersonGait.Gait = FirstPersonGait.Gait.RUN,
		jump_pressed: bool = false
) -> void:
	if _moving or not is_finite(delta) or delta <= 0.0 or not is_instance_valid(body) \
			or settings == null or not body.is_inside_tree():
		return
	_moving = true
	if gait == FirstPersonGait.Gait.SPRINT and get_speed_for_gait(gait) <= 0.0:
		gait = FirstPersonGait.Gait.RUN
	_advance_movement(delta, movement_input, gait, jump_pressed)
	_moving = false


## Includes one-tick stair support, but never reuses floor contacts after an external move.
func is_grounded() -> bool:
	if not is_instance_valid(body):
		return false
	if _has_last_position and not body.global_position.is_equal_approx(_last_position):
		return false
	return body.is_on_floor() or _stepped_last_tick


## Returns the authored normal speed with the selected gait multiplier, in meters per second.
func get_speed_for_gait(gait: FirstPersonGait.Gait) -> float:
	if settings == null:
		return 0.0
	var base_speed := settings.normal_run_speed
	if not is_finite(base_speed) or base_speed < 0.0:
		return 0.0
	var multiplier := 1.0
	match gait:
		FirstPersonGait.Gait.WALK:
			multiplier = settings.walk_speed_multiplier
		FirstPersonGait.Gait.SPRINT:
			multiplier = settings.sprint_speed_multiplier
		FirstPersonGait.Gait.CROUCH:
			multiplier = settings.crouch_speed_multiplier
		FirstPersonGait.Gait.CROUCH_WALK:
			multiplier = settings.crouch_speed_multiplier * settings.walk_speed_multiplier
	var result := base_speed * multiplier
	return result if is_finite(result) and result >= 0.0 else 0.0


func _advance_movement(
		delta: float,
		movement_input: Vector2,
		gait: FirstPersonGait.Gait,
		jump_pressed: bool
) -> void:
	if not is_finite(movement_input.x) or not is_finite(movement_input.y):
		movement_input = Vector2.ZERO
	_effective_gait = gait
	var position_changed := (
			_has_last_position and not body.global_position.is_equal_approx(_last_position)
	)
	if position_changed:
		_stair_stepper.reset()
		_stepped_last_tick = false
		_coyote_time_remaining = 0.0
		_airborne_sprint_takeoff_speed = 0.0
		terrain_reset.emit()
	body.floor_max_angle = deg_to_rad(settings.max_slope_angle)
	body.floor_snap_length = maxf(0.05, settings.max_step_height)
	var grounded := is_grounded()
	var support_before := _support_plane()
	var start_position := body.global_position
	if grounded:
		_coyote_time_remaining = settings.coyote_time
	else:
		_coyote_time_remaining = maxf(_coyote_time_remaining - delta, 0.0)

	var direction := body.global_basis * Vector3(movement_input.x, 0.0, movement_input.y)
	direction.y = 0.0
	direction = direction.limit_length(1.0)
	var horizontal_velocity := Vector3(body.velocity.x, 0.0, body.velocity.z)
	var acceleration := settings.ground_acceleration if grounded else settings.air_acceleration
	if movement_input.is_zero_approx():
		acceleration = settings.ground_deceleration if grounded else settings.air_deceleration
	var target_speed := get_speed_for_gait(gait)
	if grounded:
		_airborne_sprint_takeoff_speed = 0.0
	elif target_speed > 0.0:
		if gait == FirstPersonGait.Gait.SPRINT:
			target_speed = get_speed_for_gait(FirstPersonGait.Gait.RUN)
		target_speed = maxf(target_speed, minf(_airborne_sprint_takeoff_speed, horizontal_velocity.length()))
	horizontal_velocity = horizontal_velocity.move_toward(
			direction * maxf(target_speed, 0.0), acceleration * delta
	)
	body.velocity.x = horizontal_velocity.x
	body.velocity.z = horizontal_velocity.z

	if grounded and body.velocity.y < 0.0:
		body.velocity.y = 0.0
	body.velocity.y -= settings.gravity * delta
	if jump_pressed and gait != FirstPersonGait.Gait.SPRINT \
			and (grounded or _coyote_time_remaining > 0.0):
		var jump_height := _get_jump_height(gait)
		if is_finite(jump_height) and jump_height > 0.0:
			body.velocity.y = sqrt(2.0 * settings.gravity * jump_height)
			_coyote_time_remaining = 0.0

	var rising := body.velocity.y > 0.0
	_stepped_last_tick = false
	if grounded and not rising:
		_stepped_last_tick = _stair_stepper.try_step(
				body, horizontal_velocity * delta, settings.max_step_height,
				body.floor_max_angle, delta
		)
	body.move_and_slide()
	if grounded and gait == FirstPersonGait.Gait.SPRINT \
			and not body.is_on_floor() and not _stepped_last_tick:
		_airborne_sprint_takeoff_speed = Vector2(body.velocity.x, body.velocity.z).length()
	var correction := 0.0
	if grounded and (body.is_on_floor() or _stepped_last_tick) and not rising:
		var displacement := body.global_position - start_position
		var support_after := _support_plane()
		var normal: Vector3 = support_before.normal
		var continuous := (
				normal.y > 0.001
				and absf((support_after.point - support_before.point).dot(normal)) < 0.001
				and absf(displacement.dot(normal)) < 0.001
		)
		if not continuous:
			correction = displacement.y
	_last_position = body.global_position
	_has_last_position = true
	terrain_advanced.emit(delta, correction)


func _get_jump_height(gait: FirstPersonGait.Gait) -> float:
	if gait == FirstPersonGait.Gait.CROUCH or gait == FirstPersonGait.Gait.CROUCH_WALK:
		return settings.crouch_jump_height
	return settings.jump_height


func _support_plane() -> Dictionary:
	var excluded: Array[RID] = [body.get_rid()]
	for exception in body.get_collision_exceptions():
		excluded.append(exception.get_rid())
	var query := PhysicsRayQueryParameters3D.create(
			body.global_position + Vector3.UP * 0.15,
			body.global_position - Vector3.UP * maxf(0.2, settings.max_step_height + 0.05),
			body.collision_mask, excluded
	)
	var hit := body.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		return {"point": hit.position, "normal": hit.normal}
	for index in body.get_slide_collision_count():
		var contact := body.get_slide_collision(index)
		if contact.get_normal().y >= cos(body.floor_max_angle):
			return {"point": contact.get_position(), "normal": contact.get_normal()}
	return {"point": body.global_position, "normal": Vector3.UP}
