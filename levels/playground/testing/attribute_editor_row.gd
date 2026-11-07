class_name LiveAttributeEditorRow
extends HBoxContainer
## A saved reusable row for a live testing override or current resource amount.

signal override_changed(attribute: int, value: float, enabled: bool)

var attribute: int = CombatAttributes.Id.NONE
var _is_current: bool = false
var _test_range: Vector2 = Vector2(0.0, 100.0)
var _refreshing: bool = false

@onready var override_toggle: CheckBox = $ToggleSlot/Override
@onready var name_label: Label = $Controls/Heading/Name
@onready var value_label: Label = $Controls/Heading/Value
@onready var base_slider: HSlider = $Controls/Base


func _ready() -> void:
	override_toggle.toggled.connect(_on_override_toggled)
	base_slider.value_changed.connect(_on_value_changed)


func configure(id: int, test_range: Vector2) -> void:
	attribute = id
	_is_current = CombatAttributes.is_current_resource(id)
	_test_range = test_range
	base_slider.step = step_for_attribute(id)
	name_label.text = CombatAttributes.display_name(id)
	name_label.tooltip_text = CombatAttributes.description(id)
	override_toggle.visible = not _is_current
	override_toggle.disabled = _is_current
	override_toggle.set_pressed_no_signal(_is_current)
	override_toggle.tooltip_text = "Override the base value for this test."
	base_slider.tooltip_text = "Current amount, limited by its capacity." if _is_current \
			else "Base value before flat, increased and more modifiers."
	base_slider.editable = _is_current
	if id in [CombatAttributes.Id.ATTACK_SPEED, CombatAttributes.Id.CAST_SPEED]:
		base_slider.tooltip_text = "Release at the upper end to expand the slider range."
		if not base_slider.drag_ended.is_connected(_on_speed_drag_ended):
			base_slider.drag_ended.connect(_on_speed_drag_ended)


## The supplied maximum is exact for a current pool. A positive hint extends other tracks.
func refresh(base_value: float, enabled: bool, override_value: float, track_maximum: float = 0.0) -> void:
	var shown_value := override_value if enabled and not _is_current else base_value
	# Range bound setters may emit value_changed when the thumb is clamped.
	_refreshing = true
	override_toggle.set_pressed_no_signal(enabled or _is_current)
	base_slider.editable = enabled or _is_current
	if _is_current:
		base_slider.min_value = 0.0
		base_slider.max_value = track_maximum
	else:
		var minimum := minf(_test_range.x, floorf(minf(base_value, shown_value)))
		var maximum := maxf(_test_range.y, ceilf(maxf(base_value, shown_value)))
		if track_maximum > 0.0:
			maximum = maxf(maximum, track_maximum)
		# Keep the expanded track stable until the override is cleared.
		base_slider.min_value = minf(minimum, base_slider.min_value) if enabled else minimum
		base_slider.max_value = maxf(maximum, base_slider.max_value) if enabled else maximum
	base_slider.set_value_no_signal(shown_value)
	_set_display_value(shown_value)
	_refreshing = false


static func step_for_attribute(id: int) -> float:
	match id:
		CombatAttributes.Id.STRENGTH, CombatAttributes.Id.DEXTERITY, \
				CombatAttributes.Id.INTELLECT, CombatAttributes.Id.VITALITY:
			return 1.0
	return 0.01


static func format_value(value: float) -> String:
	if absf(value) >= 1000000.0 or (value != 0.0 and absf(value) < 0.001):
		return String.num_scientific(value)
	return String.num(value, 3)


func _on_override_toggled(enabled: bool) -> void:
	base_slider.editable = enabled
	override_changed.emit(attribute, base_slider.value, enabled)


func _on_value_changed(value: float) -> void:
	if _refreshing:
		return
	if _is_current or override_toggle.button_pressed:
		_set_display_value(value)
		override_changed.emit(attribute, value, true)


func _on_speed_drag_ended(_value_changed: bool) -> void:
	if base_slider.editable and base_slider.value >= base_slider.max_value - base_slider.step * 0.5:
		var expanded := base_slider.max_value * 2.0
		if is_finite(expanded):
			base_slider.max_value = expanded


func _set_display_value(value: float) -> void:
	var units := "%" if CombatAttributes.uses_percentage_units(attribute) else ""
	var displayed := roundf(value) if base_slider.step == 1.0 else value
	value_label.text = format_value(displayed).trim_suffix(".0") + units
	value_label.tooltip_text = value_label.text
