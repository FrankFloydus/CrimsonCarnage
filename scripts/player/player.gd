class_name Player
extends CharacterBody3D
## Resolves first-person movement input and advances physical locomotion once.

var _gait := FirstPersonGait.new()
var _crouch_input_held: bool = false

@onready var _movement: FirstPersonMovement = $Movement
@onready var _crouch: FirstPersonCrouch = $Crouch


func _physics_process(delta: float) -> void:
	var controls_active := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if not controls_active:
		advance_locomotion(delta, Vector2.ZERO)
		return
	var movement_input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
	advance_locomotion(delta, movement_input,
			Input.is_action_just_pressed(&"jump"),
			Input.is_action_just_pressed(&"crouch"), Input.is_action_pressed(&"crouch"),
			Input.is_action_pressed(&"sprint"), Input.is_action_pressed(&"walk")
	)


## Resolves stance, gait, and takeoff for one physics interval using the supplied input.
func advance_locomotion(
		delta: float,
		movement_input: Vector2,
		jump_pressed: bool = false,
		crouch_pressed: bool = false,
		crouch_held: bool = false,
		sprint_held: bool = false,
		walk_held: bool = false
) -> void:
	_update_crouch_input(crouch_pressed, crouch_held, not jump_pressed and _movement.is_grounded())
	_crouch.retry_standing()
	_gait.advance(sprint_held, walk_held, _crouch.is_crouching)
	_movement.move(delta, movement_input, _gait.current_gait, jump_pressed)


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
