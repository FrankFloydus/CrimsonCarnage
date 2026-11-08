@tool
class_name AbilityPhaseDefinition
extends Resource
## Ordered conditions and actions attached to a named execution or delivery event.

## Determines how the ordered actions handle a successful result.
enum ExecutionMode {
	## Run every action unless an action failure or cast end stops the phase.
	ALL,
	## Stop after the first action reports a successful operation.
	FIRST_SUCCESS,
}

## Determines how a failed action or target query affects execution.
enum FailurePolicy {
	## Try later actions after an action failure. A failed target query ends the phase.
	CONTINUE,
	## Skip remaining actions in this phase while allowing the cast to proceed.
	STOP_PHASE,
	## End the cast through its cancellation and cleanup path.
	CANCEL_CAST,
}

const LIFECYCLE_EVENTS: Array[StringName] = [
	&"ability.requested", &"ability.committed", &"ability.cast_started", &"ability.cast_completed",
	&"ability.input_released", &"ability.released", &"ability.channel_tick",
	&"ability.cancelled", &"ability.finished", &"delivery.spawned", &"delivery.impact",
	&"delivery.expired", &"delivery.cancelled", &"area.tick", &"target.entered", &"target.exited",
]

## Exact execution or delivery event that runs this phase.
@export var event_key: StringName = &"delivery.impact":
	set(value):
		event_key = value
		notify_property_list_changed()
## Run an actor gameplay event immediately, including descendants of Event Key.
## Only Self targeting is allowed in a synchronous event.
@export var synchronous_gameplay_event: bool = false
## Optional replacement selection. Empty inherits the current event's contacts.
@export var targeting: AbilityTargetingDefinition
## All caster gates must pass. Target gates filter contacts independently.
@export var conditions: Array[AbilityConditionDefinition] = []
## Actions executed in this order against the selected contacts.
@export var actions: Array[AbilityActionDefinition] = []
## All runs the ordered actions. First Success stops after the first action reports success.
@export var execution_mode: ExecutionMode = ExecutionMode.ALL
## Continue tries later actions after an action failure. Stop Phase ends this phase only.
## Cancel Cast ends the activation through its cancellation path.
@export var failure_policy: FailurePolicy = FailurePolicy.STOP_PHASE
## Run this phase only once over the entire execution, including detached deliveries.
@export var run_once_per_execution: bool = false:
	set(value):
		run_once_per_execution = value
		notify_property_list_changed()
## Allow each actor to enter this phase at most once for this execution.
@export var run_once_per_target: bool = false
## Maximum number of phase invocations per execution. Zero leaves the count unlimited.
@export_range(0, 1000, 1, "or_greater") var max_fires: int = 0


func _validate_property(property: Dictionary) -> void:
	if (property.name == &"max_fires" and run_once_per_execution) \
			or (property.name == &"synchronous_gameplay_event" and is_lifecycle_event()):
		property.usage = int(property.usage) & ~PROPERTY_USAGE_EDITOR


## Built-in events are dispatched by the cast or delivery and already have a defined timing.
func is_lifecycle_event() -> bool:
	return event_key in LIFECYCLE_EVENTS


## Only actor gameplay events can opt into synchronous dispatch.
func runs_synchronously() -> bool:
	return synchronous_gameplay_event and not is_lifecycle_event()


func get_validation_error() -> StringName:
	if event_key.is_empty() or actions.is_empty():
		return &"missing_phase_event_or_actions"
	if execution_mode < ExecutionMode.ALL or execution_mode > ExecutionMode.FIRST_SUCCESS \
			or failure_policy < FailurePolicy.CONTINUE or failure_policy > FailurePolicy.CANCEL_CAST \
			or (not run_once_per_execution and max_fires < 0):
		return &"invalid_phase_policy"
	if targeting != null and not targeting.get_validation_error().is_empty():
		return targeting.get_validation_error()
	if runs_synchronously() and targeting != null \
			and targeting.shape != AbilityTargetingDefinition.Shape.SELF:
		return &"synchronous_event_requires_self_targeting"
	for condition: AbilityConditionDefinition in conditions:
		if condition == null:
			return &"missing_phase_condition"
		var error := condition.get_validation_error()
		if not error.is_empty():
			return error
	for action: AbilityActionDefinition in actions:
		if action == null:
			return &"missing_phase_action"
		var error := action.get_validation_error()
		if not error.is_empty():
			return error
	return &""
