class_name GameplayEffectContext
extends RefCounted
## Source identity and weak live attributes, with launch-time fallbacks for detached payloads.

var source_id: int = 0
var source_name: String = ""
## Optional source of the ability or effect, such as the Resource that supplied its grant.
var source_object: Object
## Authored ability identity, or zero for a payload without an ability.
var ability_id: int = 0
var ability_name: String = ""
var ability_tags := PackedStringArray()
## Per-execution identity shared with detached descendants.
var outcome_context: CombatOutcomeContext
## Optional collision geometry available to impact executions and Gameplay Cues.
var hit_position: Vector3 = Vector3.ZERO
var hit_normal: Vector3 = Vector3.ZERO
var has_hit_result: bool = false
## Snapshot of the weapon's authored base cycle, independent of flight time or extra holding.
var weapon_power_coefficient: float = 0.0
## Resolved once for one delivered damaging Hit; fresh casts/deliveries start noncritical.
var is_critical: bool = false
## Applied Hit multiplier. Normal Hits use 1; critical Hits include the base and bonus.
var critical_multiplier: float = 1.0
## Applied bonus percentage points, excluding the base critical multiplier; normal Hits use zero.
var critical_damage_percent: float = 0.0

var source_level: int:
	get:
		var source := _get_source()
		return source.level if source != null else _fallback_level

var _source_attributes: WeakRef
var _source_system: WeakRef
var _source_tags: GameplayTagSet
var _fallback_level: int = 1
var _fallback_values: Dictionary = {}
var _scoped_fallbacks: Dictionary = {}
var _has_physical_weapon: bool = false
var _weapon_damage_min: float = 0.0
var _weapon_damage_max: float = 0.0
var _weapon_damage_roll: float = 0.5


static func capture(
		source_attributes: ActorAttributes,
		source_tags: GameplayTagSet,
		context_tags: PackedStringArray = PackedStringArray()
) -> GameplayEffectContext:
	var context := GameplayEffectContext.new()
	context.outcome_context = CombatOutcomeContext.create(source_attributes)
	context.ability_tags = context_tags.duplicate()
	context._source_tags = source_tags
	if is_instance_valid(source_attributes):
		context._source_attributes = weakref(source_attributes)
		context.source_id = source_attributes.get_instance_id()
		context.source_name = actor_name(source_attributes)
		context._fallback_level = source_attributes.level
		for id: int in CombatAttributes.all_ids():
			context._fallback_values[id] = source_attributes.get_value(id, context_tags)
	return context


## Creates detached event values so feedback does not retain actor nodes or shared resources.
func create_combat_event(
		event_type: StringName,
		target: ActorAttributes,
		definition: GameplayEffectDefinition = null
) -> Dictionary:
	var event := {
		"type": event_type,
		"source_id": source_id,
		"target_id": target.get_instance_id() if is_instance_valid(target) else 0,
		"source_name": source_name,
		"target_name": actor_name(target),
		"ability_id": ability_id,
		"ability_name": ability_name,
		"ability_tags": ability_tags.duplicate(),
		"effect_id": 0,
		"effect_name": "",
		"amount": 0.0,
		"resolved_amount": 0.0,
		"health_damage": 0.0,
		"damage_type": -1,
		"magic_school": -1,
		"outcome": &"",
		"is_critical": false,
		"critical_multiplier": 1.0,
		"critical_damage_percent": 0.0,
	}
	if definition == null or definition.is_damage_effect():
		event["is_critical"] = is_critical
		event["critical_multiplier"] = critical_multiplier if is_critical else 1.0
		event["critical_damage_percent"] = critical_damage_percent if is_critical else 0.0
	if definition != null:
		event["effect_id"] = definition.effect_id
		event["effect_name"] = definition.display_name
		event["damage_type"] = definition.damage_type
		if definition.get_resistance_attribute() != CombatAttributes.Id.NONE:
			event["magic_school"] = definition.magic_school
	if has_hit_result:
		event["hit_position"] = hit_position
		event["hit_normal"] = hit_normal
	if outcome_context != null:
		outcome_context.add_attribution(event)
	return event


static func actor_name(actor: ActorAttributes) -> String:
	if not is_instance_valid(actor):
		return ""
	var owner_node := actor.get_parent()
	return str(owner_node.name) if owner_node != null else str(actor.name)


## Spell delivery is authored by Ability.Spell independently of the effect's damage type.
static func is_spell_delivery(context_tags: PackedStringArray) -> bool:
	for tag: String in context_tags:
		if tag == "Ability.Spell" or tag.begins_with("Ability.Spell."):
			return true
	return false


## Copies weapon values into this cast so editing a shared profile cannot alter a flying arrow.
func bind_weapon(weapon: WeaponDefinition) -> void:
	_has_physical_weapon = false
	weapon_power_coefficient = 0.0
	_weapon_damage_min = 0.0
	_weapon_damage_max = 0.0
	_weapon_damage_roll = 0.5
	if weapon == null:
		return
	for index in range(ability_tags.size() - 1, -1, -1):
		var tag := ability_tags[index]
		if AttributeModifier._has_match(PackedStringArray([tag]), "Weapon.Finesse") \
				or AttributeModifier._has_match(PackedStringArray([tag]), "Weapon.Brutality") \
				or AttributeModifier._has_match(PackedStringArray([tag]), "Weapon.Caster") \
				or AttributeModifier._has_match(PackedStringArray([tag]), "Weapon.Bow"):
			ability_tags.remove_at(index)
	for tag in weapon.get_context_tags():
		if not ability_tags.has(tag):
			ability_tags.append(tag)
	if weapon.get_physical_attack_error().is_empty():
		_has_physical_weapon = true
		_weapon_damage_min = weapon.physical_damage_min
		_weapon_damage_max = weapon.physical_damage_max
		weapon_power_coefficient = weapon.get_power_coefficient()
	cache_source_values(ability_tags)


func has_physical_weapon() -> bool:
	return _has_physical_weapon


## One stable min/max roll is shared by the physical components of a delivered Hit.
func get_weapon_base_damage() -> float:
	return lerpf(_weapon_damage_min, _weapon_damage_max, _weapon_damage_roll)


func prime_effects(definitions: Array[GameplayEffectDefinition]) -> void:
	cache_source_values(ability_tags)
	for definition in definitions:
		if definition != null:
			var context_tags := definition.get_context_tags(ability_tags)
			cache_source_values(context_tags)


## Copies source identity/fallbacks, resets critical state and samples the new Hit's weapon roll.
func duplicate_for_hit(weapon_roll: float = -1.0) -> GameplayEffectContext:
	var context := GameplayEffectContext.new()
	context.source_id = source_id
	context.source_name = source_name
	if is_instance_valid(source_object):
		context.source_object = source_object
	context.ability_id = ability_id
	context.ability_name = ability_name
	context.ability_tags = ability_tags.duplicate()
	context.outcome_context = outcome_context
	context.hit_position = hit_position
	context.hit_normal = hit_normal
	context.has_hit_result = has_hit_result
	context._source_attributes = _source_attributes
	context._source_system = _source_system
	context._source_tags = _source_tags
	context._fallback_level = _fallback_level
	context._fallback_values = _fallback_values.duplicate(true)
	context._scoped_fallbacks = _scoped_fallbacks.duplicate(true)
	context._has_physical_weapon = _has_physical_weapon
	context._weapon_damage_min = _weapon_damage_min
	context._weapon_damage_max = _weapon_damage_max
	context.weapon_power_coefficient = weapon_power_coefficient
	context._weapon_damage_roll = clampf(weapon_roll, 0.0, 1.0) if weapon_roll >= 0.0 else randf()
	return context


## Returns the originating system while it still exists. Payloads do not keep actors alive.
func get_source_system() -> AbilitySystem:
	return _source_system.get_ref() as AbilitySystem if _source_system != null else null


## Captures current source values for an effect while target defenses remain live.
func with_snapshotted_source(context_tags: PackedStringArray) -> GameplayEffectContext:
	var context := with_critical_result(is_critical, critical_multiplier, critical_damage_percent)
	context.cache_source_values(ability_tags)
	context.cache_source_values(context_tags)
	context._source_attributes = null
	return context


## Copies a resolved critical outcome for one payload without rerolling its existing weapon sample.
## Direct explicit damage may use this resolved context; modifier events stay noncritical.
func with_critical_result(
		critical: bool, multiplier: float = 1.0, damage_bonus: float = 0.0
) -> GameplayEffectContext:
	var context := duplicate_for_hit(_weapon_damage_roll)
	context.is_critical = critical
	context.critical_multiplier = multiplier if critical else 1.0
	context.critical_damage_percent = damage_bonus if critical else 0.0
	return context


func cache_source_values(context_tags: PackedStringArray) -> void:
	var source := _get_source()
	if source != null:
		_scoped_fallbacks[_scope_key(context_tags)] = _capture_values(source, context_tags)
		_fallback_level = source.level


func get_source_value(
		attribute: int, context_tags: PackedStringArray = PackedStringArray()
) -> float:
	var source := _get_source()
	if source != null:
		return source.get_value(attribute, context_tags)
	var key := _scope_key(context_tags)
	var values: Dictionary = _scoped_fallbacks.get(key, _fallback_values)
	return float(values.get(attribute, 0.0))


func get_source_tags() -> PackedStringArray:
	return _source_tags.get_tags() if _source_tags != null else PackedStringArray()


func _get_source() -> ActorAttributes:
	if _source_attributes == null:
		return null
	return _source_attributes.get_ref() as ActorAttributes


func _capture_values(actor: ActorAttributes, context_tags: PackedStringArray) -> Dictionary:
	var values: Dictionary = {}
	for id: int in CombatAttributes.all_ids():
		values[id] = actor.get_value(id, context_tags)
	return values


func _scope_key(context_tags: PackedStringArray) -> String:
	var ordered := PackedStringArray()
	for tag in context_tags:
		if not ordered.has(tag):
			ordered.append(tag)
	ordered.sort()
	return JSON.stringify(ordered)
