class_name HealingResult
extends RefCounted
## A committed healing outcome or a typed rejection, detached from actor nodes.

var committed: bool:
	get:
		return _event.failure.is_empty()
var actual_restoration: float:
	get:
		return _event.actual_restoration

var _event: Dictionary


func _init(
		request: HealingRequest,
		source_scaled: float,
		scaled: float,
		restored: float,
		failure: StringName = &"",
		absorbed: float = 0.0
) -> void:
	var recipient := request.recipient if request != null else null
	_event = {
		"type": &"healing",
		"target_id": recipient.get_instance_id() if is_instance_valid(recipient) else 0,
		"requested_healing": request.requested_amount \
				if request != null and is_finite(request.requested_amount) else 0.0,
		"source_scaled_healing": source_scaled,
		"scaled_healing": scaled,
		"absorbed_healing": absorbed,
		"offered_healing": scaled - absorbed,
		"actual_restoration": maxf(0.0, restored),
		"actual_health_delta": restored,
		"overheal": maxf(0.0, scaled - absorbed - maxf(0.0, restored)),
		"proc_eligible": request != null and (
				request.mode == HealingRequest.Mode.HEAL or request.snapshot_triggers_reactions),
		"failure": failure,
	}
	_event.make_read_only()


func get_event() -> Dictionary:
	return _event
