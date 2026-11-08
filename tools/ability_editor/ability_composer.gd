extends SceneTree
## Projects and stages native ability resources for the standalone authoring app.

const PREFIX := "ABILITY_COMPOSER "
const MAX_ID := 2147483647
const STAGE_DIR := "res://.godot/ability_editor"
const ProjectFiles := preload("res://tools/ability_editor/ability_editor_files.gd")
const Blocks := preload("res://tools/ability_editor/ability_composer_blocks.gd")
const EXECUTION_FIELDS := [
	"cast_mode", "cast_duration", "animation_name", "release_event", "channel_period",
]
const DELIVERY_FIELDS := ["delivery", "projectile_scene"]
const TARGET_FIELDS := ["shape", "origin", "allegiance", "max_range", "radius"]
const INTEGER_BOUNDS := {
	"id": [0, MAX_ID],
	"cast_mode": [0, PhasedAbilityExecution.CastMode.SUSTAINED],
	"delivery": [0, AbilityDeliveryDefinition.Kind.CHAIN],
	"shape": [0, AbilityTargetingDefinition.Shape.CAPSULE],
	"origin": [0, AbilityTargetingDefinition.Origin.CONTACT],
	"allegiance": [0, AbilityTargetingDefinition.Allegiance.NEUTRAL],
	"cost_pool": [0, AmountDefinition.Pool.STAMINA],
}

var _next_id := 1


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var result: Dictionary
	if args.size() == 2 and args[0] == "--read":
		result = _read_ability(args[1])
	elif args.size() == 4 and args[0] == "--stage":
		result = _stage_ability(args[1], args[2], args[3])
	else:
		result = {"error": "Expected --read or --stage with ability paths."}
	print(PREFIX + JSON.stringify(result))
	quit()


func _read_ability(path: String) -> Dictionary:
	if not _valid_ability_path(path):
		return {"error": "Choose a saved project ability (.tres or .res)."}
	var revision := FileAccess.get_sha256(path)
	var ability := _load_ability(path)
	if ability == null or revision.is_empty():
		return {"error": "Godot could not open %s as a saved ability." % path}
	if revision != FileAccess.get_sha256(path):
		return {"error": "The ability changed while it was being read. Open it again."}
	return _response(path, ability, revision)


func _stage_ability(path: String, request_path: String, stage_path: String) -> Dictionary:
	if not _valid_ability_path(path) or not _valid_stage_path(path, stage_path):
		return {"error": "Choose a project resource and a stage of the same format in the project editor cache."}
	var request: Variant = JSON.parse_string(FileAccess.get_file_as_string(request_path))
	if (not request is Dictionary or not request.get("draft") is Dictionary
			or not request.get("revision") is String):
		return {"error": "Invalid ability authoring request."}
	var revision: String = request.revision
	var draft: Dictionary = request.draft
	var error := _validate_draft(draft)
	if not error.is_empty():
		return {"error": error}
	var existing := not revision.is_empty()
	if (existing and revision != FileAccess.get_sha256(path)) or (not existing and FileAccess.file_exists(path)):
		return {"error": "The ability changed on disk. Reopen it before saving."}
	if not existing and draft.blocks.is_empty():
		return {"error": "Add at least one block to What happens."}
	var ability := _load_ability(path) if existing else AbilityDefinition.new()
	if ability == null:
		return {"error": "Godot could not open %s as a saved ability." % path}
	if ability.ability_id != int(draft.id):
		return {"error": "The ability ID belongs to the saved resource and cannot be changed."}

	var owners: Dictionary[int, Array] = {}
	var issues: Array[String] = []
	_scan_definition_ids(owners, issues)
	if not issues.is_empty():
		return {"error": "\n".join(issues)}
	if not existing:
		if _next_id > MAX_ID:
			return {"error": "No ability or effect IDs remain in the supported range."}
		ability.ability_id = _allocate_id()
		ability.execution = PhasedAbilityExecution.new()
	error = _apply(ability, draft)
	if not error.is_empty():
		return {"error": error}
	issues = CombatResourceValidator.validate_definitions([ability])
	if issues.is_empty():
		issues = CombatResourceValidator.validate_catalog([ability])
	if not issues.is_empty():
		return {"error": "\n".join(issues)}
	error = _check_candidate_ids(ability, path, owners)
	if not error.is_empty():
		return {"error": error}

	var uid := ProjectFiles.saved_uid(path) if existing else ResourceUID.INVALID_ID
	if uid == ResourceUID.INVALID_ID:
		uid = ResourceUID.create_id()
	var flags := ResourceSaver.FLAG_COMPRESS if existing and ProjectFiles.is_compressed_resource(path) else 0
	var write_error := ResourceSaver.save(ability, stage_path, flags)
	if write_error != OK:
		return {"error": "Godot could not stage the ability. %s" % error_string(write_error)}
	if ResourceSaver.set_uid(stage_path, uid) != OK or ProjectFiles.saved_uid(stage_path) != uid:
		return {"error": "Godot could not preserve the resource UID in the staged ability."}
	var reopened := _load_ability(stage_path)
	if reopened == null or not _same_projected_settings(ability, reopened):
		return {"error": "The staged ability did not round-trip through Godot."}
	issues = CombatResourceValidator.validate_paths(PackedStringArray([stage_path]))
	if not issues.is_empty():
		return {"error": "\n".join(issues)}
	var staged_revision := FileAccess.get_sha256(stage_path)
	if staged_revision.is_empty():
		return {"error": "Godot could not verify the staged file."}
	var response := _response(stage_path, reopened, staged_revision)
	if String(response.draft.icon).begins_with(stage_path + "::"):
		response.draft.icon = path + String(response.draft.icon).trim_prefix(stage_path)
	return response


func _response(path: String, ability: AbilityDefinition, revision: String) -> Dictionary:
	var uid := ProjectFiles.saved_uid(path)
	return {
		"draft": _project(ability),
		"revision": revision,
		"uid": "" if uid == ResourceUID.INVALID_ID else ResourceUID.id_to_text(uid),
	}


func _load_ability(path: String) -> AbilityDefinition:
	if not FileAccess.file_exists(path):
		return null
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as AbilityDefinition


func _valid_ability_path(path: String) -> bool:
	if not _valid_project_path(path) or path.get_extension().to_lower() not in ProjectFiles.DEFINITION_EXTENSIONS:
		return false
	var relative := path.trim_prefix("res://")
	if relative.get_slice("/", 0) in ProjectFiles.CATALOG_IGNORED:
		return false
	var directory_path := "res://"
	var parts := relative.split("/")
	for index: int in parts.size():
		var part := parts[index]
		var directory := DirAccess.open(directory_path)
		if (part.is_empty() or part.begins_with(".") or directory == null or directory.is_link(part)
				or FileAccess.file_exists(directory_path.path_join(".gdignore"))):
			return false
		if index < parts.size() - 1:
			directory_path = directory_path.path_join(part)
	return true


func _valid_stage_path(destination: String, stage: String) -> bool:
	return (_valid_project_path(stage) and stage.get_base_dir() == STAGE_DIR
			and stage.get_file().begins_with(".ability-editor-")
			and stage.get_extension().to_lower() == destination.get_extension().to_lower()
			and not FileAccess.file_exists(stage))


func _valid_project_path(path: String) -> bool:
	return (path.begins_with("res://") and path.length() > 6 and path.simplify_path() == path
			and not String.chr(92) in path and not ":" in path.trim_prefix("res://"))


func _project(ability: AbilityDefinition) -> Dictionary:
	var execution := ability.execution as PhasedAbilityExecution
	var delivery := execution.delivery if execution != null else null
	var target := execution.targeting if execution != null else null
	var cost_editable := _is_simple_cost(ability)
	var cooldown_editable := _is_simple_cooldown(ability)
	var cost := ability.resource_costs[0] if cost_editable and not ability.resource_costs.is_empty() else null
	return {
		"id": ability.ability_id,
		"name": ability.display_name,
		"icon": _path_of(ability.icon),
		"tags": Array(ability.ability_tags),
		"activation_event": String(ability.activation_event_tag),
		"cast_mode": execution.cast_mode if execution != null else PhasedAbilityExecution.CastMode.IMMEDIATE,
		"cast_duration": execution.cast_duration if execution != null else 0.0,
		"animation_name": String(execution.animation_name) if execution != null else "",
		"release_event": String(execution.release_event) if execution != null else "",
		"channel_period": execution.channel_period if execution != null else 1.0,
		"delivery": delivery.kind if delivery != null else AbilityDeliveryDefinition.Kind.NONE,
		"projectile_scene": _path_of(delivery.projectile_scene) if delivery != null else "",
		"shape": target.shape if target != null else AbilityTargetingDefinition.Shape.SELF,
		"origin": target.origin if target != null else AbilityTargetingDefinition.Origin.CASTER,
		"allegiance": target.allegiance if target != null else AbilityTargetingDefinition.Allegiance.ANY,
		"max_range": target.max_range if target != null else 100.0,
		"radius": target.radius if target != null else 1.0,
		"settings_editable": (execution != null and _is_owned(execution, ability)
				and _is_owned(delivery, ability) and _is_owned(target, ability)),
		"blocks_editable": execution != null and _is_owned(execution, ability),
		"cost_pool": cost.pool if cost != null else AmountDefinition.Pool.MANA,
		"cost": (cost.amount.fixed_amount if cost != null else 0.0) if cost_editable else null,
		"cooldown": ((ability.charge_pool.recharge_seconds if ability.charge_pool != null else 0.0)
				if cooldown_editable else null),
		"cost_editable": cost_editable,
		"cooldown_editable": cooldown_editable,
		"blocks": Blocks.read_blocks(ability) if execution != null else [],
	}


func _path_of(resource: Resource) -> String:
	return resource.resource_path if resource != null else ""


func _is_owned(resource: Resource, ability: AbilityDefinition) -> bool:
	return (resource == null or resource.resource_path.is_empty()
			or resource.resource_path.begins_with(ability.resource_path + "::"))


func _is_simple_cost(ability: AbilityDefinition) -> bool:
	if ability.resource_costs.is_empty():
		return true
	if ability.resource_costs.size() != 1:
		return false
	var cost := ability.resource_costs[0]
	return (cost != null and _is_owned(cost, ability) and not cost.spend_up_to_maximum
			and cost.amount != null and _is_owned(cost.amount, ability)
			and cost.amount.source == AmountDefinition.Source.FIXED
			and cost.amount.unit == AmountDefinition.Unit.POINTS and not cost.amount.clamp_enabled)


func _is_simple_cooldown(ability: AbilityDefinition) -> bool:
	var charges := ability.charge_pool
	return charges == null or (_is_owned(charges, ability) and charges.capacity == 1
			and charges.shared_group.is_empty() and not charges.parallel_recharge)


func _validate_draft(draft: Dictionary) -> String:
	for field: String in INTEGER_BOUNDS:
		var value: Variant = draft.get(field)
		var bounds: Array = INTEGER_BOUNDS[field]
		if not _is_number(value) or value < bounds[0] or value > bounds[1] or value != floor(value):
			return "Invalid choice for %s." % field
	for field: String in ["name", "icon", "activation_event", "animation_name", "release_event", "projectile_scene"]:
		if not draft.get(field) is String:
			return "Expected text for %s." % field
	if draft.name.strip_edges().is_empty():
		return "Enter an ability name."
	for field: String in ["cast_duration", "channel_period", "max_range", "radius", "cost", "cooldown"]:
		var value: Variant = draft.get(field)
		var commitment := field in ["cost", "cooldown"]
		if commitment and draft.has(field) and value == null:
			continue
		if not _is_number(value) or (commitment and value < 0):
			return "Invalid numeric value for %s." % field
	if not draft.get("tags") is Array or not draft.get("blocks") is Array:
		return "Expected tag and block lists."
	for tag: Variant in draft.tags:
		if not tag is String:
			return "Ability tags must use registered tag names."
	return ""


func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


func _differs(before: Dictionary, after: Dictionary, fields: Array) -> bool:
	return fields.any(func(field: String) -> bool: return before[field] != after[field])


func _apply(ability: AbilityDefinition, draft: Dictionary) -> String:
	var before := _project(ability)
	ability.display_name = draft.name.strip_edges()
	ability.ability_tags = PackedStringArray(draft.tags)
	ability.activation_event_tag = StringName(draft.activation_event)
	if before.icon != draft.icon:
		if draft.icon.is_empty():
			ability.icon = null
		elif _valid_project_path(draft.icon):
			var texture := ResourceLoader.load(draft.icon, "Texture2D") as Texture2D
			if texture == null:
				return "The chosen icon is not a project texture."
			ability.icon = texture
		else:
			return "Choose a project texture for the ability icon."
	var error := _apply_execution(ability, before, draft)
	if not error.is_empty():
		return error
	error = _apply_commitment(ability, before, draft)
	if not error.is_empty():
		return error
	if before.blocks == draft.blocks:
		return ""
	if not before.blocks_editable:
		return "This ability uses an external or unsupported execution. Its blocks are read-only here."
	return Blocks.apply_blocks(ability, draft.blocks, _allocate_id)


func _apply_execution(ability: AbilityDefinition, before: Dictionary, draft: Dictionary) -> String:
	var change_cast := _differs(before, draft, EXECUTION_FIELDS)
	var change_delivery := _differs(before, draft, DELIVERY_FIELDS)
	var change_target := _differs(before, draft, TARGET_FIELDS)
	if not change_cast and not change_delivery and not change_target:
		return ""
	if not before.settings_editable:
		return "The cast or delivery uses a shared or unsupported resource. Its settings are read-only here."
	var execution := ability.execution as PhasedAbilityExecution
	if change_cast:
		execution.cast_mode = int(draft.cast_mode)
		execution.cast_duration = float(draft.cast_duration)
		execution.animation_name = StringName(draft.animation_name)
		execution.release_event = StringName(draft.release_event)
		execution.channel_period = float(draft.channel_period)
	if change_delivery:
		if execution.delivery == null:
			execution.delivery = AbilityDeliveryDefinition.new()
		execution.delivery.kind = int(draft.delivery)
		if before.projectile_scene != draft.projectile_scene:
			if draft.projectile_scene.is_empty():
				execution.delivery.projectile_scene = null
			elif _valid_project_path(draft.projectile_scene):
				var scene := ResourceLoader.load(draft.projectile_scene, "PackedScene") as PackedScene
				if scene == null or not ProjectFiles.is_projectile_scene(scene):
					return "Choose a scene with an AbilityProjectile root."
				execution.delivery.projectile_scene = scene
			else:
				return "Choose a projectile scene from this project."
	if change_target:
		if execution.targeting == null:
			execution.targeting = AbilityTargetingDefinition.new()
		execution.targeting.shape = int(draft.shape)
		execution.targeting.origin = int(draft.origin)
		execution.targeting.allegiance = int(draft.allegiance)
		execution.targeting.max_range = float(draft.max_range)
		execution.targeting.radius = float(draft.radius)
	return ""


func _apply_commitment(ability: AbilityDefinition, before: Dictionary, draft: Dictionary) -> String:
	if before.cost != draft.cost or before.cost_pool != draft.cost_pool:
		if not before.cost_editable or draft.cost == null:
			return "This ability has a shared or calculated resource cost. Its cost is read-only here."
		if ability.resource_costs.is_empty() and float(draft.cost) > 0.0:
			var cost := AbilityResourceCost.new()
			cost.amount = AmountDefinition.new()
			ability.resource_costs.append(cost)
		if not ability.resource_costs.is_empty():
			ability.resource_costs[0].pool = int(draft.cost_pool)
			ability.resource_costs[0].amount.fixed_amount = float(draft.cost)
	if before.cooldown != draft.cooldown:
		if not before.cooldown_editable or draft.cooldown == null:
			return "This ability has shared or multiple charges. Its cooldown is read-only here."
		if float(draft.cooldown) == 0.0:
			ability.charge_pool = null
		else:
			if ability.charge_pool == null:
				ability.charge_pool = AbilityChargeDefinition.new()
			ability.charge_pool.recharge_seconds = float(draft.cooldown)
	return ""


func _same_projected_settings(before: AbilityDefinition, after: AbilityDefinition) -> bool:
	var expected := _project(before)
	var actual := _project(after)
	# Internal resource paths and row keys may differ without changing gameplay.
	if before.icon != null and after.icon != null and _is_owned(before.icon, before) and _is_owned(after.icon, after):
		expected.icon = ""
		actual.icon = ""
	for rows: Array in [expected.blocks, actual.blocks]:
		for row: Dictionary in rows:
			row.erase("key")
	return expected == actual


func _scan_definition_ids(owners: Dictionary[int, Array], issues: Array[String]) -> void:
	var paths: Array[String] = []
	ProjectFiles.collect("res://", paths, issues,
			ProjectFiles.DEFINITION_EXTENSIONS + ProjectFiles.SCENE_EXTENSIONS, ProjectFiles.AUTHORING_IGNORED)
	var visited: Dictionary[Resource, bool] = {}
	for path: String in paths:
		if (path.get_extension().to_lower() in ProjectFiles.DEFINITION_EXTENSIONS
				and not ProjectFiles.has_script_dependency(path)):
			continue
		var resource := ResourceLoader.load(path)
		if resource == null:
			issues.append("Could not inspect ability and effect IDs in %s." % path)
			continue
		_collect_ids(resource, path, owners, visited)
	for id: int in owners:
		_next_id = maxi(_next_id, mini(id, MAX_ID) + 1)


func _check_candidate_ids(ability: AbilityDefinition, path: String, owners: Dictionary[int, Array]) -> String:
	var candidate: Dictionary[int, Array] = {}
	_collect_ids(ability, path, candidate, {})
	for id: int in candidate:
		for location: String in candidate[id]:
			for existing: String in owners.get(id, []):
				if existing != location and existing.get_slice("::", 0) != path:
					return "Ability or effect ID %d already belongs to %s." % [id, existing]
	return ""


func _collect_ids(
		value: Variant, owner: String, ids: Dictionary[int, Array], visited: Dictionary[Resource, bool]
) -> void:
	if value is Array:
		for child: Variant in value:
			_collect_ids(child, owner, ids, visited)
		return
	if value is Dictionary:
		for child: Variant in value.values():
			_collect_ids(child, owner, ids, visited)
		return
	if not value is Resource or value is Script or visited.has(value):
		return
	visited[value] = true
	if not value.resource_path.is_empty():
		owner = value.resource_path
	if value is AbilityDefinition:
		_note_id(ids, value.ability_id, owner)
	elif value is GameplayEffectDefinition:
		_note_id(ids, value.effect_id, owner)
	if value is PackedScene:
		var state: SceneState = value.get_state()
		for node: int in state.get_node_count():
			for property: int in state.get_node_property_count(node):
				_collect_ids(state.get_node_property_value(node, property), owner, ids, visited)
		for connection: int in state.get_connection_count():
			_collect_ids(state.get_connection_binds(connection), owner, ids, visited)
		return
	for property: Dictionary in value.get_property_list():
		var usage := int(property.usage)
		if usage & PROPERTY_USAGE_STORAGE and usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			_collect_ids(value.get(property.name), owner, ids, visited)


func _note_id(ids: Dictionary[int, Array], id: int, owner: String) -> void:
	if id > 0 and not owner in ids.get(id, []):
		if not ids.has(id):
			ids[id] = []
		ids[id].append(owner)


func _allocate_id() -> int:
	if _next_id > MAX_ID:
		return 0
	var id := _next_id
	_next_id += 1
	return id
