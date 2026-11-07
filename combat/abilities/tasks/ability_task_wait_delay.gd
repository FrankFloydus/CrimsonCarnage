class_name AbilityTaskWaitDelay
extends AbilityTask
## Waits on the ASC's action clock and fires once unless its activation ends first.

signal finished

var _remaining: float


func _init(seconds: float) -> void:
	_remaining = seconds


func _start() -> void:
	if not is_finite(_remaining) or _remaining < 0.0:
		end_task()


func _advance(delta: float) -> void:
	_remaining -= delta
	if _remaining <= 0.0:
		end_task()
		finished.emit()
