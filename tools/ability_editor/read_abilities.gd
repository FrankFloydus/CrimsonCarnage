extends SceneTree
## Runs native validation and previews for JSON authoring without starting the game.

const ATTRIBUTE_DELETE_PREFIX := "ABILITY_EDITOR_ATTRIBUTE_DELETE "
const ACCURACY_PREVIEW_PREFIX := "ABILITY_EDITOR_ACCURACY_PREVIEW "
const VALIDATION_PREFIX := "ABILITY_EDITOR_VALIDATE "
const ProjectFiles := preload("res://tools/ability_editor/ability_editor_files.gd")
const CombatJson := preload("res://combat/abilities/combat_definition_json.gd")
const PACKED_RESOURCE_EXTENSIONS := ["res", "tres", "scn", "tscn", "json"]


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.is_empty():
		push_error("Choose an ability editor command.")
		quit(1)
		return
	match arguments[0]:
		"--check-attribute-delete":
			print(ATTRIBUTE_DELETE_PREFIX + JSON.stringify(_check_attribute_delete(arguments.slice(1))))
		"--preview-accuracy":
			print(ACCURACY_PREVIEW_PREFIX + JSON.stringify(_preview_accuracy(arguments.slice(1))))
		"--validate-definition":
			print(VALIDATION_PREFIX + JSON.stringify(_validate_definition(arguments.slice(1))))
		_:
			push_error("Unknown ability editor command: %s" % arguments[0])
			quit(1)
			return
	quit()


func _validate_definition(arguments: PackedStringArray) -> Dictionary:
	if arguments.is_empty() or arguments.size() > 2:
		return {"issues": ["Expected a draft JSON file and optional project path."]}
	var file := FileAccess.open(arguments[0], FileAccess.READ)
	if file == null:
		return {"issues": ["Could not read the draft JSON file."]}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return {"issues": ["The draft must be a JSON object."]}
	var path := arguments[1] if arguments.size() == 2 else ""
	var result := CombatJson.decode_document(parsed, path)
	if result.definition == null:
		return {"issues": [result.error]}
	var issues := CombatResourceValidator.validate_definitions([result.definition])
	for issue: String in CombatResourceValidator.validate_catalog([result.definition]):
		if issue not in issues:
			issues.append(issue)
	return {"issues": issues}


func _preview_accuracy(arguments: PackedStringArray) -> Dictionary:
	var count := int(CombatRules.get_number("accuracy_curve_max_gap")) + 1
	if arguments.size() != 3 or not arguments[0].is_valid_int():
		return {"error": "Expected a level gap and two percentage arrays."}
	var gap := arguments[0].to_int()
	var base: Variant = JSON.parse_string(arguments[1])
	var ceiling: Variant = JSON.parse_string(arguments[2])
	if gap < 0 or gap >= count or not base is Array or not ceiling is Array \
			or base.size() != count or ceiling.size() != count:
		return {"error": "The draft Accuracy curve does not match the saved level gaps."}
	var draft := {"base": [], "ceiling": []}
	for index in range(count):
		if not _is_percentage(base[index]) or not _is_percentage(ceiling[index]) \
				or float(base[index]) > float(ceiling[index]):
			return {"error": "Expected 0 <= base chance <= ceiling <= 100 at gap +%d." % index}
		draft["base"].append(float(base[index]) / 100.0)
		draft["ceiling"].append(float(ceiling[index]) / 100.0)
	var details := CombatMath.get_hit_chance_details(50, 50 + gap, 69.0, draft)
	return {"chance": details["hit_chance"]}


func _is_percentage(value: Variant) -> bool:
	return typeof(value) in [TYPE_FLOAT, TYPE_INT] and is_finite(float(value)) \
			and float(value) >= 0.0 and float(value) <= 100.0


func _check_attribute_delete(arguments: PackedStringArray) -> Dictionary:
	var issues: Array[String] = []
	var attribute_id := -1
	if arguments.size() == 1 and arguments[0].is_valid_int():
		attribute_id = arguments[0].to_int()
	if attribute_id < 100 or not CombatAttributes.is_active(attribute_id):
		return {"id": attribute_id, "issues": ["Select an active custom attribute."]}
	var paths: Array[String] = []
	ProjectFiles.collect("res://", paths, issues, PACKED_RESOURCE_EXTENSIONS, ProjectFiles.AUTHORING_IGNORED)
	paths.sort()
	var json_paths := PackedStringArray()
	for path: String in paths:
		if path.ends_with(".json"):
			if CombatJson.is_definition_path(path):
				json_paths.append(path)
			continue
		var resource := ResourceLoader.load(path)
		if resource == null:
			issues.append("Could not check attribute references in %s." % path)
			continue
		_find_attribute_references(resource, attribute_id, path, {}, issues)
	var authored := CombatJson.read_definitions(json_paths)
	issues.append_array(authored.issues)
	for definition: Resource in authored.definitions:
		_find_attribute_references(definition, attribute_id, CombatJson.source_path(definition), {}, issues)
	return {"id": attribute_id, "issues": issues}


func _find_attribute_references(
		value: Variant, attribute_id: int, path: String, visited: Dictionary, issues: Array[String]
) -> void:
	if value is Array:
		for index in range(value.size()):
			_find_attribute_references(value[index], attribute_id, "%s[%d]" % [path, index], visited, issues)
		return
	if value is Dictionary:
		for key: Variant in value:
			_find_attribute_references(value[key], attribute_id, "%s[%s]" % [path, key], visited, issues)
		return
	if not value is Resource or value is Script or visited.has(value.get_instance_id()):
		return
	visited[value.get_instance_id()] = true
	if value is PackedScene:
		var state: SceneState = value.get_state()
		for node_index in range(state.get_node_count()):
			for property_index in range(state.get_node_property_count(node_index)):
				var property_path := "%s:%s.%s" % [
					path, state.get_node_path(node_index), state.get_node_property_name(node_index, property_index),
				]
				_find_attribute_references(state.get_node_property_value(node_index, property_index),
						attribute_id, property_path, visited, issues)
		for connection_index in range(state.get_connection_count()):
			_find_attribute_references(state.get_connection_binds(connection_index), attribute_id,
					"%s:connection[%d]" % [path, connection_index], visited, issues)
		return
	for property: Dictionary in value.get_property_list():
		if not int(property["usage"]) & PROPERTY_USAGE_STORAGE:
			continue
		var name: StringName = property["name"]
		var child: Variant = value.get(name)
		if typeof(child) == TYPE_INT and child == attribute_id and _is_attribute_reference(value, name):
			issues.append("%s.%s refers to attribute %d." % [path, name, attribute_id])
		elif child is Resource or child is Array or child is Dictionary:
			_find_attribute_references(child, attribute_id, "%s.%s" % [path, name], visited, issues)


func _is_attribute_reference(resource: Resource, property: StringName) -> bool:
	if resource is AttributeModifier:
		return property in [&"attribute", &"capture_attribute"]
	if resource is AttributeGameplayEventRule:
		return property in [&"attribute", &"threshold_attribute"]
	if resource is AmountDefinition:
		return property == &"stat"
	if resource is DamageResistanceStage:
		return property == &"attribute"
	if resource is StatusProfile:
		return property == &"resistance_attribute"
	return resource is AbilityConditionDefinition and property == &"resource"
