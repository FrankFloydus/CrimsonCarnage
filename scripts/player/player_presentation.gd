class_name PlayerPresentation
extends Node
## Plays screen effects and displays combat feedback for a first-person player.

const DashSpeedStreaks := preload("res://scripts/effects/dash_speed_streaks.gd")

## Player transform used for the position and horizontal bearing of incoming hits.
@export var observer: Node3D

var _painterly_preview_enabled: bool = true
var _combat_stats: PlayerStats
var _spellcaster_active: bool = false

@onready var _dash_speed_streaks: DashSpeedStreaks = $ScreenEffects/DashSpeedStreaks
@onready var _damage_vignette: DamageVignette = $ScreenEffects/DamageVignette
@onready var _lens_blood: LensBlood = $ScreenEffects/LensBlood
@onready var _post_process_pass: ColorRect = $ScreenEffects/PostProcessing/Pass
@onready var _damage_indicator: DamageIndicator = $HUD/DamageIndicator
@onready var _combat_hud: VBoxContainer = $HUD/CombatStats
@onready var _health_label: Label = $HUD/CombatStats/HealthLabel
@onready var _health_bar: ProgressBar = $HUD/CombatStats/HealthBar
@onready var _blood_label: Label = $HUD/CombatStats/BloodLabel
@onready var _blood_bar: ProgressBar = $HUD/CombatStats/BloodBar


func _ready() -> void:
	_damage_indicator.observer = observer


## Displays the current health and blood for this player.
func bind_combat_stats(stats: PlayerStats) -> void:
	if is_instance_valid(_combat_stats):
		if _combat_stats.stats_changed.is_connected(_refresh_combat_stats):
			_combat_stats.stats_changed.disconnect(_refresh_combat_stats)
		if _combat_stats.damage_taken.is_connected(_on_damage_taken):
			_combat_stats.damage_taken.disconnect(_on_damage_taken)
	_combat_stats = stats
	_combat_hud.visible = is_instance_valid(stats)
	if _combat_hud.visible:
		_combat_stats.stats_changed.connect(_refresh_combat_stats)
		_combat_stats.damage_taken.connect(_on_damage_taken)
		_refresh_combat_stats()
	else:
		_damage_vignette.set_health_fraction(1.0)


## Updates the blood readout to match the player's current form.
func set_spellcaster_active(active: bool) -> void:
	_spellcaster_active = active
	if is_instance_valid(_combat_stats):
		_refresh_combat_stats()


func _refresh_combat_stats() -> void:
	var health := _combat_stats.health
	var max_health := _combat_stats.max_health
	_health_bar.max_value = max_health
	_health_bar.value = health
	_health_label.text = "Health %.0f / %.0f" % [health, max_health]
	_damage_vignette.set_health_fraction(health / max_health if max_health > 0.0 else 1.0)
	_blood_bar.max_value = _combat_stats.max_blood
	_blood_bar.value = _combat_stats.blood
	var blood_title := "Spellcaster - Blood" if _spellcaster_active else "Blood"
	_blood_label.text = "%s %.0f / %.0f" % [blood_title, _combat_stats.blood, _combat_stats.max_blood]


## Starts or releases the screen-space dash distortion.
func set_dash_active(active: bool, local_direction: Vector2) -> void:
	_dash_speed_streaks.set_dash_active(active, local_direction)


## Plays the incoming damage vignette.
func pulse_damage_vignette() -> void:
	_damage_vignette.pulse()


## Sets the low-health warning preference and reevaluates the current health immediately.
func set_low_health_pulse_enabled(enabled: bool) -> void:
	_damage_vignette.low_health_pulse_enabled = enabled


func _on_damage_taken(_amount: float) -> void:
	pulse_damage_vignette()


## Plays a splatter on the first-person view.
func play_lens_blood() -> void:
	_lens_blood.play_splatter()


## Shows a damage indicator for a hit from the given world position.
func show_incoming_hit(source_position: Vector3) -> void:
	_damage_indicator.show_hit(source_position)


## Toggles the painterly filter on the active post-processing pass.
func toggle_painterly_preview() -> void:
	_painterly_preview_enabled = not _painterly_preview_enabled
	_post_process_pass.set_instance_shader_parameter(&"painterly_preview_enabled", _painterly_preview_enabled)
