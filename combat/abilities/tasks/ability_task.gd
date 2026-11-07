class_name AbilityTask
extends RefCounted
## One activation's latent work. Connect output signals before starting the task on a cast.

var _owner: WeakRef
var _active: bool = false


func get_cast() -> AbilityCast:
	return _owner.get_ref() as AbilityCast if _owner != null else null


func is_active() -> bool:
	return _active


## Stops the task and releases its subscription. The owning ability stays active.
func end_task() -> void:
	if not _active:
		return
	_active = false
	var cast := get_cast()
	if cast != null:
		cast._remove_task(self)
	_cleanup()


func _attach(cast: AbilityCast) -> bool:
	if _owner != null or cast.finished:
		return false
	_owner = weakref(cast)
	_active = true
	return true


func _start() -> void:
	pass


func _advance(_delta: float) -> void:
	pass


func _receive_gameplay_event(_tag: StringName, _payload: Dictionary) -> void:
	pass


func _input_released() -> void:
	pass


func _cleanup() -> void:
	pass


func _end_from_cast(_cancelled: bool) -> void:
	end_task()
