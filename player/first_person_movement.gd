class_name FirstPersonMovement
extends Node
## Accelerates a character, applies custom gravity, and resolves jumping and collisions.

## Advances camera compensation after a physics tick, with only supported terrain height changes.
signal terrain_advanced(delta: float, height_change: float)
## Clears terrain presentation when an external position change invalidates stair contacts.
signal terrain_reset

## Character whose velocity and collision movement this component owns.
@export var body: CharacterBody3D
## Actor supplying the Movement Speed bonus, carried weight and carry capacity.
@export var attributes: ActorAttributes
## Gait, encumbrance, jump, acceleration, gravity and terrain settings.
@export var settings: FirstPersonMovementSettings

## Gait actually used by the last movement step, after sprint eligibility was checked.
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
var _sprint_request: AbilityCast
var _quote_sprint_step: Callable
var _commit_sprint_step: Callable
var _sprint_charge_interval: float = 0.0
var _unpaid_sprint_travel: float = 0.0
var _airborne_sprint_takeoff_speed: float = 0.0
var _jump_request: AbilityCast


## Advances locomotion once per physics tick. Input uses X for strafe and negative Y for forward.
## Resolves the selected movement mode through this component's settings; defaults to normal run.
func move(
		delta: float,
		movement_input: Vector2,
		gait: FirstPersonGait.Gait = FirstPersonGait.Gait.RUN
) -> void:
	if _moving or not is_finite(delta) or delta <= 0.0 or not is_instance_valid(body) \
			or settings == null or not body.is_inside_tree():
		return
	_moving = true
	# Quote before callbacks can change tuning. The debit applies only to completed travel.
	var sprint_cost := _get_sprint_step_cost(delta) if gait == FirstPersonGait.Gait.SPRINT else -1.0
	var effective := gait
	if gait == FirstPersonGait.Gait.SPRINT and sprint_cost < 0.0:
		effective = FirstPersonGait.Gait.RUN
	var jump_cast := _jump_request
	_jump_request = null
	var launched := _advance_movement(
			delta, movement_input, effective, sprint_cost, jump_cast
	)
	if jump_cast != null and not jump_cast.finished:
		if launched:
			jump_cast.finish()
		else:
			jump_cast.cancel()
	_moving = false


## Includes one-tick stair support, but never reuses floor contacts after an external move.
func is_grounded() -> bool:
	if not is_instance_valid(body):
		return false
	if _has_last_position and not body.global_position.is_equal_approx(_last_position):
		return false
	return body.is_on_floor() or _stepped_last_tick


## Checks physical sprint availability. The Sprint execution owns eligibility and cost rules.
func can_move_in_sprint() -> bool:
	return get_speed_for_gait(FirstPersonGait.Gait.SPRINT) > 0.0


## Checks whether the active Sprint can fund the next full travel charge.
func can_continue_sprint(delta: float) -> bool:
	return _get_sprint_step_cost(delta) >= 0.0


## Authorizes the sprint gait until this specific ability activation ends.
func begin_sprint(cast: AbilityCast, interval: float, quote_step: Callable, commit_step: Callable) -> bool:
	if _has_sprint_request() or cast == null or cast.finished or not is_finite(interval) \
			or interval < 0.01 or not quote_step.is_valid() or not commit_step.is_valid():
		return false
	_sprint_request = cast
	_sprint_charge_interval = interval
	_quote_sprint_step = quote_step
	_commit_sprint_step = commit_step
	return true


## Revokes only the ending activation's request.
func end_sprint(cast: AbilityCast) -> void:
	if _sprint_request == cast:
		_sprint_request = null
		_sprint_charge_interval = 0.0
		_quote_sprint_step = Callable()
		_commit_sprint_step = Callable()


## Checks floor or coyote support and the physical height of the proposed takeoff.
func get_jump_failure(crouched: bool) -> StringName:
	if settings == null or not is_instance_valid(body) or not body.is_inside_tree():
		return &"missing_movement"
	var position_changed := _has_last_position and not body.global_position.is_equal_approx(_last_position)
	if not is_grounded() and (position_changed or _coyote_time_remaining <= 0.0):
		return &"jump_unsupported"
	var gait := FirstPersonGait.Gait.CROUCH if crouched else FirstPersonGait.Gait.RUN
	if _get_effective_jump_height(gait) <= 0.0:
		return &"jump_height_unavailable"
	return &""


## Queues one takeoff for the next movement step, which resolves the activation.
func request_jump(cast: AbilityCast) -> bool:
	if _jump_request != null and not _jump_request.finished:
		return false
	_jump_request = cast
	return true


## Resolves normal speed, the live bonus, gait and encumbrance in meters per second.
## Zero bonus keeps normal speed; minus one hundred percent stops requested horizontal movement.
func get_speed_for_gait(gait: FirstPersonGait.Gait) -> float:
	if settings == null or not is_instance_valid(attributes) \
			or attributes.get_value(CombatAttributes.Id.HEALTH) <= 0.0:
		return 0.0
	var bonus := attributes.get_value(CombatAttributes.Id.MOVEMENT_SPEED)
	if not is_finite(bonus):
		return 0.0
	var base_speed := settings.normal_run_speed
	if not is_finite(base_speed) or base_speed < 0.0:
		return 0.0
	var speed := base_speed * maxf(0.0, 1.0 + bonus / 100.0)
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
	var result := speed * multiplier * get_encumbrance_factors().x
	return result if is_finite(result) and result >= 0.0 else 0.0


## Returns the current horizontal speed factor in X and jump height factor in Y.
## Speed drops fastest just above capacity, while jump height decreases linearly.
func get_encumbrance_factors() -> Vector2:
	if settings == null or not is_instance_valid(attributes):
		return Vector2.ONE
	var capacity := attributes.get_value(CombatAttributes.Id.CARRY_CAPACITY)
	var weight := attributes.get_value(CombatAttributes.Id.CARRIED_WEIGHT)
	if not is_finite(capacity) or not is_finite(weight) or capacity <= 0.0 or weight <= capacity:
		return Vector2.ONE
	var full_ratio := settings.full_penalty_ratio
	var minimum_speed := settings.min_speed_multiplier
	if not is_finite(full_ratio) or full_ratio <= 1.0 or not is_finite(minimum_speed):
		return Vector2.ONE
	var progress := clampf((weight / capacity - 1.0) / (full_ratio - 1.0), 0.0, 1.0)
	var jump_height_factor := 1.0 - progress
	var speed_factor := lerpf(clampf(minimum_speed, 0.0, 1.0), 1.0, pow(jump_height_factor, 3.0))
	return Vector2(speed_factor, jump_height_factor)


func _advance_movement(
		delta: float,
		movement_input: Vector2,
		gait: FirstPersonGait.Gait,
		sprint_cost: float,
		jump_cast: AbilityCast
) -> bool:
	if not is_finite(movement_input.x) or not is_finite(movement_input.y):
		movement_input = Vector2.ZERO
	_effective_gait = gait
	var sprint_cast := _sprint_request
	var position_changed := (
			_has_last_position and not body.global_position.is_equal_approx(_last_position)
	)
	if position_changed:
		_stair_stepper.reset()
		_stepped_last_tick = false
		_coyote_time_remaining = 0.0
		_airborne_sprint_takeoff_speed = 0.0
		terrain_reset.emit()
	if _effective_gait == FirstPersonGait.Gait.SPRINT \
			and (not _has_sprint_request() or _sprint_request != sprint_cast):
		_effective_gait = FirstPersonGait.Gait.RUN
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
	var target_speed := get_speed_for_gait(_effective_gait)
	if grounded:
		_airborne_sprint_takeoff_speed = 0.0
	elif target_speed > 0.0:
		if _effective_gait == FirstPersonGait.Gait.SPRINT:
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
	var launched := false
	if jump_cast != null and not jump_cast.finished \
			and (grounded or _coyote_time_remaining > 0.0):
		var jump_height := _get_effective_jump_height(_effective_gait)
		if jump_height > 0.0:
			body.velocity.y = sqrt(2.0 * settings.gravity * jump_height)
			_coyote_time_remaining = 0.0
			launched = true

	var rising := body.velocity.y > 0.0
	_stepped_last_tick = false
	if grounded and not rising:
		_stepped_last_tick = _stair_stepper.try_step(
				body, horizontal_velocity * delta, settings.max_step_height,
				body.floor_max_angle, delta
		)
	body.move_and_slide()
	var actual_travel := body.global_position - start_position
	if grounded and _effective_gait == FirstPersonGait.Gait.SPRINT:
		if not body.is_on_floor() and not _stepped_last_tick:
			_airborne_sprint_takeoff_speed = Vector2(body.velocity.x, body.velocity.z).length()
		if not movement_input.is_zero_approx() and target_speed > 0.0 \
				and Vector2(actual_travel.x, actual_travel.z).length_squared() > 1.0e-12 \
				and _has_sprint_request() and _sprint_request == sprint_cast:
			_pay_sprint_travel(delta, sprint_cost, sprint_cast)
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
	terrain_advanced.emit(delta, correction)
	_last_position = body.global_position
	_has_last_position = true
	return launched


func _has_sprint_request() -> bool:
	return _sprint_request != null and not _sprint_request.finished


func _get_sprint_step_cost(delta: float) -> float:
	if not is_finite(delta) or delta <= 0.0 or not _has_sprint_request() or not can_move_in_sprint():
		return -1.0
	return _quote_sprint_step.call()


func _pay_sprint_travel(delta: float, cost: float, cast: AbilityCast) -> void:
	if cost <= 0.0:
		return
	_unpaid_sprint_travel += delta
	var interval := _sprint_charge_interval
	while _sprint_request == cast and not cast.finished and _unpaid_sprint_travel + 1.0e-9 >= interval:
		if not _commit_sprint_step.call(cost):
			break
		_unpaid_sprint_travel = maxf(0.0, _unpaid_sprint_travel - interval)


func _get_effective_jump_height(gait: FirstPersonGait.Gait) -> float:
	var height := settings.jump_height
	if gait == FirstPersonGait.Gait.CROUCH or gait == FirstPersonGait.Gait.CROUCH_WALK:
		height = settings.crouch_jump_height
	height *= get_encumbrance_factors().y
	return height if is_finite(height) else 0.0


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
