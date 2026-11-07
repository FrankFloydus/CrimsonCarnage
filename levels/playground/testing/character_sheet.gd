extends PanelContainer
## Read-only combat outcomes for the selected playground actor.

const STAT_LABELS: Dictionary[int, NodePath] = {
	CombatAttributes.Id.STRENGTH: ^"%StrengthValue",
	CombatAttributes.Id.DEXTERITY: ^"%DexterityValue",
	CombatAttributes.Id.INTELLECT: ^"%IntellectValue",
	CombatAttributes.Id.VITALITY: ^"%VitalityValue",
	CombatAttributes.Id.CRITICAL_CHANCE: ^"%CriticalChanceValue",
	CombatAttributes.Id.CRITICAL_DAMAGE: ^"%CriticalDamageValue",
	CombatAttributes.Id.ARMOR_PENETRATION: ^"%ArmorPenetrationValue",
	CombatAttributes.Id.ATTACK_SPEED: ^"%AttackSpeedValue",
	CombatAttributes.Id.CAST_SPEED: ^"%CastSpeedValue",
	CombatAttributes.Id.ARMOR: ^"%PhysicalReductionValue",
	CombatAttributes.Id.FIRE_RESISTANCE: ^"%FireResistanceValue",
	CombatAttributes.Id.COLD_RESISTANCE: ^"%ColdResistanceValue",
	CombatAttributes.Id.LIGHTNING_RESISTANCE: ^"%LightningResistanceValue",
	CombatAttributes.Id.NECROTIC_RESISTANCE: ^"%NecroticResistanceValue",
	CombatAttributes.Id.VOID_RESISTANCE: ^"%VoidResistanceValue",
	CombatAttributes.Id.MOVEMENT_SPEED: ^"%MovementSpeedValue",
}
const RESOURCE_ROWS := {
	CombatAttributes.Id.HEALTH: [^"%HealthValue", ^"%HealthRegenValue", ^"%HealthBar"],
	CombatAttributes.Id.STAMINA: [^"%StaminaValue", ^"%StaminaRegenValue", ^"%StaminaBar"],
	CombatAttributes.Id.MANA: [^"%ManaValue", ^"%ManaRegenValue", ^"%ManaBar"],
}
# Outgoing values use the selected ability. Pools, defenses and mobility use actor totals.
const ACTION_STATS: Array[int] = [
	CombatAttributes.Id.STRENGTH,
	CombatAttributes.Id.DEXTERITY,
	CombatAttributes.Id.INTELLECT,
	CombatAttributes.Id.VITALITY,
	CombatAttributes.Id.CRITICAL_CHANCE,
	CombatAttributes.Id.CRITICAL_DAMAGE,
	CombatAttributes.Id.ARMOR_PENETRATION,
]

var _value_labels: Dictionary[int, Label] = {}
var _resource_bars: Dictionary[int, ProgressBar] = {}

@onready var _actor_title: Label = %ActorTitle
@onready var _actor_level: Label = %ActorLevel
@onready var _encumbered: Label = %Encumbered
@onready var _carry_load_value: Label = %CarryLoadValue
@onready var _movement_penalty_row: HBoxContainer = %MovementSpeedPenalty
@onready var _movement_penalty_value: Label = %MovementSpeedPenaltyValue
@onready var _jump_penalty_row: HBoxContainer = %JumpHeightPenalty
@onready var _jump_penalty_value: Label = %JumpHeightPenaltyValue
@onready var _scroll: ScrollContainer = $Layout/Scroll
@onready var _unavailable: Label = %Unavailable
@onready var _matchup: PanelContainer = %Matchup
@onready var _matchup_ability: Label = %MatchupAbility
@onready var _success_label: Label = %SuccessLabel
@onready var _success_value: Label = %SuccessValue
@onready var _failure_label: Label = %FailureLabel
@onready var _failure_value: Label = %FailureValue
@onready var _hit_damage_cell: VBoxContainer = %HitDamage
@onready var _hit_damage_label: Label = %HitDamageLabel
@onready var _hit_damage_value: Label = %HitDamageValue


func _ready() -> void:
	_value_labels[CombatAttributes.Id.CARRIED_WEIGHT] = _carry_load_value
	_value_labels[CombatAttributes.Id.CARRY_CAPACITY] = _carry_load_value
	for id: int in STAT_LABELS:
		var label := get_node(STAT_LABELS[id]) as Label
		_value_labels[id] = label
		_set_row_tooltip(label, CombatAttributes.description(id))
	for id: int in RESOURCE_ROWS:
		var paths: Array = RESOURCE_ROWS[id]
		var amount := get_node(paths[0]) as Label
		var rate := get_node(paths[1]) as Label
		var maximum_id := CombatAttributes.maximum_for(id)
		var regen_id := CombatAttributes.regeneration_for(id)
		_value_labels[id] = amount
		_value_labels[maximum_id] = amount
		_value_labels[regen_id] = rate
		_resource_bars[id] = get_node(paths[2]) as ProgressBar
		_set_row_tooltip(amount, "%s\n\n%s" % [
			CombatAttributes.description(id),
			CombatAttributes.description(maximum_id),
		])
		rate.tooltip_text = CombatAttributes.description(regen_id)


## Renders the current actor and a separate player-versus-dummy ability preview.
## Matchup chance and ceiling are fractions from zero to one.
func refresh(
		system: AbilitySystem,
		tags: PackedStringArray,
		actor_name: String,
		matchup: Dictionary,
		movement: FirstPersonMovement = null
) -> void:
	if not is_node_ready():
		return
	_actor_title.text = actor_name
	var attributes := system.attributes if is_instance_valid(system) else null
	var has_actor := is_instance_valid(attributes)
	_actor_level.visible = has_actor
	_scroll.visible = has_actor
	_unavailable.visible = not has_actor
	_matchup.visible = has_actor and not matchup.is_empty()
	var show_penalties := has_actor and is_instance_valid(movement) \
			and movement.attributes == attributes
	_movement_penalty_row.visible = show_penalties
	_jump_penalty_row.visible = show_penalties
	if not has_actor:
		_encumbered.hide()
		return
	_actor_level.text = "Lv. %d" % attributes.level
	_refresh_resources(attributes)
	_refresh_carry_load(attributes, system.tags.has_tag(&"State.Encumbered"))
	if show_penalties:
		var factors := movement.get_encumbrance_factors()
		var movement_penalty := snappedf((factors.x - 1.0) * 100.0, 0.01)
		var jump_penalty := snappedf((factors.y - 1.0) * 100.0, 0.01)
		_movement_penalty_value.text = _format_value(movement_penalty) + "%"
		_jump_penalty_value.text = _format_value(jump_penalty) + "%"
	for id: int in STAT_LABELS:
		var value := attributes.get_value(id, tags) if id in ACTION_STATS else attributes.get_value(id)
		var label := _value_labels[id]
		if id == CombatAttributes.Id.ARMOR:
			label.text = _format_chance(CombatMath.get_armor_reduction(value))
			_set_row_tooltip(label, "Armor rating %s\nBefore incoming Armor Penetration." % _format_value(value))
		elif id == CombatAttributes.Id.CRITICAL_DAMAGE:
			var multiplier_percent := CombatMath.get_critical_multiplier(value) * 100.0
			label.text = _format_value(multiplier_percent) + "%"
			_set_row_tooltip(label, "Critical Damage bonus %s%%\nTotal damage multiplier on a critical hit."
					% _format_value(value))
		else:
			var suffix := "%" if CombatAttributes.uses_percentage_units(id) else ""
			label.text = _format_value(value) + suffix
	if _matchup.visible:
		_refresh_matchup(matchup)


## Returns the visible value for an attribute. Armor and Critical Damage use combat outcomes.
## Pool pairs and carried weight/capacity share a label. Preview ratings have no row.
func get_value_label(attribute: int) -> Label:
	return _value_labels.get(attribute)


func _refresh_resources(attributes: ActorAttributes) -> void:
	for id: int in RESOURCE_ROWS:
		var current := attributes.get_value(id)
		var maximum := attributes.get_value(CombatAttributes.maximum_for(id))
		var regen_id := CombatAttributes.regeneration_for(id)
		var regen := attributes.get_value(regen_id)
		var fraction := clampf(current / maximum, 0.0, 1.0) if maximum > 0.0 else 0.0
		_value_labels[id].text = "%s / %s" % [
			_format_value(current),
			_format_value(maximum),
		]
		_value_labels[regen_id].text = "%s /s" % _format_value(regen)
		_resource_bars[id].set_value_no_signal(fraction)


func _refresh_carry_load(attributes: ActorAttributes, encumbered: bool) -> void:
	var weight := attributes.get_value(CombatAttributes.Id.CARRIED_WEIGHT)
	var capacity := attributes.get_value(CombatAttributes.Id.CARRY_CAPACITY)
	_carry_load_value.text = "%s / %s" % [_format_value(weight), _format_value(capacity)]
	_encumbered.visible = encumbered
	_set_row_tooltip(_carry_load_value, "Carry load %s\n%s" % [
		_carry_load_value.text,
		_encumbered.tooltip_text,
	])


func _refresh_matchup(matchup: Dictionary) -> void:
	var spell := bool(matchup.get("spell", false))
	var chance := float(matchup.get("hit_chance", 0.0))
	_matchup_ability.text = str(matchup.get("ability_name", ""))
	_matchup_ability.tooltip_text = "%s · Player Lv. %d → Dummy Lv. %d" % [
		_matchup_ability.text,
		int(matchup.get("source_level", 1)),
		int(matchup.get("target_level", 1)),
	]
	_failure_label.text = "Resist" if spell else "Miss"
	_success_value.text = _format_chance(chance)
	_failure_value.text = _format_chance(1.0 - chance)
	var hit_tooltip := "Accuracy rating %s\nLevel ceiling %s" % [
		_format_value(float(matchup.get("accuracy_rating", 0.0))),
		_format_chance(float(matchup.get("max_chance", 0.0))),
	]
	_success_label.tooltip_text = hit_tooltip
	_success_value.tooltip_text = hit_tooltip
	_hit_damage_cell.visible = matchup.has("hit_damage_min") and matchup.has("hit_damage_max")
	if not _hit_damage_cell.visible:
		return
	var minimum := _format_value(float(matchup["hit_damage_min"]))
	var maximum := _format_value(float(matchup["hit_damage_max"]))
	_hit_damage_value.text = minimum if minimum == maximum else "%s–%s" % [minimum, maximum]
	var damage_tooltip := "Normal hit %s\nDamage after the dummy's defenses." % _hit_damage_value.text
	var power_details := str(matchup.get("hit_damage_power_details", ""))
	if not power_details.is_empty():
		damage_tooltip += "\n" + power_details
	_hit_damage_label.tooltip_text = damage_tooltip
	_hit_damage_value.tooltip_text = damage_tooltip


static func _set_row_tooltip(value_label: Label, description: String) -> void:
	value_label.tooltip_text = description
	(value_label.get_parent().get_node("Name") as Label).tooltip_text = description


static func _format_chance(chance: float) -> String:
	var percentage := chance * 100.0
	if percentage > 0.0 and percentage < 0.01:
		return "<0.01%"
	if chance < 1.0 and percentage > 99.99:
		return ">99.99%"
	return _format_value(snappedf(percentage, 0.01)) + "%"


static func _format_value(value: float) -> String:
	return LiveAttributeEditorRow.format_value(value).trim_suffix(".0")
