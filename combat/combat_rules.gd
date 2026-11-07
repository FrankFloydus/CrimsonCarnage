class_name CombatRules
extends RefCounted
## Shared numeric tuning loaded once from the editable combat rules JSON.

const RULES_PATH: String = "res://combat/combat_rules.json"
## Compatibility for rule files and cached values from before the movement bonus cap.
const LEGACY_NUMBER_DEFAULTS: Dictionary[String, float] = {"movement_speed_max_percent": 25.0}

static var _loaded: bool = false
static var _values: Dictionary = {}


static func get_number(key: String) -> float:
	if not _loaded:
		_load_values()
	var value: Variant = _values.get(key, LEGACY_NUMBER_DEFAULTS.get(key))
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)):
		push_error("Combat rules require a finite numeric value for '%s'." % key)
		return 0.0
	return float(value)


## Reads a numeric lookup table, extending its first and last entries outside its index range.
static func get_number_at(key: String, index: int) -> float:
	if not _loaded:
		_load_values()
	var values: Variant = _values.get(key)
	if not values is Array or values.is_empty():
		push_error("Combat rules require a nonempty numeric array for '%s'." % key)
		return 0.0
	var value: Variant = values[clampi(index, 0, values.size() - 1)]
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)):
		push_error("Combat rule '%s' requires a finite numeric value at index %d." % [key, index])
		return 0.0
	return float(value)


static func _load_values() -> void:
	_loaded = true
	if not FileAccess.file_exists(RULES_PATH):
		push_error("Combat rules file is missing: %s" % RULES_PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RULES_PATH))
	if not parsed is Dictionary:
		push_error("Combat rules must contain a JSON object: %s" % RULES_PATH)
		return
	_values = parsed
