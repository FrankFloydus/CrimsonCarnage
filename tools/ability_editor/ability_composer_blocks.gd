extends RefCounted
## Projects and patches the composer timeline without creating a second gameplay format.

const EVENTS := {
	"cast": &"ability.cast_started",
	"contact": &"delivery.impact",
	"release": &"ability.input_released",
}
const TRIGGERS := {
	"hit": ReactionDefinition.Trigger.ON_HIT,
	"dealt": ReactionDefinition.Trigger.ON_HEALTH_DAMAGED,
}
const LABELS := {
	"ref": "Apply saved effect", "damage": "Deal damage", "dot": "Damage over time",
	"slow": "Slow movement", "stun": "Stun", "silence": "Silence", "heal": "Heal",
	"restore": "Restore resource", "leech": "Lifesteal", "shield": "Absorb shield",
	"reflect": "Reflect spell", "link": "Link target", "dispel": "Cleanse / dispel",
}
const SCHOOLS := {
	"Fire": GameplayEffectDefinition.MagicSchool.FIRE,
	"Cold": GameplayEffectDefinition.MagicSchool.COLD,
	"Lightning": GameplayEffectDefinition.MagicSchool.LIGHTNING,
	"Necrotic": GameplayEffectDefinition.MagicSchool.NECROTIC,
	"Void": GameplayEffectDefinition.MagicSchool.VOID,
}
const STATUS_TAGS := {
	"slow": "State.Slowed", "stun": "State.Control.Stunned", "silence": "State.Control.Silenced",
}
const LINK_SLOT := &"LinkedTarget"


## Returns ordered designer-facing rows. Complex native logic remains visible and read-only.
static func read_blocks(ability: AbilityDefinition) -> Array[Dictionary]:
	return _project(ability)["rows"]


## Applies the draft to a fresh, detached ability. Existing opaque rows must be preserved.
static func apply_blocks(ability: AbilityDefinition, rows: Array, allocate_id: Callable) -> String:
	var execution := ability.execution as PhasedAbilityExecution
	if execution == null:
		return "This execution type cannot be edited in the composer."
	var model := _project(ability)
	var sources: Dictionary = model["sources"]
	var seen := {}
	var lanes := {"cast": [], "contact": [], "payload": [], "release": [], "hit": [], "dealt": []}
	for raw: Variant in rows:
		if not raw is Dictionary or not raw.get("values") is Dictionary:
			return "Invalid timeline block."
		var row: Dictionary = raw
		var key := str(row.get("key", ""))
		var lane := str(row.get("phase", ""))
		var kind := str(row.get("kind", ""))
		var source: Dictionary = sources.get(key, {})
		if not lanes.has(lane) or (not key.is_empty() and seen.has(key)):
			return "Invalid or repeated block: %s." % key
		if source.is_empty() and not (key.is_empty() or key.begins_with("new:")):
			return "This block no longer matches the saved resource. Reopen the ability."
		seen[key] = true
		if not source.is_empty():
			var original: Dictionary = source["row"]
			if kind != original["kind"]:
				return "Replace a block by removing it and adding its new kind."
			if not original["editable"]:
				if lane != original["phase"] or row["values"] != original["values"]:
					return "Existing complex blocks are read-only."
				if not source["whole_phase"]:
					lanes[lane].append(source["resource"])
				continue
		var validation := _validate_row(row, lane, kind)
		if not validation.is_empty():
			return validation
		var event_lane := "contact" if lane == "payload" else lane
		if model["locked"].has(event_lane):
			return "This timing uses a complex existing phase. Its blocks are preserved."
		var resource: Resource = source.get("resource")
		if not source.is_empty() and lane == source["row"]["phase"] and row["values"] == source["row"]["values"]:
			lanes[lane].append(resource)
			continue
		var mapped := _make_block(row, resource, lane, kind, allocate_id)
		if mapped == null:
			return "%s could not be created. Check its values and referenced effect." % LABELS[kind]
		lanes[lane].append(mapped)
	for key: String in sources:
		if not sources[key]["row"]["editable"] and not seen.has(key):
			return "Existing complex blocks cannot be removed in the composer."
	if _crosses_read_only_block(model["rows"], rows, sources):
		return "Keep editable blocks on the same side of existing complex blocks."
	_apply_phases(execution, model, lanes)
	_apply_reactions(ability, lanes)
	return ""


static func _project(ability: AbilityDefinition) -> Dictionary:
	var model := {"rows": [] as Array[Dictionary], "sources": {}, "owners": {}, "locked": {}, "hit_action": null}
	var execution := ability.execution as PhasedAbilityExecution
	if execution != null:
		var counts := {}
		for phase: AbilityPhaseDefinition in execution.phases:
			if phase != null:
				counts[phase.event_key] = int(counts.get(phase.event_key, 0)) + 1
		for index: int in range(execution.phases.size()):
			var phase := execution.phases[index]
			if phase == null:
				continue
			var lane := str(EVENTS.find_key(phase.event_key)) if phase.event_key in EVENTS.values() else ""
			if lane.is_empty() or counts[phase.event_key] != 1 or not _simple_phase(phase, lane):
				if not lane.is_empty():
					model["locked"][lane] = true
				_add_projection(model, "p:%d" % index, lane if not lane.is_empty() else "cast",
						phase, {}, "%s · %d actions" % [phase.event_key, phase.actions.size()], true)
				continue
			model["owners"][lane] = index
			for action_index: int in range(phase.actions.size()):
				var action := phase.actions[action_index]
				var key := "p:%d/a:%d" % [index, action_index]
				var apply := action as AbilityApplyEffectsAction
				if apply != null and apply.application == AbilityApplyEffectsAction.Application.DELIVERED_HIT:
					model["hit_action"] = apply
					for effect_index: int in range(apply.effects.size()):
						var effect := apply.effects[effect_index]
						_add_projection(model, "%s/e:%d" % [key, effect_index], "payload", effect,
								_effect_projection(effect), _resource_label(effect))
				else:
					_add_projection(model, key, lane, action, _action_projection(action, lane), _resource_label(action))
	for index: int in range(ability.reactions.size()):
		var reaction := ability.reactions[index]
		if reaction == null:
			continue
		var lane := _reaction_lane(reaction)
		if lane.is_empty():
			_add_projection(model, "r:%d" % index, "hit", reaction, {},
					"%s · %d actions" % [ReactionDefinition.Trigger.find_key(reaction.trigger), reaction.actions.size()], true)
		else:
			_add_projection(model, "r:%d" % index, lane, reaction, _reaction_projection(reaction),
					"%d existing reaction actions" % reaction.actions.size())
	return model


static func _add_projection(
		model: Dictionary, key: String, lane: String, native: Resource,
		projection: Dictionary, fallback: String, whole_phase: bool = false
) -> void:
	var kind: String = projection.get("kind", "opaque")
	if not _compatible(kind, lane):
		kind = "opaque"
		projection = {}
	var row := {
		"key": key, "phase": lane, "kind": kind, "label": LABELS.get(kind, "Existing logic"),
		"summary": projection.get("summary", fallback), "values": projection.get("values", {}),
		"editable": not projection.is_empty(),
	}
	model["rows"].append(row)
	model["sources"][key] = {"row": row, "resource": native, "whole_phase": whole_phase}


static func _resource_label(resource: Resource) -> String:
	if resource is GameplayEffectDefinition:
		return resource.display_name
	if resource == null:
		return "Missing resource"
	var script := resource.get_script() as Script
	return script.get_global_name() if script != null else resource.get_class()


static func _is_external(resource: Resource) -> bool:
	return resource != null and resource.resource_path.begins_with("res://") \
			and not "::" in resource.resource_path


static func _simple_phase(phase: AbilityPhaseDefinition, lane: String) -> bool:
	if _is_external(phase) or phase.targeting != null or not phase.conditions.is_empty() \
			or phase.execution_mode != AbilityPhaseDefinition.ExecutionMode.ALL \
			or phase.failure_policy != AbilityPhaseDefinition.FailurePolicy.STOP_PHASE \
			or phase.run_once_per_execution or phase.run_once_per_target or phase.max_fires != 0:
		return false
	for index: int in range(phase.actions.size()):
		var action := phase.actions[index] as AbilityApplyEffectsAction
		if action != null and action.application == AbilityApplyEffectsAction.Application.DELIVERED_HIT:
			if lane != "contact" or index != phase.actions.size() - 1 or _is_external(action):
				return false
	return true


static func _projection(kind: String, values: Dictionary, summary: String) -> Dictionary:
	return {"kind": kind, "values": values, "summary": summary}


static func _fixed(amount: AmountDefinition) -> bool:
	return amount != null and amount.source == AmountDefinition.Source.FIXED \
			and amount.unit == AmountDefinition.Unit.POINTS and not amount.clamp_enabled


static func _effect_projection(effect: GameplayEffectDefinition) -> Dictionary:
	if effect == null:
		return {}
	if _is_external(effect):
		return _projection("ref", {"path": effect.resource_path}, effect.display_name + " · Linked effect")
	var damage := effect.get_damage_execution()
	if damage != null and _fixed(damage.amount) and not damage.use_weapon_damage \
			and is_zero_approx(damage.power_coefficient) and effect.executions.size() == 1 \
			and effect.components.is_empty() and effect.modifiers.is_empty() and effect.status_profile == null:
		var school := "Physical" if effect.damage_type == GameplayEffectDefinition.DamageType.PHYSICAL \
				else str(SCHOOLS.find_key(effect.magic_school))
		var values := {"amount": damage.amount.fixed_amount, "school": school}
		if effect.timing == GameplayEffectDefinition.Timing.INSTANT:
			return _projection("damage", values, "%s %s damage" % [values["amount"], school])
		if effect.timing == GameplayEffectDefinition.Timing.DURATION and effect.period > 0.0:
			values.merge({"duration": effect.duration, "period": effect.period})
			return _projection("dot", values, "%s %s per tick for %s s" % [values["amount"], school, effect.duration])
	if effect.timing != GameplayEffectDefinition.Timing.DURATION or effect.period != 0.0 \
			or not effect.executions.is_empty():
		return {}
	var duration := {"duration": effect.duration}
	if effect.status_profile != null and effect.components.is_empty():
		var modifier: AttributeModifier = effect.modifiers.front() if effect.modifiers.size() == 1 else null
		if effect.status_profile.category == StatusProfile.Category.SLOW and modifier != null \
				and modifier.attribute == CombatAttributes.Id.MOVEMENT_SPEED \
				and modifier.operation == AttributeModifier.Operation.FINAL_MOVEMENT_PERCENT \
				and modifier.capture_attribute == CombatAttributes.Id.NONE and modifier.set_by_caller_tag.is_empty():
			duration["amount"] = -modifier.value
			return _projection("slow", duration, "−%s%% movement for %s s" % [duration["amount"], effect.duration])
		if effect.modifiers.is_empty():
			if effect.status_profile.category == StatusProfile.Category.STUN and STATUS_TAGS["stun"] in effect.granted_tags:
				return _projection("stun", duration, "Stun for %s s" % effect.duration)
			if effect.status_profile.category == StatusProfile.Category.SILENCE and STATUS_TAGS["silence"] in effect.granted_tags:
				return _projection("silence", duration, "Silence for %s s" % effect.duration)
	if effect.modifiers.is_empty() and effect.status_profile == null:
		if effect.components.is_empty() and effect.exclusive_owner_slot == LINK_SLOT:
			return _projection("link", duration, "Remember Linked Target for %s s" % effect.duration)
		if effect.components.size() == 1:
			var defense := effect.components[0] as DamageDefenseEffectComponent
			if defense != null and defense.mode == DamageDefenseEffectComponent.Mode.ABSORB:
				duration["amount"] = defense.capacity
				return _projection("shield", duration, "Absorb %s damage for %s s" % [defense.capacity, effect.duration])
			if defense != null and defense.mode == DamageDefenseEffectComponent.Mode.REFLECT \
					and defense.damage_tags == PackedStringArray(["Ability.Spell"]):
				return _projection("reflect", duration, "Reflect spells for %s s" % effect.duration)
	return {}


static func _action_projection(action: AbilityActionDefinition, lane: String) -> Dictionary:
	if _is_external(action):
		return {}
	if action is AbilityApplyEffectsAction and action.effects.size() == 1 \
			and not action.owned_until_cast_ends and not action.require_application:
		return _with_recipient(_effect_projection(action.effects[0]), _phase_recipient(lane))
	if action is AbilityRestoreResourceAction and _fixed(action.amount) and action.healing_profile == null:
		if action.resource == AmountDefinition.Pool.HEALTH:
			return _with_recipient(_projection("heal", {"amount": action.amount.fixed_amount},
					"Restore %s Health" % action.amount.fixed_amount), _phase_recipient(lane))
		return _restore_projection(action.amount.fixed_amount, action.resource, _phase_recipient(lane))
	if action is AbilityDispelAction and action.effect_id == 0 and action.asset_tags.size() == 1:
		return _projection("dispel", {"tag": action.asset_tags[0], "amount": action.maximum_per_target},
				"Remove effects matching %s" % action.asset_tags[0])
	return {}


static func _reaction_lane(reaction: ReactionDefinition) -> String:
	return str(TRIGGERS.find_key(reaction.trigger)) if reaction.trigger in TRIGGERS.values() else ""


static func _reaction_projection(reaction: ReactionDefinition) -> Dictionary:
	if _is_external(reaction) or reaction.actions.size() != 1 \
			or reaction.once_policy != ReactionDefinition.OncePolicy.PER_EVENT:
		return {}
	var recipient := _reaction_recipient(reaction)
	if recipient.is_empty():
		return {}
	var action := reaction.actions[0]
	if _is_external(action):
		return {}
	if action is ApplyEffectReactionAction and action.magnitude_tag.is_empty() and not action.retaliation:
		return _with_recipient(_effect_projection(action.effect), recipient)
	if action is HealReactionAction and action.healing_profile == null:
		if _fixed(action.amount):
			return _with_recipient(_projection("heal", {"amount": action.amount.fixed_amount},
					"Restore %s Health" % action.amount.fixed_amount), recipient)
		if action.amount != null and action.amount.source == AmountDefinition.Source.OUTCOME_PERCENT \
				and action.amount.outcome_basis == AmountDefinition.OutcomeBasis.ACTUAL_HEALTH_DAMAGE \
				and not action.amount.clamp_enabled and recipient == "Caster" \
				and reaction.trigger == ReactionDefinition.Trigger.ON_HEALTH_DAMAGED:
			return _projection("leech", {"amount": action.amount.percentage},
					"Heal for %s%% of actual Health damage" % action.amount.percentage)
	if action is RestoreResourceReactionAction and _fixed(action.amount):
		return _restore_projection(action.amount.fixed_amount, action.resource, recipient)
	return {}


static func _reaction_recipient(reaction: ReactionDefinition) -> String:
	match reaction.recipient:
		ReactionDefinition.Recipient.CREDITED_OWNER:
			return "Caster"
		ReactionDefinition.Recipient.TARGET:
			return "Target"
		ReactionDefinition.Recipient.LINKED_ACTOR:
			return "Linked Target" if reaction.link_slot == LINK_SLOT else ""
	return ""


static func _restore_projection(amount: float, pool: int, recipient: String) -> Dictionary:
	var name := "Mana" if pool == AmountDefinition.Pool.MANA else "Stamina"
	return _with_recipient(_projection("restore", {"amount": amount, "pool": name},
			"Restore %s %s" % [amount, name]), recipient)


static func _with_recipient(projection: Dictionary, recipient: String) -> Dictionary:
	if projection.get("kind") in ["heal", "restore", "shield", "reflect"]:
		projection["values"]["recipient"] = recipient
		projection["summary"] += " · " + recipient
	return projection


static func _phase_recipient(lane: String) -> String:
	return "Caster" if lane in ["cast", "release", "hit", "dealt"] else "Target"


static func _compatible(kind: String, lane: String) -> bool:
	match kind:
		"ref":
			return true
		"damage", "dot":
			return lane == "payload"
		"slow", "stun", "silence":
			return lane in ["payload", "hit", "dealt"]
		"heal", "restore", "shield", "reflect":
			return lane != "payload"
		"leech":
			return lane == "dealt"
		"link":
			return lane in ["contact", "hit", "dealt"]
		"dispel":
			return lane in ["cast", "contact", "release"]
	return false


static func _validate_row(row: Dictionary, lane: String, kind: String) -> String:
	if not _compatible(kind, lane):
		return "This block cannot run at the chosen timing."
	var values: Dictionary = row["values"]
	if kind in ["damage", "dot", "slow", "heal", "restore", "leech", "shield", "dispel"] \
			and not _is_number(values.get("amount"), 0.0):
		return "Enter a nonnegative amount for %s." % LABELS[kind]
	if kind in ["dot", "slow", "stun", "silence", "shield", "reflect", "link"] \
			and not _is_number(values.get("duration"), 0.0, true):
		return "Enter a positive duration for %s." % LABELS[kind]
	if kind in ["damage", "dot"] and values.get("school") != "Physical" and not SCHOOLS.has(values.get("school")):
		return "Choose a valid damage school."
	if kind == "dot" and not _is_number(values.get("period"), 0.0, true):
		return "Enter a positive tick interval."
	if kind == "slow" and float(values["amount"]) > 100.0:
		return "Movement slow must be between 0% and 100%."
	if kind == "shield" and not _is_number(values["amount"], 0.0, true):
		return "Enter a positive absorption capacity."
	if kind == "restore" and values.get("pool") not in ["Mana", "Stamina"]:
		return "Resource recovery supports Mana and Stamina. Use Heal for Health."
	if kind == "dispel" and (not values.get("tag") is String or values["tag"].strip_edges().is_empty() \
			or floorf(float(values["amount"])) != float(values["amount"]) or float(values["amount"]) > 2147483647.0):
		return "Choose a dispel tag and a whole-number removal limit."
	if kind in ["heal", "restore", "shield", "reflect"]:
		var recipient: Variant = values.get("recipient", _phase_recipient(lane))
		if lane in TRIGGERS and recipient not in ["Caster", "Target", "Linked Target"]:
			return "Choose a valid reaction recipient."
		if lane not in TRIGGERS and recipient != _phase_recipient(lane):
			return "This timing fixes the recipient to %s." % _phase_recipient(lane)
	if kind == "ref":
		var path: Variant = values.get("path")
		if not path is String or not path.begins_with("res://") or path.get_extension() not in ["res", "tres"] \
				or ".." in path.split("/") or "::" in path or "\\" in path:
			return "Choose a saved effect from the project."
	return ""


static func _is_number(value: Variant, minimum: float, strict: bool = false) -> bool:
	return (value is int or value is float) and is_finite(value) \
			and (float(value) > minimum if strict else float(value) >= minimum)


static func _crosses_read_only_block(original: Array, rows: Array, sources: Dictionary) -> bool:
	var ordered := {}
	for index: int in range(rows.size()):
		var row: Dictionary = rows[index]
		ordered[row.get("key", "")] = {"index": index, "phase": row.get("phase", "")}
	for index: int in range(original.size()):
		var anchor: Dictionary = original[index]
		if anchor["editable"] or sources[anchor["key"]]["whole_phase"]:
			continue
		for other_index: int in range(original.size()):
			var other: Dictionary = original[other_index]
			if index == other_index or other["phase"] != anchor["phase"] or not ordered.has(other["key"]):
				continue
			var moved: Dictionary = ordered[other["key"]]
			if moved["phase"] == anchor["phase"] \
					and (other_index < index) != (moved["index"] < ordered[anchor["key"]]["index"]):
				return true
	return false


static func _make_block(
		row: Dictionary, source: Resource, lane: String, kind: String, allocate_id: Callable
) -> Resource:
	var values: Dictionary = row["values"]
	if lane in TRIGGERS:
		return _make_reaction(values, source, lane, kind, allocate_id)
	if kind in ["heal", "restore"]:
		var recovery := source.duplicate() as AbilityRestoreResourceAction if source is AbilityRestoreResourceAction \
				else AbilityRestoreResourceAction.new()
		recovery.resource = AmountDefinition.Pool.HEALTH if kind == "heal" else _pool(values["pool"])
		recovery.amount = _fixed_amount(float(values["amount"]), _source_amount(source))
		return recovery
	if kind == "dispel":
		var dispel := source.duplicate() as AbilityDispelAction if source is AbilityDispelAction \
				else AbilityDispelAction.new()
		dispel.asset_tags = PackedStringArray([values["tag"]])
		dispel.maximum_per_target = int(values["amount"])
		return dispel
	var effect := _make_effect(values, _source_effect(source), kind, allocate_id)
	if effect == null or (kind == "ref" and lane != "payload" and effect.is_damage_effect()):
		return null
	if lane == "payload":
		return effect
	var apply := source.duplicate() as AbilityApplyEffectsAction if source is AbilityApplyEffectsAction \
			else AbilityApplyEffectsAction.new()
	apply.application = AbilityApplyEffectsAction.Application.DIRECT_EFFECT
	apply.effects = [effect]
	return apply


static func _make_reaction(
		values: Dictionary, source: Resource, lane: String, kind: String, allocate_id: Callable
) -> ReactionDefinition:
	var original := source as ReactionDefinition
	var reaction := original.duplicate() as ReactionDefinition if original != null else ReactionDefinition.new()
	reaction.trigger = TRIGGERS[lane]
	if original == null:
		reaction.recipient = ReactionDefinition.Recipient.TARGET
	var recipient: String = values.get("recipient", "")
	if recipient == "Linked Target":
		if reaction.recipient != ReactionDefinition.Recipient.LINKED_ACTOR:
			reaction.link_exclude_trigger_target = false
		reaction.recipient = ReactionDefinition.Recipient.LINKED_ACTOR
		reaction.link_slot = LINK_SLOT
	elif not recipient.is_empty() or kind == "leech":
		reaction.recipient = ReactionDefinition.Recipient.CREDITED_OWNER if recipient == "Caster" or kind == "leech" \
				else ReactionDefinition.Recipient.TARGET
	var previous: CombatReactionAction = original.actions[0] if original != null else null
	if kind in ["heal", "leech"]:
		var healing := previous.duplicate() as HealReactionAction if previous is HealReactionAction \
				else HealReactionAction.new()
		healing.amount = _fixed_amount(float(values["amount"]), _source_amount(source))
		if kind == "leech":
			healing.amount.source = AmountDefinition.Source.OUTCOME_PERCENT
			healing.amount.outcome_basis = AmountDefinition.OutcomeBasis.ACTUAL_HEALTH_DAMAGE
			healing.amount.percentage = float(values["amount"])
		reaction.actions = [healing]
	elif kind == "restore":
		var recovery := previous.duplicate() as RestoreResourceReactionAction if previous is RestoreResourceReactionAction \
				else RestoreResourceReactionAction.new()
		recovery.resource = _pool(values["pool"])
		recovery.amount = _fixed_amount(float(values["amount"]), _source_amount(source))
		reaction.actions = [recovery]
	else:
		var effect := _make_effect(values, _source_effect(source), kind, allocate_id)
		if effect == null or (kind == "ref" and effect.is_damage_effect()):
			return null
		var apply := previous.duplicate() as ApplyEffectReactionAction if previous is ApplyEffectReactionAction \
				else ApplyEffectReactionAction.new()
		apply.effect = effect
		reaction.actions = [apply]
	return reaction


static func _pool(name: String) -> AmountDefinition.Pool:
	return AmountDefinition.Pool.MANA if name == "Mana" else AmountDefinition.Pool.STAMINA


static func _source_amount(source: Resource) -> AmountDefinition:
	if source is AbilityRestoreResourceAction:
		return source.amount
	if source is ReactionDefinition:
		var action: CombatReactionAction = source.actions[0]
		if action is HealReactionAction or action is RestoreResourceReactionAction:
			return action.amount
	return null


static func _source_effect(source: Resource) -> GameplayEffectDefinition:
	if source is GameplayEffectDefinition:
		return source
	if source is AbilityApplyEffectsAction:
		return source.effects[0]
	if source is ReactionDefinition and source.actions[0] is ApplyEffectReactionAction:
		return source.actions[0].effect
	return null


static func _fixed_amount(value: float, original: AmountDefinition = null) -> AmountDefinition:
	var amount := original.duplicate() as AmountDefinition if original != null else AmountDefinition.new()
	amount.source = AmountDefinition.Source.FIXED
	amount.fixed_amount = value
	return amount


static func _make_effect(
		values: Dictionary, original: GameplayEffectDefinition, kind: String, allocate_id: Callable
) -> GameplayEffectDefinition:
	if kind == "ref":
		if original != null and original.resource_path == values["path"]:
			return original
		return ResourceLoader.load(values["path"]) as GameplayEffectDefinition
	var effect := original.duplicate() as GameplayEffectDefinition if original != null else GameplayEffectDefinition.new()
	if original == null:
		effect.effect_id = int(allocate_id.call())
		effect.display_name = LABELS[kind]
	if kind in ["damage", "dot"]:
		var previous := effect.get_damage_execution()
		var damage := previous.duplicate() as GameplayEffectDamageExecution if previous != null \
				else GameplayEffectDamageExecution.new()
		damage.amount = _fixed_amount(float(values["amount"]), damage.amount)
		effect.damage_type = GameplayEffectDefinition.DamageType.PHYSICAL if values["school"] == "Physical" \
				else GameplayEffectDefinition.DamageType.MAGIC
		if values["school"] != "Physical":
			effect.magic_school = SCHOOLS[values["school"]]
		effect.executions = [damage]
	if values.has("duration"):
		effect.timing = GameplayEffectDefinition.Timing.DURATION
		effect.duration = float(values["duration"])
	if kind == "dot":
		effect.period = float(values["period"])
		if original == null:
			effect.execute_periodic_on_application = false
	if kind in STATUS_TAGS:
		if effect.status_profile == null:
			effect.status_profile = StatusProfile.new()
			effect.status_profile.category = StatusProfile.Category.SLOW if kind == "slow" \
					else StatusProfile.Category.STUN if kind == "stun" else StatusProfile.Category.SILENCE
			effect.granted_tags = PackedStringArray([STATUS_TAGS[kind]])
		if kind == "slow":
			var modifier := effect.modifiers[0].duplicate() as AttributeModifier if not effect.modifiers.is_empty() \
					else AttributeModifier.new()
			modifier.attribute = CombatAttributes.Id.MOVEMENT_SPEED
			modifier.operation = AttributeModifier.Operation.FINAL_MOVEMENT_PERCENT
			modifier.value = -float(values["amount"])
			effect.modifiers = [modifier]
	if kind in ["shield", "reflect"]:
		var defense := effect.components[0].duplicate() as DamageDefenseEffectComponent \
				if not effect.components.is_empty() else DamageDefenseEffectComponent.new()
		defense.mode = DamageDefenseEffectComponent.Mode.ABSORB if kind == "shield" \
				else DamageDefenseEffectComponent.Mode.REFLECT
		if kind == "shield":
			defense.capacity = float(values["amount"])
		elif original == null:
			defense.damage_tags = PackedStringArray(["Ability.Spell"])
		effect.components = [defense]
	if kind == "link":
		effect.exclusive_owner_slot = LINK_SLOT
	return effect


static func _apply_phases(execution: PhasedAbilityExecution, model: Dictionary, lanes: Dictionary) -> void:
	var grouped := {}
	for lane: String in EVENTS:
		var actions: Array[AbilityActionDefinition] = []
		actions.assign(lanes[lane])
		if lane == "contact" and not lanes["payload"].is_empty():
			var saved := model["hit_action"] as AbilityApplyEffectsAction
			var payload: Array[GameplayEffectDefinition] = []
			payload.assign(lanes["payload"])
			var apply := saved
			if saved == null or saved.effects != payload:
				apply = saved.duplicate() as AbilityApplyEffectsAction if saved != null else AbilityApplyEffectsAction.new()
				apply.effects = payload
			actions.append(apply)
		grouped[lane] = actions
	var phases: Array[AbilityPhaseDefinition] = []
	var owners: Dictionary = model["owners"]
	for index: int in range(execution.phases.size()):
		var phase := execution.phases[index]
		if not index in owners.values():
			phases.append(phase)
			continue
		var lane: String = owners.find_key(index)
		var actions: Array[AbilityActionDefinition] = grouped[lane]
		if not actions.is_empty():
			if phase.actions != actions:
				phase = phase.duplicate() as AbilityPhaseDefinition
				phase.actions = actions
			phases.append(phase)
	for lane: String in EVENTS:
		if owners.has(lane) or grouped[lane].is_empty():
			continue
		var phase := AbilityPhaseDefinition.new()
		phase.event_key = EVENTS[lane]
		phase.actions.assign(grouped[lane])
		phases.append(phase)
	execution.phases = phases


static func _apply_reactions(ability: AbilityDefinition, lanes: Dictionary) -> void:
	var reactions: Array[ReactionDefinition] = []
	for saved: ReactionDefinition in ability.reactions:
		var lane := _reaction_lane(saved) if saved != null else ""
		if lane.is_empty():
			reactions.append(saved)
		elif not lanes[lane].is_empty():
			reactions.append(lanes[lane].pop_front())
	for lane: String in TRIGGERS:
		reactions.append_array(lanes[lane])
	ability.reactions = reactions
