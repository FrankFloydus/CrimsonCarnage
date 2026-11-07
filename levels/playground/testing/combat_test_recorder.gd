class_name CombatTestRecorder
extends RefCounted
## Session-only combat measurements owned by the playground tools.

signal changed
signal event_recorded(event: Dictionary)
signal log_cleared

const COUNT_FIELDS := [
	"casts", "failed_casts", "attempts", "hits", "critical_hits", "misses", "resists", "damage_events",
]
const AMOUNT_FIELDS := ["damage"]

var max_log_entries: int = 500
var _rows: Dictionary = {}
var _sources: Dictionary = {}
var _log: Array[Dictionary] = []
var _created_at: int = Time.get_ticks_msec()
var _combat_started_at: int = -1


func record_event(event: Dictionary) -> void:
	var ability_tags: PackedStringArray = event.get("ability_tags", PackedStringArray())
	if AttributeModifier._has_match(ability_tags, "Ability.Movement"):
		return
	var captured := event.duplicate(true)
	captured["timestamp"] = float(Time.get_ticks_msec() - _created_at) / 1000.0
	_log.append(captured)
	while _log.size() > maxi(1, max_log_entries):
		_log.pop_front()
	var event_type := StringName(event.get("type", &""))
	var source_id := int(event.get("source_id", 0))
	if source_id != 0:
		_sources[source_id] = str(event.get("source_name", "Actor %s" % source_id))
	var status_activation := event_type in [&"cast", &"cast_failed"] \
			and AttributeModifier._has_match(ability_tags, "Ability.Status")
	if not status_activation and event_type in [&"cast", &"cast_failed", &"hit_outcome", &"damage"]:
		if _combat_started_at < 0:
			_combat_started_at = Time.get_ticks_msec()
		_accumulate(event)
	event_recorded.emit(captured)
	changed.emit()


func reset() -> void:
	_rows.clear()
	_combat_started_at = -1
	changed.emit()


func clear_log() -> void:
	_log.clear()
	log_cleared.emit()


func elapsed_seconds() -> float:
	if _combat_started_at < 0:
		return 0.0
	return float(Time.get_ticks_msec() - _combat_started_at) / 1000.0


func get_log() -> Array[Dictionary]:
	return _log.duplicate(true)


func get_sources() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for source_id: int in _sources:
		result.append({"id": source_id, "name": _sources[source_id]})
	return result


func get_rows(source_id: int = 0) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var elapsed := elapsed_seconds()
	for row: Dictionary in _rows.values():
		if source_id != 0 and int(row["source_id"]) != source_id:
			continue
		var copy := row.duplicate(true)
		copy["dps"] = float(copy["damage"]) / elapsed if elapsed > 0.0 else 0.0
		result.append(copy)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["damage"]) > float(b["damage"]))
	return result


func get_totals(source_id: int = 0) -> Dictionary:
	var total := _empty_row()
	for row: Dictionary in get_rows(source_id):
		for field: String in COUNT_FIELDS:
			total[field] += int(row[field])
		for field: String in AMOUNT_FIELDS:
			total[field] += float(row[field])
	var elapsed := elapsed_seconds()
	total["dps"] = float(total["damage"]) / elapsed if elapsed > 0.0 else 0.0
	return total


func _accumulate(event: Dictionary) -> void:
	var source_id := int(event.get("source_id", 0))
	var ability_id := str(event.get("ability_id", ""))
	if ability_id.is_empty():
		ability_id = "unattributed"
	var key := "%s|%s" % [source_id, ability_id]
	if not _rows.has(key):
		var row := _empty_row()
		row["source_id"] = source_id
		row["source_name"] = str(event.get("source_name", "Unknown"))
		row["ability_id"] = ability_id
		var ability_name := str(event.get("ability_name", ""))
		row["ability_name"] = ability_name if not ability_name.is_empty() else ability_id.capitalize()
		_rows[key] = row
	var row: Dictionary = _rows[key]
	match StringName(event.get("type", &"")):
		&"cast":
			row["casts"] += 1
		&"cast_failed":
			row["failed_casts"] += 1
		&"hit_outcome":
			row["attempts"] += 1
			match StringName(event.get("outcome", &"")):
				&"hit":
					row["hits"] += 1
					if bool(event.get("is_critical", false)):
						row["critical_hits"] += 1
				&"miss":
					row["misses"] += 1
				&"resist":
					row["resists"] += 1
		&"damage":
			row["damage"] += maxf(0.0, float(event.get("amount", 0.0)))
			row["damage_events"] += 1


func _empty_row() -> Dictionary:
	var row: Dictionary = {}
	for field: String in COUNT_FIELDS:
		row[field] = 0
	for field: String in AMOUNT_FIELDS:
		row[field] = 0.0
	return row
