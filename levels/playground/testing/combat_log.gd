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
		ability = str(event.get("ability_id", "Ability"))
	var effect := str(event.get("effect_name", ""))
	if effect.is_empty():
		effect = str(event.get("effect_id", "Effect"))
	var message := ""
	match StringName(event.get("type", &"")):
		&"cast":
			message = "%s uses %s." % [source, ability]
		&"cast_failed":
			message = "%s cannot use %s: %s." % [
				source, ability, str(event.get("reason", "requirements not met")),
			]
		&"hit_outcome":
			var outcome := StringName(event.get("outcome", &""))
			if outcome in [&"miss", &"resist"]:
				message = "%s → %s: %s %s." % [source, target, ability, str(outcome).to_upper()]
		&"damage":
			message = "%s → %s: %s deals %.1f damage%s." % [
				source, target, ability, float(event.get("amount", 0.0)),
				" (CRITICAL)" if bool(event.get("is_critical", false)) else "",
			]
		&"effect_applied":
			message = "%s gains %s from %s (%s)." % [target, effect, source, ability]
		&"effect_removed":
			message = "%s: %s ends." % [target, effect]
	if message.is_empty():
		return ""
	var timestamp := float(event.get("timestamp", 0.0))
	return "[%02d:%05.2f] %s" % [int(timestamp / 60.0), fmod(timestamp, 60.0), message]
