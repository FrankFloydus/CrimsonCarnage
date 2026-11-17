class_name PlayerStats
extends AbilitySystemComponent
## Owns Carnage's rules for the player's native vitals set.

## Emitted after the live stats initialize or an edit changes them.
signal stats_changed

## Emitted when damage removes health. Reports the actual health points lost after clamping.
signal damage_taken(amount: float)

const VITALS := &"vitals"
const HEALTH := &"health"
const MAX_HEALTH := &"max_health"
const BLOOD := &"blood"
const MAX_BLOOD := &"max_blood"
const BLOOD_DRAIN := &"blood_drain"
const BLOOD_CAP := 300.0

## Health points available at spawn. The player starts at full health.
@export var starting_max_health: float = 100.0
## Blood points the player can hold at spawn, up to 300. The meter starts empty.
@export_range(0.0, 300.0, 1.0) var starting_max_blood: float = 300.0
## Blood points spent each second in Spellcaster form.
@export_range(0.1, 300.0, 0.1, "or_greater", "suffix:points/s") var blood_drain: float = 30.0:
	get:
		return maxf(0.1, _read(BLOOD_DRAIN)) if _vitals != null else blood_drain
	set(value):
		if not is_finite(value):
			return
		var rate := maxf(value, 0.1)
		if _vitals == null:
			blood_drain = rate
		elif _write(BLOOD_DRAIN, rate):
			stats_changed.emit()

@export_group("Fall Damage", "fall_damage_")
## Maximum drop in meters from the airborne peak to touchdown before damage starts.
## Set this above the normal jump height to keep ordinary jumps safe.
@export_range(0.0, 30.0, 0.1, "or_greater", "suffix:m") var fall_damage_safe_distance: float = 3.0
## Health lost for each meter beyond Safe Distance. At 15 HP/m, a 5 m drop with a 3 m safe distance
## costs 30 health. Set this to zero to disable fall damage.
@export_range(0.0, 100.0, 0.5, "or_greater", "suffix:HP/m") var fall_damage_per_meter: float = 15.0

@export_group("Live Vitals")
## Current health points. Inspect this value on the Remote scene tree during play.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY)
var health: float:
	get:
		return _read(HEALTH)
	set(value):
		if is_finite(value) and _write(HEALTH, clampf(value, 0.0, max_health)):
			stats_changed.emit()

## Current health limit. Lowering it also clamps current health.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY)
var max_health: float:
	get:
		return _read(MAX_HEALTH)
	set(value):
		if is_finite(value):
			_set_maximum(HEALTH, MAX_HEALTH, maxf(value, 0.0))

## Current blood points. Inspect this value on the Remote scene tree during play.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY)
var blood: float:
	get:
		return _read(BLOOD)
	set(value):
		if is_finite(value) and _write(BLOOD, clampf(value, 0.0, max_blood)):
			stats_changed.emit()

## Current blood limit, up to 300. Lowering it also clamps current blood.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY)
var max_blood: float:
	get:
		return _read(MAX_BLOOD)
	set(value):
		if is_finite(value):
			_set_maximum(BLOOD, MAX_BLOOD, clampf(value, 0.0, BLOOD_CAP))

var _vitals: GameplayAttributeSet


func _ready() -> void:
	# The native component initializes its attribute source during this notification.
	ready.connect(_initialize_vitals, CONNECT_ONE_SHOT)


func add_blood(amount: float) -> void:
	blood += amount


## Applies damage to current health and returns the actual points lost.
func apply_damage(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0:
		return 0.0
	var previous_health := health
	if not _write(HEALTH, maxf(previous_health - amount, 0.0)):
		return 0.0

	var actual_loss := maxf(previous_health - health, 0.0)
	stats_changed.emit()
	if actual_loss > 0.0:
		damage_taken.emit(actual_loss)
	return actual_loss


## Applies fall damage from the vertical drop in meters measured by Mover.
func apply_fall_damage(drop_distance: float) -> float:
	var excess := maxf(drop_distance - fall_damage_safe_distance, 0.0)
	return apply_damage(excess * fall_damage_per_meter)


func _initialize_vitals() -> void:
	var authored_blood_drain := blood_drain
	_vitals = get_attribute_set(VITALS)
	if _vitals == null:
		push_error("Add the local vitals attribute set to PlayerStats.")
		return
	if is_finite(starting_max_health):
		var health_points := maxf(starting_max_health, 0.0)
		_write(MAX_HEALTH, health_points)
		_write(HEALTH, health_points)
	if is_finite(starting_max_blood):
		_write(MAX_BLOOD, clampf(starting_max_blood, 0.0, BLOOD_CAP))
	_write(BLOOD_DRAIN, authored_blood_drain)
	stats_changed.emit()


func _set_maximum(current: StringName, limit: StringName, maximum: float) -> void:
	var current_changed := _write(current, minf(_read(current), maximum))
	var limit_changed := _write(limit, maximum)
	if current_changed or limit_changed:
		stats_changed.emit()


func _read(attribute: StringName) -> float:
	if _vitals == null:
		return 0.0
	var reading := _vitals.get_attribute(attribute)
	return reading.get_current() if reading != null else 0.0


func _write(attribute: StringName, value: float) -> bool:
	if _vitals == null or _read(attribute) == value:
		return false
	var result := _vitals.set_base(attribute, value)
	if result != OK:
		push_error("Could not set PlayerStats %s: %s" % [attribute, error_string(result)])
	return result == OK
