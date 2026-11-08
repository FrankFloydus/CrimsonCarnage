extends Node
## Shows a saved actor visual while a matching cast cue is active.

## Actor whose casts drive this visual.
@export var ability_system: AbilitySystem
## Registered Gameplay Cue tag that selects this visual.
@export var cue_tag: StringName = &""
## Saved visual shown from cast start until release, completion, or cancellation.
@export var visual: Node3D

var _router: GameplayCueRouter
var _active_casts: Dictionary[int, bool] = {}


func _ready() -> void:
	if not is_instance_valid(visual):
		return
	visual.hide()
	if not is_instance_valid(ability_system):
		return
	if ability_system.is_node_ready():
		_bind()
	else:
		ability_system.ready.connect(_bind, CONNECT_ONE_SHOT)


func _exit_tree() -> void:
	if _router != null:
		_router.unregister_handler(cue_tag, _on_cue)
		_router = null
	_active_casts.clear()
	if is_instance_valid(visual):
		visual.hide()


func _bind() -> void:
	if ability_system.effects == null:
		return
	_router = ability_system.effects.cues
	_router.register_handler(cue_tag, _on_cue)


func _on_cue(
		_target: Node, _tag: StringName, event: GameplayCueRouter.Event, parameters: Dictionary
) -> void:
	if not parameters.has("cast_id") or not is_instance_valid(visual):
		return
	var cast_id: int = parameters["cast_id"]
	match event:
		GameplayCueRouter.Event.WHILE_ACTIVE:
			_active_casts[cast_id] = true
		GameplayCueRouter.Event.REMOVED:
			_active_casts.erase(cast_id)
	visual.visible = not _active_casts.is_empty()
