class_name FirstPersonController
extends CharacterBody3D
## Sends action input to the AbilitySystem and advances physical locomotion once.

const SPRINT_ABILITY = preload("res://player/abilities/sprint.tres")
const JUMP_ABILITY = preload("res://player/abilities/jump.tres")
const CROUCH_ABILITY = preload("res://player/abilities/crouch.tres")

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
			Input.is_action_just_pressed(&"jump"),
			Input.is_action_just_pressed(&"crouch"), Input.is_action_pressed(&"crouch"),
			Input.is_action_pressed(&"sprint"), Input.is_action_pressed(&"walk")
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
	var jump_id: int = JUMP_ABILITY.ability_id
	_update_crouch_input(crouch_pressed, crouch_held,
			not jump_pressed and _abilities.get_active_cast(jump_id) == null)
	_crouch.retry_standing()
	_update_sprint_input(delta, sprint_held, walk_held)
	var movement_locked := _abilities.tags.has_tag(&"State.Control.Rooted") \
			or _abilities.tags.has_tag(&"State.Control.Stunned")
	var cast_locks_movement := _abilities.handle_movement_intent(
			not movement_locked and (jump_pressed or not movement_input.is_zero_approx())
	)
	movement_locked = movement_locked or cast_locks_movement
	if jump_pressed and not movement_locked and _abilities.get_active_cast(jump_id) == null:
		_abilities.try_activate(jump_id)
	_movement.move(delta, movement_input, _gait.current_gait, movement_locked)


func _update_crouch_input(pressed: bool, held: bool, can_enter: bool) -> void:
	var ability_id: int = CROUCH_ABILITY.ability_id
	var active := _abilities.get_active_cast(ability_id)
	if _crouch.settings.mode == FirstPersonCrouchSettings.Mode.TOGGLE:
		if pressed:
			if active != null:
				_abilities.release_ability(ability_id)
			elif can_enter:
				_abilities.try_activate(ability_id)
	elif held:
		if active == null and can_enter and _abilities.get_activation_failure(ability_id).is_empty():
			_abilities.try_activate(ability_id)
	elif _crouch_input_held:
		_abilities.release_ability(ability_id)
	_crouch_input_held = held


func _update_sprint_input(delta: float, held: bool, walking: bool) -> void:
	var ability_id: int = SPRINT_ABILITY.ability_id
	if not held:
		if _sprint_input_held:
			_abilities.release_ability(ability_id)
		_gait.clear_sprint_release()
	_sprint_input_held = held
	var active := _abilities.get_active_cast(ability_id)
	var can_continue := active == null or _movement.can_continue_sprint(delta)
	_gait.advance(held or active != null, walking, _crouch.is_crouching, true, can_continue)
	if active != null and _gait.sprint_requires_release:
		active.cancel()
	elif active == null and _gait.current_gait == FirstPersonGait.Gait.SPRINT:
		if not _abilities.try_activate(ability_id) or _abilities.get_active_cast(ability_id) == null:
			_gait.advance(held, walking, _crouch.is_crouching, true, false)


func _on_ability_ended(ability_id: int, cancelled: bool) -> void:
	if ability_id == SPRINT_ABILITY.ability_id and cancelled and _sprint_input_held:
		_gait.require_sprint_release()


func _on_stance_changed(crouched: bool) -> void:
	if crouched:
		_abilities.tags.add_tag(&"State.Crouched")
	else:
		_abilities.tags.remove_tag(&"State.Crouched")
