@tool
extends MarginContainer
## Sends preview shortcuts from the viewport hosting this workspace.

signal key_input(event: InputEventKey)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and is_visible_in_tree():
		key_input.emit(event)
