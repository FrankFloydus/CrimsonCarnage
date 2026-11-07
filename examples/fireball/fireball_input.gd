extends Node
## Requests the example's granted ability without coupling input to its execution.

## Ability component receiving player requests; AI can call the same API directly.
@export var ability_system: AbilitySystem
## Granted ability identifier to request when the input action is pressed.
@export var ability_id: StringName = &"fireball"
## Input Map action used to activate the example ability while the mouse is captured.
@export var input_action: StringName = &"use_ability"
## Saved cast cue shown only while the example actor owns the casting tag.
@export var casting_visual: Node3D

var _controls_were_active: bool = false


func _ready() -> void:
	_controls_were_active = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if ability_system != null:
		ability_system.tags.changed.connect(_on_tags_changed)
	_update_casting_visual()


func _process(_delta: float) -> void:
	if ability_system == null:
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_controls_were_active = false
		ability_system.cancel_animation()
		return
	if not _controls_were_active:
		_controls_were_active = true
		return
	if Input.is_action_just_pressed(input_action):
		ability_system.try_activate(ability_id)


## Ignore the first captured frame after a menu closes, including its closing mouse click.
func reset_input_latch() -> void:
	_controls_were_active = false


func _on_tags_changed(_tag: StringName, _present: bool) -> void:
	_update_casting_visual()


func _update_casting_visual() -> void:
	if casting_visual != null:
		casting_visual.visible = ability_system != null \
				and ability_system.tags.has_tag(&"State.Casting")
