class_name ResourceResult
extends RefCounted
## A committed pool change or a typed rejection, detached from actor nodes.

var committed: bool:
	get:
		return _event.failure.is_empty()
var actual_delta: float:
	get:
		return _event.actual_delta

var _event: Dictionary


func _init(request: ResourceRequest, applied_delta: float, failure: StringName = &"") -> void:
	var recipient := request.recipient if request != null else null
	_event = {
		"type": &"resource",
		"target_id": recipient.get_instance_id() if is_instance_valid(recipient) else 0,
		"resource": request.resource if request != null else -1,
		"requested_delta": request.delta if request != null and is_finite(request.delta) else 0.0,
		"actual_delta": applied_delta,
		"reason": request.reason if request != null else -1,
		"publish_outcome": request != null and request.publish_outcome,
		"failure": failure,
	}
	_event.make_read_only()


func get_event() -> Dictionary:
	return _event
