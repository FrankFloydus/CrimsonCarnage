class_name PlayerActionRouter
extends Node
## Routes the player's assigned combat actions through their granted abilities.

const SLOT_PREFIX := "ability_slot_"
const PRIMARY_SLOT := &"ability_slot_1"

## Actor whose granted abilities are available to player combat slots.
@export var ability_system: AbilitySystem
## Default slot assignments authored in the Ability Editor's Player Actions workspace.
@export_file("*.json") var starting_loadout: String

var _slot_abilities: Dictionary[StringName, int] = {}
var _pending: Dictionary[StringName, PendingGesture] = {}
var _mouse_was_captured: bool = false


func _ready() -> void:
	_mouse_was_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	_load_starting_loadout()


func _process(_delta: float) -> void:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if _mouse_was_captured and not captured:
		_cancel_gameplay_input()
	_mouse_was_captured = captured


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_cancel_gameplay_input()


func _unhandled_input(event: InputEvent) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event.is_action_pressed(&"release_mouse"):
		_cancel_gameplay_input()
	elif handle_action_event(event):
		get_viewport().set_input_as_handled()


## Returns the assigned definition ID, or zero for an empty slot.
func get_slot_ability(action: StringName) -> int:
	return _slot_abilities.get(action, 0)


## Changes a slot assignment for this player. Zero clears the slot.
func set_slot_ability(action: StringName, ability_id: int) -> bool:
	if not String(action).begins_with(SLOT_PREFIX) or not InputMap.has_action(action):
		return false
	if ability_id == 0:
		_slot_abilities.erase(action)
	else:
		if _get_manual_grant(ability_id) == null:
			return false
		_slot_abilities[action] = ability_id
	return true


## Dispatches one Input Map event while gameplay input is active.
func handle_action_event(event: InputEvent) -> bool:
	if event.is_echo():
		return false
	var handled := false
	for action: StringName in _pending.keys():
		var gesture := _pending.get(action) as PendingGesture
		if gesture == null:
			continue
		var index := gesture.find_input(event)
		if index < 0:
			continue
		if event.is_canceled() or not InputMap.has_action(action):
			_pending.erase(action)
			gesture.cancel()
			return true
		if not event.is_action_released(action):
			return true
		gesture.inputs.remove_at(index)
		if gesture.inputs.is_empty():
			_pending.erase(action)
			if gesture.mode == AbilityDefinition.InputGesture.RELEASE:
				ability_system.try_activate_input_spec(gesture.spec_handle)
			elif gesture.cast != null:
				ability_system.release_cast_input(gesture.cast)
		# An analog input can release one action and press its opposite in the same event.
		if event is not InputEventJoypadMotion:
			return true
		handled = true
	for action: StringName in _slot_abilities:
		if InputMap.has_action(action) and event.is_action_pressed(action):
			_press_slot(action, event)
			return true
	return handled


## Clears armed releases and cancels the casts started by held inputs.
func cancel_pending_input() -> void:
	var pending := _pending.values()
	_pending.clear()
	for gesture: PendingGesture in pending:
		gesture.cancel()


func _press_slot(action: StringName, event: InputEvent) -> void:
	var gesture := _pending.get(action) as PendingGesture
	if gesture != null:
		gesture.inputs.append(event)
		return
	var spec := _get_manual_grant(_slot_abilities[action])
	if spec == null:
		return
	gesture = PendingGesture.new()
	gesture.mode = spec.definition.get_input_gesture()
	gesture.spec_handle = spec.handle
	gesture.inputs.append(event)
	_pending[action] = gesture
	if gesture.mode == AbilityDefinition.InputGesture.RELEASE:
		return
	var cast := ability_system.try_activate_input_spec(spec.handle)
	if gesture.mode != AbilityDefinition.InputGesture.PRESS:
		gesture.cast = cast
		if _pending.get(action) != gesture:
			gesture.cancel()


func _get_manual_grant(ability_id: int) -> GameplayAbilitySpec:
	if is_instance_valid(ability_system):
		for spec in ability_system.get_granted_ability_specs():
			if spec.definition.ability_id == ability_id and spec.definition.activation_event_tag.is_empty():
				return spec
	return null


func _cancel_gameplay_input() -> void:
	cancel_pending_input()
	if is_instance_valid(ability_system):
		ability_system.cancel_animation()


func _load_starting_loadout() -> void:
	if starting_loadout.is_empty():
		return
	var assignments: Variant = JSON.parse_string(FileAccess.get_file_as_string(starting_loadout))
	if assignments is not Dictionary:
		push_warning("Invalid player starting loadout: %s" % starting_loadout)
		return
	for action: String in assignments:
		var ability_id: Variant = assignments[action]
		if (ability_id is not int and ability_id is not float) or ability_id <= 0 \
				or ability_id != floor(ability_id) or not set_slot_ability(StringName(action), int(ability_id)):
			push_warning("Invalid starting ability assignment for %s in %s" % [action, starting_loadout])


class PendingGesture:
	var mode: AbilityDefinition.InputGesture
	var spec_handle: int
	var cast: AbilityCast
	var inputs: Array[InputEvent] = []

	func find_input(event: InputEvent) -> int:
		for index in inputs.size():
			if inputs[index].device == event.device and inputs[index].is_match(event, false):
				return index
		return -1

	func cancel() -> void:
		if cast != null:
			cast.cancel()
