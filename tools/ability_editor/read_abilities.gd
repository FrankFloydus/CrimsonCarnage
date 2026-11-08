extends SceneTree
## Reads definitions, checks deletion references and evaluates tuning previews without starting the game.

const CATALOG_PREFIX := "ABILITY_EDITOR_CATALOG "
const DELETE_CHECK_PREFIX := "ABILITY_EDITOR_DELETE_CHECK "
const ATTRIBUTE_DELETE_PREFIX := "ABILITY_EDITOR_ATTRIBUTE_DELETE "
const ACCURACY_PREVIEW_PREFIX := "ABILITY_EDITOR_ACCURACY_PREVIEW "
const ProjectFiles := preload("res://tools/ability_editor/ability_editor_files.gd")
const PACKED_RESOURCE_EXTENSIONS := ["res", "tres", "scn", "tscn"]
const DEPENDENCY_EXTENSIONS := ["res", "tres", "scn", "tscn", "gd", "cs", "godot"]
# Script loaders do not report all literal references. Include quoted path constants.
const SOURCE_PATH_PATTERN := r"""(?i)"((?:uid://[^"\r\n]+|[^"\r\n]+\.(?:tres|res)))"|'((?:uid://[^'\r\n]+|[^'\r\n]+\.(?:tres|res)))'"""
const THUMBNAIL_MAX_SIZE := 48


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if not arguments.is_empty():
		match arguments[0]:
			"--check-delete":
				print(DELETE_CHECK_PREFIX + JSON.stringify(_check_delete(arguments.slice(1))))
			"--check-attribute-delete":
				print(ATTRIBUTE_DELETE_PREFIX + JSON.stringify(_check_attribute_delete(arguments.slice(1))))
			"--preview-accuracy":
				print(ACCURACY_PREVIEW_PREFIX + JSON.stringify(_preview_accuracy(arguments.slice(1))))
			_:
				push_error("Unknown ability editor command: %s" % arguments[0])
				quit(1)
				return
		quit()
		return

	var paths: Array[String] = []
	var warnings: Array[String] = []
	ProjectFiles.collect("res://", paths, warnings)
	paths.sort()
	var abilities: Array[Dictionary] = []
	var effects: Array[Dictionary] = []
	var definitions: Array[Resource] = []
	for path: String in paths:
		if not ProjectFiles.has_script_dependency(path):
			continue
		var resource := ResourceLoader.load(path)
		if resource == null:
			warnings.append("Could not load %s." % path)
			continue
		if resource is AbilityDefinition:
			var ability := resource as AbilityDefinition
			definitions.append(ability)
			abilities.append(_make_entry(
				ability.ability_id, ability.display_name, ability.ability_tags,
				ability.icon, path, warnings
			))
		elif resource is GameplayEffectDefinition:
			var effect := resource as GameplayEffectDefinition
			definitions.append(effect)
			effects.append(_make_entry(
				effect.effect_id, effect.display_name, effect.asset_tags,
				effect.icon, path, warnings
			))
	warnings.append_array(CombatResourceValidator.validate_catalog(definitions))
	var attribute_error := CombatAttributes.registry_error()
	if not attribute_error.is_empty():
		warnings.append(attribute_error)
	var assets := ProjectFiles.composer_assets(warnings)
	print(CATALOG_PREFIX + JSON.stringify({
		"abilities": abilities,
		"effects": effects,
		"assets": assets,
		"warnings": warnings,
	}))
	quit()


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
	for path: String in paths:
		var resource := ResourceLoader.load(path)
		if resource == null:
			issues.append("Could not check attribute references in %s." % path)
			continue
		_find_attribute_references(resource, attribute_id, path, {}, issues)
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


func _check_delete(selection: PackedStringArray) -> Dictionary:
	var paths: Array[String] = []
	var issues: Array[String] = []
	ProjectFiles.collect("res://", paths, issues, DEPENDENCY_EXTENSIONS, ProjectFiles.AUTHORING_IGNORED)
	var targets: Dictionary[String, String] = {}
	var referrers: Dictionary[String, Array] = {}
	if selection.is_empty():
		issues.append("Choose at least one saved definition.")
	for path: String in selection:
		if not path.begins_with("res://") or not ProjectFiles.DEFINITION_EXTENSIONS.has(path.get_extension().to_lower()) \
				or not paths.has(path):
			issues.append("Definition is missing or outside the project scan: %s" % path)
			continue
		if referrers.has(path):
			issues.append("Definition selected more than once: %s" % path)
			continue
		var resource := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if not (resource is AbilityDefinition or resource is GameplayEffectDefinition):
			issues.append("Expected a saved ability or effect at %s." % path)
			continue
		targets[_path_key(path)] = path
		referrers[path] = []
		var uid := ResourceLoader.get_resource_uid(path)
		if uid != ResourceUID.INVALID_ID:
			var uid_text := ResourceUID.id_to_text(uid)
			if targets.has(uid_text):
				issues.append("%s and %s share a resource UID." % [path, targets[uid_text]])
			targets[uid_text] = path
	if not issues.is_empty():
		return {"paths": [], "issues": issues}

	var source_paths := RegEx.create_from_string(SOURCE_PATH_PATTERN)
	for path: String in paths:
		for reference: String in _read_references(path, source_paths, issues):
			for key: String in _reference_keys(reference, path):
				var target := targets.get(key, "") as String
				if target.is_empty():
					continue
				var owners: Array = referrers[target]
				if not owners.has(path):
					owners.append(path)
	for target: String in selection:
		for owner: String in referrers[target]:
			if not referrers.has(owner):
				issues.append("%s is referenced by %s." % [target, owner])
	if not issues.is_empty():
		return {"paths": [], "issues": issues}

	# Move dependents first. Stopping after a failed move then leaves remaining links intact.
	var order: Array[String] = []
	while order.size() < selection.size():
		var previous_count := order.size()
		for path: String in selection:
			if order.has(path):
				continue
			if referrers[path].all(func(owner: String) -> bool: return order.has(owner)):
				order.append(path)
		if order.size() == previous_count:
			return {"paths": [], "issues": ["The selected definitions reference each other in a cycle."]}
	return {"paths": order, "issues": []}


func _read_references(path: String, source_paths: RegEx, issues: Array[String]) -> Array[String]:
	var references: Array[String] = []
	if path.get_extension().to_lower() in PACKED_RESOURCE_EXTENSIONS:
		for dependency: String in ResourceLoader.get_dependencies(path):
			references.append(dependency.get_slice("::", 0))
			var fallback := dependency.get_slice("::", 2)
			if not fallback.is_empty():
				references.append(fallback)
		return references

	var source := FileAccess.open(path, FileAccess.READ)
	if source == null:
		issues.append("Could not read %s for references." % path)
		return references
	for result: RegExMatch in source_paths.search_all(source.get_as_text()):
		var reference := result.get_string(1)
		if reference.is_empty():
			reference = result.get_string(2)
		references.append(reference.c_unescape())
	return references


func _reference_keys(reference: String, owner: String) -> Array[String]:
	if reference.begins_with("uid://"):
		var uid := ResourceUID.text_to_id(reference)
		if ResourceUID.has_id(uid):
			return [reference, _path_key(ResourceUID.get_id_path(uid))]
		return [reference]
	var path := reference.replace("\\", "/")
	if path.is_relative_path():
		return [_path_key(owner.get_base_dir().path_join(path)), _path_key("res://".path_join(path))]
	return [_path_key(ProjectSettings.localize_path(path))]


func _path_key(path: String) -> String:
	var simplified := path.simplify_path()
	return simplified.to_lower() if OS.has_feature("windows") else simplified


func _make_entry(
	id: int,
	display_name: String,
	tags: PackedStringArray,
	icon: Texture2D,
	path: String,
	warnings: Array[String]
) -> Dictionary:
	var icon_png := _get_icon_png(icon)
	if icon != null and icon_png.is_empty():
		warnings.append("Could not make an icon thumbnail for %s." % path)
	return {
		"id": id,
		"name": display_name,
		"tags": Array(tags),
		"icon_png": icon_png,
		"path": path,
	}


func _get_icon_png(icon: Texture2D) -> String:
	if icon == null:
		return ""
	var image := icon.get_image()
	if image == null or image.is_empty():
		return ""
	# The headless renderer may return its stored image directly.
	var thumbnail := image.duplicate() as Image
	if thumbnail.is_compressed() and thumbnail.decompress() != OK:
		return ""
	var largest_side := maxi(thumbnail.get_width(), thumbnail.get_height())
	if largest_side > THUMBNAIL_MAX_SIZE:
		var scale_factor := float(THUMBNAIL_MAX_SIZE) / largest_side
		var width := maxi(1, roundi(thumbnail.get_width() * scale_factor))
		var height := maxi(1, roundi(thumbnail.get_height() * scale_factor))
		thumbnail.resize(width, height, Image.INTERPOLATE_LANCZOS)
	return Marshalls.raw_to_base64(thumbnail.save_png_to_buffer())
