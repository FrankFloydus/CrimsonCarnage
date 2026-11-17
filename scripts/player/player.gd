class_name Player
extends CharacterBody3D
## Boots native controls and routes combat input to the active form.

enum CombatForm { DUAL_SWORDS, SPELLCASTER }

const WeaponControl := preload("res://scripts/melee/first_person_melee.gd")
const LOCOMOTION_MAP := &"Locomotion"
const MELEE_SLASH := &"melee_slash"
const ACTIVATE_SPELLCASTER := &"activate_spellcaster"
const BLOOD_PER_SWING := 50.0

var combat_form: CombatForm = CombatForm.DUAL_SWORDS

var _controls: Controls
var _locomotion_active := false
var _left_sword_was_visible := true

@onready var _mover: MoverComponent = $Mover
@onready var _controls_setup: ControlsComponent = $Controls
@onready var _look: FirstPersonLook = $Look
@onready var _weapon: WeaponControl = $Look/Camera3D/WeaponControl
@onready var _left_sword_mount: Node3D = $Look/Camera3D/LeftWeaponControl
@onready var _stats: PlayerStats = $Stats
@onready var _presentation: PlayerPresentation = $PlayerPresentation


func _ready() -> void:
	_presentation.bind_combat_stats(_stats)
	_weapon.swing_started.connect(_on_swing_started)
	var control := _controls_setup.boot(_look, null, _look.apply_aim)
	if control == null or not control.is_ready():
		return
	_controls = control.controls()
	var movement := control.mover()
	movement.landed.connect(_weapon.play_landing_motion)
	movement.landed.connect(_on_landed)
	var camera: Camera3D = _look.get_node(^"Camera3D")
	_mover.boot_stair_smoothing(camera, _look.get_base_camera_position())
	_update_locomotion_enabled()


func _physics_process(delta: float) -> void:
	if _controls == null:
		return
	_update_locomotion_enabled()
	if combat_form == CombatForm.SPELLCASTER:
		_stats.add_blood(-_stats.blood_drain * delta)
		if is_zero_approx(_stats.blood):
			_stats.blood = 0.0
			_set_combat_form(CombatForm.DUAL_SWORDS)
	elif _locomotion_active:
		_process_sword_input()


func _process_sword_input() -> void:
	if _controls.pressed(ACTIVATE_SPELLCASTER) and _stats.blood >= PlayerStats.BLOOD_CAP:
		_set_combat_form(CombatForm.SPELLCASTER)
	elif _controls.pressed(MELEE_SLASH):
		_weapon.request_slash()


func _set_combat_form(form: CombatForm) -> void:
	combat_form = form
	var spellcaster_active := form == CombatForm.SPELLCASTER
	_weapon.set_sword_form_active(not spellcaster_active)
	if spellcaster_active:
		_left_sword_was_visible = _left_sword_mount.visible
		_left_sword_mount.hide()
		_look.attack_camera_motion = Transform3D.IDENTITY
	else:
		_left_sword_mount.visible = _left_sword_was_visible
	_presentation.set_spellcaster_active(spellcaster_active)


func _on_swing_started() -> void:
	if combat_form == CombatForm.DUAL_SWORDS:
		_stats.add_blood(BLOOD_PER_SWING)


func _on_landed(_impact_speed: float) -> void:
	var movement := _mover.mover()
	if movement != null:
		_stats.apply_fall_damage(movement.get_last_fall_distance())


func _update_locomotion_enabled() -> void:
	var active := _controls.pointer_captured()
	if active != _locomotion_active and _controls.set_map_enabled(LOCOMOTION_MAP, active) == OK:
		_locomotion_active = active
