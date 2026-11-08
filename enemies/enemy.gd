@tool
class_name Enemy
extends Node3D
## Enemy actor with scene-composed attributes and abilities.

## Attributes component owned by this actor.
var attributes: ActorAttributes
## Ability system owned by this actor.
var ability_system: AbilitySystem


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	attributes = $Attributes
	ability_system = $AbilitySystem
