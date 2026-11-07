class_name FirstPersonController
extends CharacterBody3D
## Sends action input to the AbilitySystem and advances physical locomotion once.

const SPRINT: StringName = &"sprint"
const JUMP: StringName = &"jump"
const CROUCH: StringName = &"crouch"

var _gait := FirstPersonGait.new()
var _sprint_input_held: bool = false
var _crouch_input_held: bool = false

@onready var _movement: FirstPersonMovement = $Movement
@onready var _crouch: FirstPersonCrouch = $Crouch
@onready var _abilities: AbilitySystem = $AbilitySystem


func _ready() -> void:
	_abilities.ability_ended.connect(_on_ability_ended)
	_crouch.stance_changed.connect(_on_stance_changed)


func _physics_process(delta: float) -> void:
	var controls_active := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if not controls_active:
		advance_locomotion(delta, Vector2.ZERO)
		return
	var movement_input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
	advance_locomotion(delta, movement_input,
			Input.is_action_just_pressed(JUMP),
			Input.is_action_just_pressed(CROUCH), Input.is_action_pressed(CROUCH),
			Input.is_action_pressed(SPRINT), Input.is_action_pressed(&"walk")
	)


## Processes one physics interval using supplied input. AI may also request actions via AbilitySystem.
func advance_locomotion(
		delta: float,
		movement_input: Vector2,
		jump_pressed: bool = false,
		crouch_pressed: bool = false,
		crouch_held: bool = false,
		sprint_held: bool = false,
		walk_held: bool = false
) -> void:
	_update_crouch_input(crouch_pressed, crouch_held,
			not jump_pressed and _abilities.get_active_cast(JUMP) == null)
	_crouch.retry_standing()
	_update_sprint_input(delta, sprint_held, walk_held)
	if jump_pressed and _abilities.get_active_cast(JUMP) == null:
		_abilities.try_activate(JUMP)
	_movement.move(delta, movement_input, _gait.current_gait)


func _update_crouch_input(pressed: bool, held: bool, can_enter: bool) -> void:
	var active := _abilities.get_active_cast(CROUCH)
	if _crouch.settings.mode == FirstPersonCrouchSettings.Mode.TOGGLE:
		if pressed:
			if active != null:
				_abilities.release_ability(CROUCH)
			elif can_enter:
				_abilities.try_activate(CROUCH)
	elif held:
		if active == null and can_enter and _abilities.get_activation_failure(CROUCH).is_empty():
			_abilities.try_activate(CROUCH)
	elif _crouch_input_held:
		_abilities.release_ability(CROUCH)
	_crouch_input_held = held


func _update_sprint_input(delta: float, held: bool, walking: bool) -> void:
	if not held:
		if _sprint_input_held:
			_abilities.release_ability(SPRINT)
		_gait.clear_sprint_release()
	_sprint_input_held = held
	var active := _abilities.get_active_cast(SPRINT)
	var can_continue := active == null or _movement.can_continue_sprint(delta)
	_gait.advance(held or active != null, walking, _crouch.is_crouching, true, can_continue)
	if active != null and _gait.sprint_requires_release:
		active.cancel()
	elif active == null and _gait.current_gait == FirstPersonGait.Gait.SPRINT:
		if not _abilities.try_activate(SPRINT) or _abilities.get_active_cast(SPRINT) == null:
			_gait.advance(held, walking, _crouch.is_crouching, true, false)


func _on_ability_ended(ability_id: StringName, cancelled: bool) -> void:
	if ability_id == SPRINT and cancelled and _sprint_input_held:
		_gait.require_sprint_release()


func _on_stance_changed(crouched: bool) -> void:
	if crouched:
		_abilities.tags.add_tag(&"State.Crouched")
	else:
		_abilities.tags.remove_tag(&"State.Crouched")
