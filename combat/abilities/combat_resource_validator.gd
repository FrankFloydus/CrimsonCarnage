class_name CombatResourceValidator
extends RefCounted
## Validates saved abilities and effects as a collection, including their shared resources.

var _issues: Array[String] = []
var _active: Dictionary[int, String] = {}
var _visited: Dictionary[Resource, bool] = {}
var _file_dependencies: Dictionary[String, bool] = {}
var _ability_ids: Dictionary[StringName, String] = {}
var _effect_ids: Dictionary[StringName, String] = {}


## Loads combat resources at explicit res:// paths and returns problems in traversal order.
static func validate_paths(paths: PackedStringArray) -> Array[String]:
	var validator := CombatResourceValidator.new()
	for path: String in paths:
		validator._check_dependencies(path)
		var definition := ResourceLoader.load(path) if ResourceLoader.exists(path) else null
		if definition is AbilityDefinition or definition is GameplayEffectDefinition:
			validator._visit(definition, path)
		else:
			validator._add_issue(path, "Expected an AbilityDefinition or GameplayEffectDefinition.")
	return validator._issues


## Validates in-memory authoring before saving. Shared definitions are checked once.
static func validate_definitions(definitions: Array[Resource]) -> Array[String]:
	var validator := CombatResourceValidator.new()
	for index: int in definitions.size():
		var definition := definitions[index]
		var location := "definitions[%d]" % index
		if definition is AbilityDefinition or definition is GameplayEffectDefinition:
			validator._visit(definition, location)
		else:
			validator._add_issue(location, "Expected an AbilityDefinition or GameplayEffectDefinition.")
	return validator._issues


func _visit(definition: Resource, location: String) -> void:
	var instance_id := definition.get_instance_id()
	if _active.has(instance_id):
		_add_issue(location, "Cyclic resource reference to %s." % _active[instance_id])
		return
	if _visited.has(definition):
		return
	_active[instance_id] = location
	_visited[definition] = true
	_check_definition(definition, location)
	for property: Dictionary in definition.get_property_list():
		var usage := int(property.usage)
		if (usage & PROPERTY_USAGE_EDITOR) == 0 or (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var name := String(property.name)
		var value: Variant = definition.get(name)
		var field := "%s.%s" % [location, name]
		if value is Resource:
			_visit(value, field)
		elif value is Array:
			for index: int in value.size():
				if value[index] is Resource:
					_visit(value[index], "%s[%d]" % [field, index])
		elif value is PackedStringArray and name.ends_with("_tags"):
			for index: int in value.size():
				_check_tag(value[index], "%s[%d]" % [field, index])
		elif value is StringName and name.ends_with("_tag") and not value.is_empty():
			_check_tag(value, field)
	_active.erase(instance_id)


func _check_definition(definition: Resource, location: String) -> void:
	var failure: StringName
	if definition is AbilityDefinition:
		var ability := definition as AbilityDefinition
		_check_id(ability.ability_id, location, _ability_ids, "ability")
		failure = ability.get_validation_error()
	elif definition is GameplayEffectDefinition:
		var effect := definition as GameplayEffectDefinition
		_check_id(effect.effect_id, location, _effect_ids, "effect")
		failure = effect.get_validation_error()
		if effect.timing == GameplayEffectDefinition.Timing.DURATION and effect.duration <= 0.0:
			_add_issue(location + ".duration", "A timed effect needs a positive duration in seconds.")
	elif definition is AmountDefinition:
		failure = definition.get_validation_error()
	elif definition is StatusProfile:
		failure = definition.get_validation_error()
	elif definition is ReactionDefinition:
		failure = definition.get_validation_error()
	elif definition is PhasedAbilityExecution:
		failure = definition.get_authoring_error()
	elif definition is PackedScene and not definition.can_instantiate():
		_add_issue(location, "The packed scene has no root to instantiate.")
	if not failure.is_empty():
		_add_issue(location, String(failure))


func _check_id(
		id: StringName,
		location: String,
		ids: Dictionary[StringName, String],
		kind: String
) -> void:
	if id.is_empty():
		_add_issue(location, "Missing %s ID." % kind)
	elif ids.has(id):
		_add_issue(location, "Duplicate %s ID '%s' (also at %s)." % [kind, id, ids[id]])
	else:
		ids[id] = location


func _check_tag(tag: String, location: String) -> void:
	for part: String in tag.split("."):
		if part.is_empty() or not ("_" + part).is_valid_ascii_identifier():
			_add_issue(location, "Invalid hierarchical tag '%s'." % tag)
			return


func _check_dependencies(path: String) -> void:
	if _file_dependencies.has(path):
		return
	_file_dependencies[path] = true
	if not ResourceLoader.exists(path):
		_add_issue(path, "Resource file is missing.")
		return
	for dependency: String in ResourceLoader.get_dependencies(path):
		var target := dependency
		if dependency.contains("::"):
			target = dependency.get_slice("::", 2)
			var uid := ResourceUID.text_to_id(dependency.get_slice("::", 0))
			if ResourceUID.has_id(uid) and ResourceLoader.exists(ResourceUID.get_id_path(uid)):
				target = ResourceUID.get_id_path(uid)
		if ResourceLoader.exists(target):
			_check_dependencies(target)
		else:
			_add_issue(path, "Missing dependency '%s'." % target)


func _add_issue(location: String, message: String) -> void:
	_issues.append("%s: %s" % [location, message])
