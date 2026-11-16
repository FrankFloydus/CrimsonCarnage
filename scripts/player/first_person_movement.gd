class_name FirstPersonMovement
extends MoverComponent
## Connects the native first-person solver to the player scene's movement settings and signals.

## Advances camera compensation after a physics tick, with only supported terrain height changes.
signal terrain_advanced(delta: float, height_change: float)
## Clears terrain presentation when an external position change invalidates stair contacts.
signal terrain_reset
## Emitted when a jump is accepted, including jumps during coyote time.
signal jump_started
## Reports a new floor contact and its pre-collision downward velocity, in m/s.
signal landed(impact_speed: float)
## Reports a dash start with its locked local direction and a dash stop with a zero direction.
signal dash_state_changed(active: bool, local_direction: Vector2)

## The parent character whose velocity and collision movement this component owns.
@export var body: CharacterBody3D
## Gait, jump, dash, acceleration, gravity and terrain settings.
@export var settings: FirstPersonMovementSettings:
	set(value):
		settings = value
		if _native_solver != null:
			_native_solver.configure(value)

## Gait used by the last movement step.
var effective_gait: FirstPersonGait.Gait:
	get:
		return _effective_gait

var _effective_gait: FirstPersonGait.Gait = FirstPersonGait.Gait.RUN
var _native_solver: FirstPersonMotionSolver


func _ready() -> void:
	if body != get_parent():
		push_error("Assign the parent CharacterBody3D to Movement's Body.")
		return
	_native_solver = boot_first_person(settings)
	if _native_solver == null:
		return
	_native_solver.terrain_advanced.connect(terrain_advanced.emit)
	_native_solver.terrain_reset.connect(terrain_reset.emit)
	_native_solver.jump_started.connect(jump_started.emit)
	_native_solver.landed.connect(landed.emit)
	_native_solver.dash_state_changed.connect(dash_state_changed.emit)


## Advances locomotion once per physics tick. Input uses X for strafe and negative Y for forward.
## Jump requires floor or coyote support. Dash requires a direction and can start in the air.
func move(
		delta: float,
		movement_input: Vector2,
		gait: FirstPersonGait.Gait = FirstPersonGait.Gait.RUN,
		jump_pressed: bool = false,
		dash_pressed: bool = false
) -> void:
	if _native_solver == null or not is_instance_valid(body) or not body.is_inside_tree():
		return
	_effective_gait = gait
	_native_solver.advance(body, delta, movement_input, gait, jump_pressed, dash_pressed)


## Includes one-tick stair support and invalidates floor contacts after an external move.
func is_grounded() -> bool:
	return _native_solver != null and _native_solver.is_grounded(body)


## Reports whether the last physics step used dash velocity, including the final dash step.
func did_dash_last_step() -> bool:
	return _native_solver != null and _native_solver.did_dash_last_step()


## Horizontal travel in meters over the last supported movement step, with floor carry removed.
func get_ground_travel() -> Vector2:
	return _native_solver.get_ground_travel(body) if _native_solver != null else Vector2.ZERO


## Reports grounded deceleration from releasing movement on the latest step.
func is_ground_braking() -> bool:
	return _native_solver != null and _native_solver.is_ground_braking(body)


## Returns the authored full-input speed for the selected gait, in m/s.
func get_speed_for_gait(gait: FirstPersonGait.Gait) -> float:
	return _native_solver.get_speed_for_gait(gait) if _native_solver != null else 0.0
