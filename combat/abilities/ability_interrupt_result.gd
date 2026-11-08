class_name AbilityInterruptResult
extends RefCounted
## Actual executions stopped by an explicit interrupt request.

var interrupted_abilities: Array[int] = []
var interrupted_schools: Array[StringName] = []
var reason: StringName


func is_success() -> bool:
	return not interrupted_abilities.is_empty()
