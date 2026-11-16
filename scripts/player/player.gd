class_name Player
extends CharacterBody3D
## Resolves first-person movement input and advances physical locomotion once.

const LOCOMOTION_MAP := &"Locomotion"
const WALK := &"walk"
const CROUCH := &"crouch"
const DASH := &"dash"

var _gait := FirstPersonGait.new()
var _crouch_input_held: bool = false
var _controls: Controls

@onready var _movement: FirstPersonMovement = $Movement
@onready var _crouch: FirstPersonCrouch = $Crouch
@onready var _controls_setup: ControlsComponent = $Controls


func _ready() -> void:
	_controls = Controls.boot(self, _controls_setup.input_layout)
	if _controls == null or not _controls.is_ready() or _controls.set_map_enabled(LOCOMOTION_MAP, true) != OK:
		push_error("Assign a valid Locomotion Input Layout to the player's Controls.")
		_controls = null


func _physics_process(delta: float) -> void:
	_advance_control_frame(delta, Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)


func _advance_control_frame(delta: float, controls_active: bool) -> void:
	if not controls_active or _controls == null or not _controls.is_ready():
		advance_locomotion(delta, Vector2.ZERO)
		return
	advance_locomotion(delta, _controls.vector(_controls_setup.move_action),
			_controls.pressed(_controls_setup.jump_action),
			_controls.pressed(CROUCH), _controls.held(CROUCH),
			_controls.held(WALK), _controls.pressed(DASH)
	)


## Resolves stance, gait, and takeoff for one physics interval using the supplied input.
func advance_locomotion(
		delta: float,
		movement_input: Vector2,
		jump_pressed: bool = false,
		crouch_pressed: bool = false,
		crouch_held: bool = false,
		walk_held: bool = false,
		dash_pressed: bool = false
) -> void:
	_update_crouch_input(crouch_pressed, crouch_held, not jump_pressed and _movement.is_grounded())
	_crouch.retry_standing()
	_gait.advance(walk_held, _crouch.is_crouching)
	_movement.move(delta, movement_input, _gait.current_gait, jump_pressed, dash_pressed)


func _update_crouch_input(pressed: bool, held: bool, can_enter: bool) -> void:
	if _crouch.settings.mode == FirstPersonCrouchSettings.Mode.TOGGLE:
		if pressed:
			if _crouch.is_crouching:
				_crouch.try_set_crouched(false)
			elif can_enter:
				_crouch.try_set_crouched(true)
	elif held:
		if can_enter or _crouch.is_crouching:
			_crouch.try_set_crouched(true)
	elif _crouch_input_held:
		_crouch.request_stand()
	_crouch_input_held = held
