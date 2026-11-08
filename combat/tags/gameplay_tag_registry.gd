@tool
class_name GameplayTagRegistry
extends RefCounted
## Authoring view of the project tag registry maintained by the standalone editor.

## Whether a field assigns an explicit tag or can match an implied parent branch.
enum FieldKind {
	## The property is unrelated to the gameplay tag registry.
	NONE,
	## The property stores an explicitly registered tag.
	ASSIGNMENT,
	## The property can query an explicit tag or an implied parent.
	QUERY,
}

const PATH := "res://combat/tags/gameplay_tags.json"

static var _loaded := false
static var _source: Variant = null
static var _load_error := ""
static var _descriptions: Dictionary[StringName, String] = {}
static var _query_tags: Dictionary[StringName, bool] = {}
static var _assignments := PackedStringArray()
static var _queries := PackedStringArray()


## Read once per authoring operation and only parse when the file content changes.
static func refresh() -> void:
	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null:
		_loaded = true
		_source = null
		_clear()
		_load_error = "Could not open the gameplay tag registry at %s." % PATH
		return
	var source := file.get_as_text()
	if _loaded and source == _source:
		return
	_loaded = true
	_source = source
	_clear()
	var json := JSON.new()
	if json.parse(source) != OK:
		_load_error = "Invalid JSON at %s:%d: %s" % [PATH, json.get_error_line(), json.get_error_message()]
		return
	var registry: Variant = json.data
	if not registry is Dictionary or registry.get("version") != 1 or not registry.get("tags") is Array:
		_load_error = "Expected version 1 and a tags array in %s." % PATH
		return

	var definitions: Dictionary[StringName, String] = {}
	var paths_by_case: Dictionary[String, String] = {}
	for index: int in registry.tags.size():
		var entry: Variant = registry.tags[index]
		if not entry is Dictionary or not entry.get("name") is String \
				or not entry.get("description", "") is String or not entry.get("code_owned", false) is bool:
			_load_error = "Invalid gameplay tag entry %d in %s." % [index + 1, PATH]
			return
		var name: String = entry.name
		if not is_valid_name(name):
			_load_error = "Invalid gameplay tag name '%s' in %s." % [name, PATH]
			return
		if definitions.has(StringName(name)):
			_load_error = "Duplicate gameplay tag '%s' in %s." % [name, PATH]
			return
		definitions[StringName(name)] = entry.get("description", "")
		var path := name
		while not path.is_empty():
			var lower := path.to_lower()
			var previous: String = paths_by_case.get(lower, "")
			if not previous.is_empty() and previous != path:
				_load_error = "Conflicting gameplay tag spellings '%s' and '%s' in %s." % [previous, path, PATH]
				return
			paths_by_case[lower] = path
			var separator := path.rfind(".")
			path = path.left(separator) if separator >= 0 else ""

	_descriptions = definitions
	for tag: StringName in _descriptions:
		_assignments.append(String(tag))
	for path: String in paths_by_case.values():
		_query_tags[StringName(path)] = true
		_queries.append(path)
	_assignments.sort()
	_queries.sort()


## Returns registered names, optionally including branches implied by their descendants.
static func get_choices(allow_implied: bool) -> PackedStringArray:
	_ensure_loaded()
	return _queries.duplicate() if allow_implied else _assignments.duplicate()


## Description saved on an explicit tag. Implied branches have no description.
static func get_description(tag: StringName) -> String:
	_ensure_loaded()
	return _descriptions.get(tag, "")


## Reports invalid or unreadable registry data to the authoring tool.
static func get_load_error() -> String:
	_ensure_loaded()
	return _load_error


## Checks a canonical spelling against the current in-memory registry.
static func contains(tag: StringName, allow_implied: bool) -> bool:
	_ensure_loaded()
	return _query_tags.has(tag) if allow_implied else _descriptions.has(tag)


## Dot-separated nonempty ASCII segments may contain letters, digits and underscores.
static func is_valid_name(tag: String) -> bool:
	for segment: String in tag.split("."):
		if segment.is_empty() or not ("_" + segment).is_valid_ascii_identifier():
			return false
	return true


## Classifies known tag fields for both the Godot Inspector and resource validation.
static func field_kind(object: Object, property: StringName, type: int) -> FieldKind:
	if type == TYPE_PACKED_STRING_ARRAY:
		match property:
			&"ability_tags", &"activation_tags", &"initial_tags", &"gameplay_cue_tags", &"granted_tags":
				return FieldKind.ASSIGNMENT
			&"asset_tags":
				if object is GameplayEffectDefinition:
					return FieldKind.ASSIGNMENT
				if object is AbilityDispelAction:
					return FieldKind.QUERY
			&"damage_tags":
				if object is GameplayEffectDefinition:
					return FieldKind.ASSIGNMENT
				if object is DamageDefenseEffectComponent or object is DamageRoutingEffectComponent:
					return FieldKind.QUERY
			&"required_tags", &"cancel_ability_tags", &"block_ability_tags", &"blocked_ability_tags", \
			&"required_context_tags", &"excluded_context_tags", &"required_ability_tags", &"excluded_ability_tags", \
			&"required_target_tags", &"blocked_target_tags", &"ongoing_required_target_tags", \
			&"ongoing_blocked_target_tags", &"required_owner_tags", &"blocked_owner_tags", &"immunity_tags", \
			&"activation_blockers", &"activation_exceptions", &"cancel_on_tags", &"effect_asset_tags", \
			&"blocked_asset_tags", &"required_asset_tags":
				return FieldKind.QUERY
	elif type == TYPE_STRING_NAME:
		match property:
			&"set_by_caller_tag", &"magnitude_tag", &"transaction_tag", &"entered_event", &"exited_event", \
			&"casting_cue":
				return FieldKind.ASSIGNMENT
			&"activation_event_tag", &"cue_tag":
				return FieldKind.QUERY
			&"tag":
				if object is AbilityConditionDefinition:
					return FieldKind.QUERY
			&"school":
				if object is AbilityInterruptionPolicy:
					return FieldKind.ASSIGNMENT
			&"event_key":
				if object is AbilityPhaseDefinition:
					return FieldKind.QUERY
	return FieldKind.NONE


static func _ensure_loaded() -> void:
	if not _loaded:
		refresh()


static func _clear() -> void:
	_load_error = ""
	_descriptions.clear()
	_query_tags.clear()
	_assignments.clear()
	_queries.clear()
