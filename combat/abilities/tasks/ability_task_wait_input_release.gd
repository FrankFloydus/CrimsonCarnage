class_name AbilityTaskWaitInputRelease
extends AbilityTask
## Waits for the release request routed to this activation's grant by the ASC.

signal released


func _input_released() -> void:
	end_task()
	released.emit()
