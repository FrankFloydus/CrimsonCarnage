extends RefCounted
## Builds native ability and effect definitions from the project-owned JSON graph.

const FORMAT := "godot_combat_definition"
const VERSION := 1
const ABILITY_SUFFIX := ".ability.json"
const EFFECT_SUFFIX := ".effect.json"
const SOURCE_PATH := &"_combat_definition_source_path"
const MAX_INTEGER := 9007199254740991

static var _runtime_cache: Dictionary[String, Resource] = {}
static var _class_paths: Dictionary[String, String] = {}

var _error := ""
var _path_cache: Dictionary[String, Resource] = {}
var _loading_paths: Dictionary[String, bool] = {}
var _overrides: Dictionary = {}


## Checks only the reserved suffixes, leaving other project JSON files to their owners.
static func is_definition_path(path: String) -> bool:
	return path.ends_with(ABILITY_SUFFIX) or path.ends_with(EFFECT_SUFFIX)


## Returns the physical JSON source for a loaded root, or the engine path for native assets.
static func source_path(resource: Resource) -> String:
	return String(resource.get_meta(SOURCE_PATH, resource.resource_path))


## Caches shared authored definitions for the lifetime of a game run.
static func load_definition(path: String) -> Resource:
	var reader := new()
	if not Engine.is_editor_hint():
		reader._path_cache = _runtime_cache
	var definition := reader._load_path(path)
	if definition == null:
		push_error(reader._error)
	return definition


## Resolves a gameplay input binding to its authored ID, or zero when its JSON cannot be loaded.
static func load_ability_id(path: String) -> int:
	var definition := load_definition(path) as AbilityDefinition
	return definition.ability_id if definition != null else 0


## Reads a fresh definition for authoring checks without reusing a gameplay cache.
static func read_definition(path: String) -> Dictionary:
	var reader := new()
	var definition := reader._load_path(path)
	return {"definition": definition, "error": reader._error}


## Reads multiple roots in one session so shared references remain the same native object.
static func read_definitions(paths: PackedStringArray, overrides: Dictionary = {}) -> Dictionary:
	var reader := new()
	reader._overrides = overrides
	var definitions: Array[Resource] = []
	var issues: Array[String] = []
	for path: String in paths:
		reader._error = ""
		var definition := reader._load_path(path)
		if definition == null:
			issues.append(reader._error)
		else:
			definitions.append(definition)
	return {"definitions": definitions, "issues": issues}


## Checks an unsaved document and optional replacements without modifying project files.
static func decode_document(document: Dictionary, path: String = "", overrides: Dictionary = {}) -> Dictionary:
	var reader := new()
	reader._overrides = overrides
	if not path.is_empty():
		reader._loading_paths[path] = true
	var definition := reader._decode(document, path)
	return {"definition": definition, "error": reader._error}


## Instantiates a known project Resource type for decoding or schema inspection.
static func make_resource(type: String) -> Resource:
	if type == "Curve":
		return Curve.new()
	if _class_paths.is_empty():
		for entry: Dictionary in ProjectSettings.get_global_class_list():
			var path: String = entry["path"]
			if path.begins_with("res://combat/") or path.begins_with("res://player/"):
				_class_paths[entry["class"]] = path
	if not _class_paths.has(type):
		return null
	var script := ResourceLoader.load(_class_paths[type], "Script") as Script
	if script == null or not ClassDB.is_parent_class(script.get_instance_base_type(), &"Resource") \
			or not script.can_instantiate():
		return null
	return script.new() as Resource


func _load_path(path: String) -> Resource:
	if not _valid_asset_path(path) or not is_definition_path(path):
		return _fail("Expected a project ability or effect JSON path, got %s." % path)
	if _path_cache.has(path):
		return _path_cache[path]
	if _loading_paths.has(path):
		return _fail("Cyclic combat definition reference to %s." % path)
	_loading_paths[path] = true
	var definition: Resource
	if _overrides.has(path):
		definition = _decode(_overrides[path], path)
	elif not FileAccess.file_exists(path):
		_fail("Combat definition file is missing: %s." % path)
	else:
		var parser := JSON.new()
		if parser.parse(FileAccess.get_file_as_string(path)) != OK:
			_fail("%s:%d: %s" % [path, parser.get_error_line(), parser.get_error_message()])
		else:
			definition = _decode(parser.data, path)
	_loading_paths.erase(path)
	if definition != null:
		_path_cache[path] = definition
	return definition


func _decode(document: Variant, path: String) -> Resource:
	if not document is Dictionary or document.get("format") != FORMAT or document.get("version") != VERSION:
		return _fail("Expected combat definition JSON version %d at %s." % [VERSION, path])
	if not document.get("uid") is String or ResourceUID.text_to_id(document["uid"]) == ResourceUID.INVALID_ID:
		return _fail("Combat definition %s requires a valid UID." % path)
	var nodes: Variant = document.get("resources")
	var root: Variant = document.get("root")
	if not nodes is Dictionary or not root is String or not nodes.has(root):
		return _fail("Combat definition %s has no root resource." % path)
	var graph := {"nodes": nodes, "built": {}, "active": {}}
	var definition := _build_node(root, graph)
	if definition == null:
		if not path.is_empty():
			_error = "%s: %s" % [path, _error]
		return null
	if not (definition is AbilityDefinition or definition is GameplayEffectDefinition) \
			or (path.ends_with(ABILITY_SUFFIX) and not definition is AbilityDefinition) \
			or (path.ends_with(EFFECT_SUFFIX) and not definition is GameplayEffectDefinition):
		return _fail("The root resource does not match the combat definition at %s." % path)
	if graph["built"].size() != nodes.size():
		return _fail("Combat definition %s contains unreferenced resource nodes." % path)
	if not path.is_empty():
		definition.set_meta(SOURCE_PATH, path)
	return definition


func _build_node(key: String, graph: Dictionary) -> Resource:
	if graph["built"].has(key):
		return graph["built"][key]
	if graph["active"].has(key):
		return _fail("Cyclic resource reference to %s." % key)
	var node: Variant = graph["nodes"].get(key)
	if not node is Dictionary or not node.get("type") is String or not node.get("properties") is Dictionary:
		return _fail("Invalid resource node %s." % key)
	var result := make_resource(node["type"])
	if result == null:
		return _fail("Unknown combat resource type '%s' at %s." % [node["type"], key])
	graph["active"][key] = true
	var fields: Dictionary = node["properties"]
	if result is Curve:
		_build_curve(result, fields, key)
	else:
		var properties := _stored_properties(result)
		for name: String in fields:
			if not properties.has(name):
				return _fail("Unknown stored field %s.%s." % [key, name])
			var info: Dictionary = properties[name]
			var value: Variant = _decode_value(fields[name], graph, "%s.%s" % [key, name],
					int(info["type"]), StringName(info["class_name"]), result.get(name))
			if not _error.is_empty():
				return null
			result.set(name, value)
	if not _error.is_empty():
		return null
	graph["active"].erase(key)
	graph["built"][key] = result
	return result


func _decode_value(
		raw: Variant, graph: Dictionary, location: String, expected: int = TYPE_NIL,
		class_type: StringName = &"", default: Variant = null
) -> Variant:
	if expected == TYPE_ARRAY:
		return _decode_array(raw, graph, location, default)
	if expected >= TYPE_PACKED_BYTE_ARRAY and expected <= TYPE_PACKED_VECTOR4_ARRAY:
		return _decode_packed(raw, graph, location, expected)
	if raw is Dictionary:
		var value: Variant = _decode_object(raw, graph, location)
		if not _error.is_empty():
			return null
		if expected == TYPE_OBJECT:
			if value is Resource and _matches_class(value, class_type):
				return value
			return _fail("Expected a %s resource at %s." % [class_type, location])
		if expected == TYPE_NIL or typeof(value) == expected:
			return value
		return _fail("Invalid type for %s." % location)
	if expected == TYPE_STRING_NAME and raw is String:
		return StringName(raw)
	if expected == TYPE_NODE_PATH and raw is String:
		return NodePath(raw)
	if expected == TYPE_INT:
		return int(raw) if _valid_integer(raw) else _fail("Invalid integer at %s." % location)
	if expected == TYPE_FLOAT:
		return float(raw) if _finite_number(raw) else _fail("Invalid number at %s." % location)
	if (expected == TYPE_OBJECT and raw == null) or expected == typeof(raw):
		return raw
	if expected == TYPE_NIL:
		return _decode_array(raw, graph, location, []) if raw is Array else raw
	return _fail("Invalid value for %s." % location)


func _decode_object(raw: Dictionary, graph: Dictionary, location: String) -> Variant:
	if raw.has("$resource"):
		return _build_node(raw["$resource"], graph) if raw["$resource"] is String \
				else _fail("Invalid resource reference at %s." % location)
	if raw.has("$asset"):
		var path: Variant = raw["$asset"]
		if not path is String or not _valid_asset_path(path):
			return _fail("Invalid project asset at %s." % location)
		if is_definition_path(path):
			return _load_path(path)
		if not ResourceLoader.exists(path):
			var uid: Variant = raw.get("uid")
			var id := ResourceUID.text_to_id(uid) if uid is String else ResourceUID.INVALID_ID
			if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
				path = ResourceUID.get_id_path(id)
		if not _valid_asset_path(path) or not ResourceLoader.exists(path):
			return _fail("Missing project asset %s at %s." % [path, location])
		var asset := ResourceLoader.load(path)
		if asset == null or asset is Script or asset is AbilityDefinition or asset is GameplayEffectDefinition:
			return _fail("Invalid project asset %s at %s." % [path, location])
		return asset
	if raw.has("$variant"):
		var value: Variant = JSON.to_native(raw["$variant"])
		if value == null:
			return _fail("Invalid Godot value at %s." % location)
		return value
	var result := {}
	for key: String in raw:
		result[key] = _decode_value(raw[key], graph, "%s.%s" % [location, key])
	return result


func _decode_array(raw: Variant, graph: Dictionary, location: String, default: Variant) -> Variant:
	if not raw is Array:
		return _fail("Expected an array at %s." % location)
	var template: Array = default if default is Array else []
	var type := template.get_typed_builtin()
	var class_type := template.get_typed_class_name()
	var script: Variant = template.get_typed_script()
	if script is Script:
		class_type = script.get_global_name()
	var result := Array([], type, template.get_typed_class_name(), script)
	for index: int in raw.size():
		var value: Variant = _decode_value(raw[index], graph, "%s[%d]" % [location, index], type, class_type)
		if not _error.is_empty():
			return null
		result.append(value)
	return result


func _decode_packed(raw: Variant, graph: Dictionary, location: String, expected: int) -> Variant:
	var types := {
		TYPE_PACKED_BYTE_ARRAY: TYPE_INT, TYPE_PACKED_INT32_ARRAY: TYPE_INT, TYPE_PACKED_INT64_ARRAY: TYPE_INT,
		TYPE_PACKED_FLOAT32_ARRAY: TYPE_FLOAT, TYPE_PACKED_FLOAT64_ARRAY: TYPE_FLOAT, TYPE_PACKED_STRING_ARRAY: TYPE_STRING,
		TYPE_PACKED_VECTOR2_ARRAY: TYPE_VECTOR2, TYPE_PACKED_VECTOR3_ARRAY: TYPE_VECTOR3,
		TYPE_PACKED_COLOR_ARRAY: TYPE_COLOR, TYPE_PACKED_VECTOR4_ARRAY: TYPE_VECTOR4,
	}
	if not raw is Array:
		return _fail("Expected an array at %s." % location)
	var values: Array = []
	for index: int in raw.size():
		values.append(_decode_value(raw[index], graph, "%s[%d]" % [location, index], types[expected]))
		if not _error.is_empty():
			return null
	return type_convert(values, expected)


func _build_curve(curve: Curve, fields: Dictionary, key: String) -> void:
	var defaults := {
		"min_domain": curve.min_domain, "max_domain": curve.max_domain,
		"min_value": curve.min_value, "max_value": curve.max_value, "bake_resolution": curve.bake_resolution,
		"points": [], "resource_name": curve.resource_name, "resource_local_to_scene": curve.resource_local_to_scene,
	}
	for field: String in fields:
		if not defaults.has(field):
			_fail("Unknown Curve field %s.%s." % [key, field])
			return
	defaults.merge(fields, true)
	for field: String in ["min_domain", "max_domain", "min_value", "max_value"]:
		if not _finite_number(defaults[field]):
			_fail("Invalid Curve limit %s.%s." % [key, field])
			return
	if defaults["max_domain"] <= defaults["min_domain"] or defaults["max_value"] <= defaults["min_value"] \
			or not _valid_integer(defaults["bake_resolution"]) or defaults["bake_resolution"] < 1 \
			or defaults["bake_resolution"] > 1000 or not defaults["points"] is Array \
			or not defaults["resource_name"] is String or not defaults["resource_local_to_scene"] is bool:
		_fail("Invalid Curve settings at %s." % key)
		return
	curve.set("_limits", [float(defaults["min_value"]), float(defaults["max_value"]),
		float(defaults["min_domain"]), float(defaults["max_domain"])])
	curve.bake_resolution = int(defaults["bake_resolution"])
	curve.resource_name = defaults["resource_name"]
	curve.resource_local_to_scene = defaults["resource_local_to_scene"]
	var previous := -INF
	for point: Variant in defaults["points"]:
		if not point is Dictionary or not _finite_number(point.get("x")) or not _finite_number(point.get("y")) \
				or not _finite_number(point.get("left_tangent", 0.0)) or not _finite_number(point.get("right_tangent", 0.0)) \
				or point.get("left_mode", 0) not in [0, 1] or point.get("right_mode", 0) not in [0, 1] \
				or point["x"] < previous or point["x"] < curve.min_domain or point["x"] > curve.max_domain \
				or point["y"] < curve.min_value or point["y"] > curve.max_value:
			_fail("Invalid or unordered Curve point at %s." % key)
			return
		curve.add_point(Vector2(point["x"], point["y"]), point.get("left_tangent", 0.0),
				point.get("right_tangent", 0.0), int(point.get("left_mode", 0)), int(point.get("right_mode", 0)))
		previous = float(point["x"])


func _fail(message: String) -> Resource:
	if _error.is_empty():
		_error = message
	return null


static func _stored_properties(resource: Resource) -> Dictionary:
	var properties := {}
	for info: Dictionary in resource.get_property_list():
		var usage := int(info["usage"])
		var name := String(info["name"])
		if usage & PROPERTY_USAGE_STORAGE and (usage & PROPERTY_USAGE_SCRIPT_VARIABLE \
				or name in ["resource_name", "resource_local_to_scene"]):
			properties[name] = info
	return properties


static func _matches_class(resource: Resource, expected: StringName) -> bool:
	if expected.is_empty() or resource.is_class(expected):
		return true
	var script := resource.get_script() as Script
	while script != null:
		if script.get_global_name() == expected:
			return true
		script = script.get_base_script()
	return false


static func _valid_asset_path(path: String) -> bool:
	return path.begins_with("res://") and path.length() > 6 and path.simplify_path() == path \
			and not "\\" in path and not ":" in path.trim_prefix("res://")


static func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _valid_integer(value: Variant) -> bool:
	return _finite_number(value) and absf(float(value)) <= MAX_INTEGER and float(value) == floorf(float(value))
