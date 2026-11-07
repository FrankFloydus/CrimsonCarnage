class_name AbilityTaskWaitGameplayEvent
extends AbilityTask
## Listens for gameplay events while its activation is running.

signal event_received(tag: StringName, payload: Dictionary)

var _tag: StringName
var _only_once: bool
var _exact_match: bool


func _init(tag: StringName, only_once: bool = true, exact_match: bool = true) -> void:
	_tag = tag
	_only_once = only_once
	_exact_match = exact_match


func _start() -> void:
	if _tag.is_empty():
		end_task()


func _receive_gameplay_event(tag: StringName, payload: Dictionary) -> void:
	if tag != _tag and (_exact_match or not GameplayTagSet.matches(tag, _tag)):
		return
	if _only_once:
		end_task()
	event_received.emit(tag, payload.duplicate(true))
