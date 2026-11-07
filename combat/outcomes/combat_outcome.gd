class_name CombatOutcome
extends RefCounted
## A committed event with a causal identity and detached values for observers and reactions.

## The committed fact represented by an outcome, independently of its timing or provenance.
enum Kind {
	## An event without a dedicated typed reaction, such as retained effect application.
	OTHER,
	## The result of testing a delivery contact for a confirmed hit.
	HIT,
	## A damage transaction with the offered magnitude and actual Health loss.
	DAMAGE,
	## An independent decision about whether a status was applied.
	STATUS,
	## A healing transaction with the requested, scaled, restored, and excess amounts.
	HEALING,
	## A signed Mana or Stamina change with its requested and committed amounts.
	RESOURCE,
	## A damage transaction that killed a living recipient.
	KILL,
	## The completion of a target batch, including its final unique-target count.
	BATCH_COMPLETE,
	## The termination of a retained effect with its removal reason and optional instigator.
	EFFECT_REMOVED,
	## A retained accumulator publishing its stored contribution total.
	EFFECT_THRESHOLD,
}

var id: int:
	get:
		return _id
var kind: Kind:
	get:
		return _kind
var context: CombatOutcomeContext:
	get:
		return _context
var target_id: int:
	get:
		return int(_event.get("target_id", 0))
var source_id: int:
	get:
		return int(_event.get("source_id", 0))

var _id: int
var _kind: Kind
var _context: CombatOutcomeContext
var _event: Dictionary
var _published: bool = false
var _scoped_deliveries: Dictionary[int, bool] = {}


func _init(attribution: CombatOutcomeContext, event: Dictionary) -> void:
	_id = CombatOutcomeContext.allocate_id()
	_context = attribution
	_event = _copy_event_values(event)
	_event["event_id"] = _id
	if not _event.has("target_id"):
		_event["target_id"] = attribution.actor_id(CombatOutcomeContext.Role.TARGET)
	attribution.add_attribution(_event)
	_kind = _event_kind(StringName(_event.get("type", &"")))
	_event.make_read_only()


func get_event() -> Dictionary:
	return _event


## An unavailable or nonnumeric basis returns NAN, so an action cannot mistake it for zero.
func get_amount(key: StringName) -> float:
	var value: Variant = _event.get(key)
	if value is float or value is int:
		return float(value)
	return NAN


func is_confirmed_hit() -> bool:
	return kind == Kind.HIT and _event.get("outcome") == &"hit"


static func _event_kind(type: StringName) -> Kind:
	match type:
		&"hit_outcome":
			return Kind.HIT
		&"damage":
			return Kind.DAMAGE
		&"status_applied", &"status_rejected", &"effect_rejected":
			return Kind.STATUS
		&"healing":
			return Kind.HEALING
		&"resource":
			return Kind.RESOURCE
		&"kill":
			return Kind.KILL
		&"batch_complete":
			return Kind.BATCH_COMPLETE
		&"effect_removed":
			return Kind.EFFECT_REMOVED
		&"effect_threshold":
			return Kind.EFFECT_THRESHOLD
	return Kind.OTHER


static func _copy_event_values(input: Dictionary) -> Dictionary:
	var result := {}
	for key: Variant in input:
		if key is String or key is StringName or key is int:
			result[key] = _copy_event_value(input[key])
	return result


static func _copy_event_value(value: Variant) -> Variant:
	if value is Dictionary:
		var dictionary := _copy_event_values(value)
		dictionary.make_read_only()
		return dictionary
	if value is Array:
		var array := []
		for entry: Variant in value:
			array.append(_copy_event_value(entry))
		array.make_read_only()
		return array
	if value is Object or value is Callable or value is Signal or value is RID:
		return null
	return value
