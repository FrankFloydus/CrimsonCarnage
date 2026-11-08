extends SceneTree
## Reports the project's exported authoring fields and their Godot types for the Qt editor.

const PREFIX := "ABILITY_EDITOR_SCHEMA "
const TEXTURES := ["png", "svg", "webp", "jpg", "jpeg", "bmp", "tga", "dds", "exr", "hdr", "ktx"]
const EXCLUDED := ["addons", "builds", "exports", "tests"]

var _class_paths: Dictionary[String, String] = {}
var _enum_descriptions: Dictionary[String, Dictionary] = {}


func _initialize() -> void:
	var classes := ProjectSettings.get_global_class_list()
	for entry: Dictionary in classes:
		_class_paths[entry.class] = entry.path
	var types := {}
	for entry: Dictionary in classes:
		var path: String = entry.path
		if not (path.begins_with("res://combat/") or path.begins_with("res://player/")):
			continue
		var script := load(path) as GDScript
		if script == null or not ClassDB.is_parent_class(script.get_instance_base_type(), &"Resource"):
			continue
		if script.is_abstract() or not script.can_instantiate():
			continue
		types[entry.class] = {"base": entry.base, "fields": _script_fields(script)}
	types["Curve"] = {"base": "Resource", "fields": _curve_fields()}
	var assets := {"PackedScene": [], "Texture2D": [], "Curve": []}
	_collect_assets("res://", assets)
	for paths: Array in assets.values():
		paths.sort()
	print(PREFIX + JSON.stringify({
		"types": types, "assets": assets, "lifecycle_events": AbilityPhaseDefinition.LIFECYCLE_EVENTS,
		"ability_cost_amount": {
			"unit": AbilityResourceCost.AMOUNT_UNIT,
			"sources": AbilityResourceCost.AMOUNT_SOURCES,
		},
	}))
	quit()


func _script_fields(script: GDScript) -> Array[Dictionary]:
	var instance := script.new() as Resource
	var descriptions := _descriptions(script)
	var inspector := {}
	for property: Dictionary in instance.get_property_list():
		inspector[property.name] = property
	var fields: Array[Dictionary] = []
	var group := "General"
	for property: Dictionary in script.get_script_property_list():
		var usage := int(property.usage)
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
			group = String(property.name) if not String(property.name).is_empty() else "General"
			continue
		if not usage & PROPERTY_USAGE_STORAGE or not usage & PROPERTY_USAGE_EDITOR:
			continue
		var field: String = property.name
		var hint: Dictionary = inspector.get(field, property)
		var tag_kind := GameplayTagRegistry.field_kind(instance, property.name, property.type)
		if instance is PhasedAbilityExecution and field == "release_event":
			tag_kind = GameplayTagRegistry.FieldKind.ASSIGNMENT
		fields.append({
			"key": field,
			"group": group,
			"type": type_string(property.type),
			"target": String(property.class_name) if property.type == TYPE_OBJECT else "",
			"hint": int(hint.hint),
			"hint_string": String(hint.hint_string),
			"tag_kind": int(tag_kind),
			"description": descriptions.get(field, ""),
			"choice_descriptions": _choice_descriptions(property),
			"default": _encode_default(instance.get(field)),
		})
	return fields


func _descriptions(script: GDScript) -> Dictionary:
	var inherited := script.get_base_script() as GDScript
	var descriptions := _descriptions(inherited) if inherited != null else {}
	var declaration := RegEx.create_from_string(r"^(?:@export[^\r\n]*?\s+)?var\s+([A-Za-z_]\w*)")
	var comments := PackedStringArray()
	for source_line: String in script.source_code.split("\n"):
		var line := source_line.strip_edges()
		if line.begins_with("##"):
			comments.append(line.trim_prefix("##").strip_edges())
			continue
		if not comments.is_empty():
			var result := declaration.search(line)
			if result != null:
				descriptions[result.get_string(1)] = " ".join(comments)
			elif line.begins_with("@export") and not " var " in line and not line.begins_with("@export_group"):
				continue
		comments.clear()
	return descriptions


func _choice_descriptions(property: Dictionary) -> Dictionary:
	if property.hint != PROPERTY_HINT_ENUM:
		return {}
	var qualified_name: String = property.class_name
	if _enum_descriptions.has(qualified_name):
		return _enum_descriptions[qualified_name]
	var descriptions := {}
	_enum_descriptions[qualified_name] = descriptions
	var parts := qualified_name.split(".")
	if parts.size() != 2 or not _class_paths.has(parts[0]):
		return descriptions
	var script := load(_class_paths[parts[0]]) as GDScript
	var constants: Variant = script.get_script_constant_map().get(parts[1])
	if not constants is Dictionary:
		return descriptions
	var declaration := RegEx.create_from_string(r"^([A-Za-z_]\w*)\s*[,=}]?")
	var comments := PackedStringArray()
	var in_enum := false
	for source_line: String in script.source_code.split("\n"):
		var line := source_line.strip_edges()
		if not in_enum:
			in_enum = line.begins_with("enum " + parts[1] + " ") or line.begins_with("enum " + parts[1] + "{")
			continue
		if line.begins_with("}"):
			break
		if line.begins_with("##"):
			comments.append(line.trim_prefix("##").strip_edges())
			continue
		var result := declaration.search(line)
		if result != null and not comments.is_empty() and constants.has(result.get_string(1)):
			var key := str(constants[result.get_string(1)])
			if not descriptions.has(key):
				descriptions[key] = " ".join(comments)
		comments.clear()
	return descriptions


func _encode_default(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return String(value)
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			var items := []
			for item: Variant in value:
				items.append(_encode_default(item))
			return items
		TYPE_DICTIONARY:
			var items := {}
			for key: Variant in value:
				items[String(key)] = _encode_default(value[key])
			return items
		TYPE_OBJECT:
			if value is Resource and not value.resource_path.is_empty():
				return {"$asset": value.resource_path}
			return null
	return {"$variant": JSON.from_native(value)}


func _curve_fields() -> Array[Dictionary]:
	return [
		{"key": "min_domain", "group": "Curve", "type": "float", "default": 0.0,
			"description": "Lowest supported curve input."},
		{"key": "max_domain", "group": "Curve", "type": "float", "default": 1.0,
			"description": "Highest supported curve input."},
		{"key": "min_value", "group": "Curve", "type": "float", "default": 0.0,
			"description": "Lower bound for curve point output values."},
		{"key": "max_value", "group": "Curve", "type": "float", "default": 1.0,
			"description": "Upper bound for curve point output values."},
		{"key": "bake_resolution", "group": "Curve", "type": "int", "default": 100,
			"hint": 1, "hint_string": "1,1000,1", "description": "Number of samples cached by Godot."},
		{"key": "points", "group": "Curve", "type": "CurvePoints", "default": [],
			"description": "Curve control points and interpolation tangents."},
	]


func _collect_assets(path: String, assets: Dictionary) -> void:
	if FileAccess.file_exists(path.path_join(".gdignore")):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for folder: String in directory.get_directories():
		if not folder.begins_with(".") and not directory.is_link(folder):
			if path != "res://" or folder not in EXCLUDED:
				_collect_assets(path.path_join(folder), assets)
	for filename: String in directory.get_files():
		if filename.begins_with(".") or directory.is_link(filename):
			continue
		var asset := path.path_join(filename)
		var extension := filename.get_extension().to_lower()
		if extension in ["tscn", "scn"] and ResourceLoader.exists(asset, "PackedScene"):
			assets.PackedScene.append(asset)
		elif extension in TEXTURES and ResourceLoader.exists(asset, "Texture2D"):
			assets.Texture2D.append(asset)
		elif extension in ["tres", "res"] and ResourceLoader.exists(asset):
			var resource := load(asset) as Resource
			if resource is Curve:
				assets.Curve.append(asset)
			elif resource is Texture2D:
				assets.Texture2D.append(asset)
