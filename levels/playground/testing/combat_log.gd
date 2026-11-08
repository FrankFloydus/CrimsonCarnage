class_name CombatLogPanel
extends PanelContainer
## Bounded combat history; showing it never changes the combat simulation.

var recorder: CombatTestRecorder
var _rebuild_queued: bool = false

@onready var _lines: RichTextLabel = $Margin/Content/Lines
@onready var _follow: CheckBox = $Margin/Content/Toolbar/Follow


func _ready() -> void:
	$Margin/Content/Toolbar/Clear.pressed.connect(_clear_log)
	_follow.toggled.connect(_set_follow)
	_rebuild()


func bind_recorder(value: CombatTestRecorder) -> void:
	if recorder != null:
		if recorder.event_recorded.is_connected(_on_event_recorded):
			recorder.event_recorded.disconnect(_on_event_recorded)
		if recorder.log_cleared.is_connected(_rebuild):
			recorder.log_cleared.disconnect(_rebuild)
	recorder = value
	if recorder != null:
		recorder.event_recorded.connect(_on_event_recorded)
		recorder.log_cleared.connect(_rebuild)
	if is_node_ready():
		_rebuild()


func _on_event_recorded(_event: Dictionary) -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	_flush_pending_events.call_deferred()


func _flush_pending_events() -> void:
	_rebuild_queued = false
	_rebuild()


func _rebuild() -> void:
	if not is_node_ready():
		return
	var scroll_position := _lines.get_v_scroll_bar().value
	_lines.clear()
	if recorder != null:
		for event: Dictionary in recorder.get_log():
			var line := format_event(event)
			if not line.is_empty():
				_lines.add_text(line + "\n")
	if not _follow.button_pressed:
		_lines.get_v_scroll_bar().set_deferred("value", scroll_position)


func _set_follow(enabled: bool) -> void:
	_lines.scroll_following = enabled
	if enabled:
		_lines.scroll_to_line(maxi(0, _lines.get_line_count() - 1))


func _clear_log() -> void:
	if recorder != null:
		recorder.clear_log()


static func format_event(event: Dictionary) -> String:
	var source := str(event.get("source_name", "Unknown"))
	var target := str(event.get("target_name", "Unknown"))
	var ability := str(event.get("ability_name", ""))
	if ability.is_empty():
		var ability_id := int(event.get("ability_id", 0))
		ability = "Ability %d" % ability_id if ability_id > 0 else "Ability"
	var effect := str(event.get("effect_name", ""))
	if effect.is_empty():
		var effect_id := int(event.get("effect_id", 0))
		effect = "Effect %d" % effect_id if effect_id > 0 else "Effect"
	var message := ""
	match StringName(event.get("type", &"")):
		&"cast":
			message = "%s uses %s." % [source, ability]
		&"cast_failed":
			message = "%s cannot use %s: %s." % [
				source, ability, str(event.get("reason", "requirements not met")),
			]
			if event.has("actor_tags"):
				message += " Actor tags: %s." % ", ".join(event["actor_tags"])
		&"cast_reserved":
			message = "%s reserves %s for %s." % [source, _describe_resources(event), ability]
		&"cast_spent", &"cast_refunded":
			var verb := "spends" if event["type"] == &"cast_spent" else "recovers"
			message = "%s %s %s for %s." % [source, verb, _describe_resources(event), ability]
		&"cast_phase":
			message = "%s: %s phase %s." % [source, ability, str(event.get("phase_key", ""))]
		&"target_batch":
			message = "%s: %s selected %d targets (%s)." % [
				source, ability, int(event.get("target_count", 0)),
				str(event.get("reason", &"complete")),
			]
		&"cast_ended":
			message = "%s: %s ends (%s)." % [source, ability, str(event.get("reason", ""))]
		&"hit_outcome":
			var outcome := StringName(event.get("outcome", &""))
			message = "%s → %s: %s %s." % [source, target, ability, str(outcome).to_upper()]
		&"damage":
			message = "%s → %s: %s deals %.1f damage%s." % [
				source, target, ability, float(event.get("amount", 0.0)),
				" (CRITICAL)" if bool(event.get("is_critical", false)) else "",
			]
			var blocked := float(event.get("blocked_amount", 0.0))
			var absorbed := float(event.get("absorbed_amount", 0.0))
			var resisted := float(event.get("effective_resistance_percent", 0.0))
			var armor := float(event.get("effective_armor", 0.0))
			if blocked != 0.0 or absorbed != 0.0 or resisted != 0.0 or armor != 0.0:
				message += " Armor %.1f, resistance %.1f%%, blocked %.1f, absorbed %.1f." % [
					armor, resisted, blocked, absorbed,
				]
		&"effect_applied":
			message = "%s gains %s from %s (%s)." % [target, effect, source, ability]
		&"effect_removed":
			var reason := int(event.get("removal_reason", -1))
			var reasons := GameplayEffectRuntime.RemovalReason.keys()
			var label := str(reasons[reason]).to_lower() if reason >= 0 and reason < reasons.size() \
					else "removed"
			message = "%s: %s ends (%s)." % [target, effect, label]
		&"status_rejected", &"effect_rejected":
			message = "%s rejects %s (%s)." % [target, effect, str(event.get("outcome", ""))]
		&"healing":
			message = "%s: %s restores %.1f Health (%.1f overheal)." % [
				target, ability, float(event.get("actual_restoration", 0.0)),
				float(event.get("overheal", 0.0)),
			]
		&"resource":
			var pool := AmountDefinition.pool_attribute(int(event.get("resource", -1)))
			message = "%s: %s changes %s by %+.1f." % [
				target, ability, CombatAttributes.display_name(pool),
				float(event.get("actual_delta", 0.0)),
			]
		&"reaction_suppressed":
			message = "%s reaction skipped (%s)." % [ability, str(event.get("reason", ""))]
	if message.is_empty():
		return ""
	var root_id := int(event.get("root_execution_id", 0))
	if root_id > 0:
		message += " [cast %d" % root_id
		for field in ["event_id", "parent_event_id", "handle"]:
			var value := int(event.get(field, 0))
			if value > 0:
				message += ", %s %d" % [field.trim_suffix("_id"), value]
		message += "]"
	var timestamp := float(event.get("timestamp", 0.0))
	return "[%02d:%05.2f] %s" % [int(timestamp / 60.0), fmod(timestamp, 60.0), message]


static func _describe_resources(event: Dictionary) -> String:
	var entries := PackedStringArray()
	var resources: Dictionary = event.get("resources", {})
	for attribute: int in resources:
		entries.append("%.2f %s" % [resources[attribute], CombatAttributes.display_name(attribute)])
	if event.get("reserved_charge", false):
		entries.append("one charge")
	return ", ".join(entries)
