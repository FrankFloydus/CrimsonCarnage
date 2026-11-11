class_name FirstPersonMovement
extends Node
## Accelerates a character, applies custom gravity, and resolves jumping and collisions.

## Advances camera compensation after a physics tick, with only supported terrain height changes.
signal terrain_advanced(delta: float, height_change: float)
## Clears terrain presentation when an external position change invalidates stair contacts.
signal terrain_reset
## Reports a dash start with its locked local direction (X strafe, negative Y forward).
## Reports a dash stop with a zero direction, including when a collision ends it early.
signal dash_state_changed(active: bool, local_direction: Vector2)

## Character whose velocity and collision movement this component owns.
@export var body: CharacterBody3D
## Gait, jump, dash, acceleration, gravity and terrain settings.
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
var _dash_charges: int = -1
var _dash_recharge_elapsed: float = 0.0
var _dash_time_left: float = 0.0
var _dash_velocity: Vector3 = Vector3.ZERO
var _dash_saved_vertical_speed: float = 0.0


## Advances locomotion once per physics tick. Input uses X for strafe and negative Y for forward.
## Jump requires floor or coyote support. Dash requires a movement direction and can start in the air.
func move(
		delta: float,
		movement_input: Vector2,
		gait: FirstPersonGait.Gait = FirstPersonGait.Gait.RUN,
		jump_pressed: bool = false,
		dash_pressed: bool = false
) -> void:
	if _moving or not is_finite(delta) or delta <= 0.0 or not is_instance_valid(body) \
			or settings == null or not body.is_inside_tree():
		return
	_moving = true
	_advance_movement(delta, movement_input, gait, jump_pressed, dash_pressed)
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
		FirstPersonGait.Gait.CROUCH:
			multiplier = settings.crouch_speed_multiplier
		FirstPersonGait.Gait.CROUCH_WALK:
			multiplier = settings.crouch_walk_speed_multiplier
	var result := base_speed * multiplier
	return result if is_finite(result) and result >= 0.0 else 0.0


func _advance_movement(
		delta: float,
		movement_input: Vector2,
		gait: FirstPersonGait.Gait,
		jump_pressed: bool,
		dash_pressed: bool
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
		if _dash_time_left > 0.0:
			_finish_dash(true)
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
	_recharge_dash(delta)
	if dash_pressed and _dash_time_left <= 0.0:
		_try_start_dash(direction, movement_input, grounded)
	var dashing := _dash_time_left > 0.0
	var horizontal_velocity: Vector3
	if dashing:
		# Scale the final tick to the remaining burst time.
		horizontal_velocity = _dash_velocity * minf(1.0, _dash_time_left / delta)
		body.velocity.y = 0.0
	else:
		var acceleration := settings.ground_acceleration if grounded else settings.air_acceleration
		if movement_input.is_zero_approx():
			acceleration = settings.ground_deceleration if grounded else settings.air_deceleration
		var previous_velocity := Vector3(body.velocity.x, 0.0, body.velocity.z)
		horizontal_velocity = previous_velocity.move_toward(
				direction * get_speed_for_gait(gait), acceleration * delta
		)
		_advance_vertical_velocity(delta, gait, grounded, jump_pressed)
	body.velocity.x = horizontal_velocity.x
	body.velocity.z = horizontal_velocity.z

	var rising := body.velocity.y > 0.0
	_stepped_last_tick = false
	if grounded and not rising:
		_stepped_last_tick = _stair_stepper.try_step(
				body, horizontal_velocity * delta, settings.max_step_height,
				body.floor_max_angle, delta
		)
	body.move_and_slide()
	if dashing:
		_dash_time_left -= delta
		var hit_wall := body.is_on_wall() and body.get_wall_normal().dot(_dash_velocity) < -0.001
		if _dash_time_left <= 0.0 or hit_wall:
			_finish_dash(body.is_on_floor() or _stepped_last_tick)
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


func _advance_vertical_velocity(
		delta: float,
		gait: FirstPersonGait.Gait,
		grounded: bool,
		jump_pressed: bool
) -> void:
	if grounded and body.velocity.y < 0.0:
		body.velocity.y = 0.0
	body.velocity.y -= settings.gravity * delta
	if jump_pressed and (grounded or _coyote_time_remaining > 0.0):
		var jump_height := _get_jump_height(gait)
		if is_finite(jump_height) and jump_height > 0.0:
			body.velocity.y = sqrt(2.0 * settings.gravity * jump_height)
			_coyote_time_remaining = 0.0


func _recharge_dash(delta: float) -> void:
	var capacity := maxi(settings.dash_max_charges, 0)
	_dash_charges = capacity if _dash_charges < 0 else mini(_dash_charges, capacity)
	if _dash_charges == capacity:
		_dash_recharge_elapsed = 0.0
		return
	var recharge_time := settings.dash_recharge_time
	if not is_finite(recharge_time) or recharge_time <= 0.0:
		return
	_dash_recharge_elapsed += delta
	while _dash_charges < capacity and _dash_recharge_elapsed >= recharge_time:
		_dash_charges += 1
		_dash_recharge_elapsed -= recharge_time
	if _dash_charges == capacity:
		_dash_recharge_elapsed = 0.0


func _try_start_dash(direction: Vector3, local_direction: Vector2, grounded: bool) -> void:
	var speed := settings.dash_speed
	var duration := settings.dash_duration
	if direction.is_zero_approx() or _dash_charges <= 0 or not is_finite(speed) or speed <= 0.0 \
			or not is_finite(duration) or duration <= 0.0:
		return
	_dash_charges -= 1
	_dash_velocity = direction.normalized() * speed
	_dash_time_left = duration
	_dash_saved_vertical_speed = 0.0 if grounded else body.velocity.y
	dash_state_changed.emit(true, local_direction.normalized())


func _finish_dash(grounded: bool) -> void:
	_dash_time_left = 0.0
	body.velocity = Vector3(0.0, 0.0 if grounded else _dash_saved_vertical_speed, 0.0)
	dash_state_changed.emit(false, Vector2.ZERO)


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
