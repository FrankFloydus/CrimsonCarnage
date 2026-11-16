class_name PlayerPresentation
extends Node
## Plays screen effects and displays incoming hit directions for a first-person player.

const DashSpeedStreaks := preload("res://scripts/effects/dash_speed_streaks.gd")

## Player transform used for the position and horizontal bearing of incoming hits.
@export var observer: Node3D

var _painterly_preview_enabled: bool = true

@onready var _dash_speed_streaks: DashSpeedStreaks = $ScreenEffects/DashSpeedStreaks
@onready var _damage_vignette: DamageVignette = $ScreenEffects/DamageVignette
@onready var _lens_blood: LensBlood = $ScreenEffects/LensBlood
@onready var _post_process_pass: ColorRect = $ScreenEffects/PostProcessing/Pass
@onready var _damage_indicator: DamageIndicator = $HUD/DamageIndicator


func _ready() -> void:
	_damage_indicator.observer = observer


## Starts or releases the screen-space dash distortion.
func set_dash_active(active: bool, local_direction: Vector2) -> void:
	_dash_speed_streaks.set_dash_active(active, local_direction)


## Plays the contact vignette.
func pulse_damage_vignette() -> void:
	_damage_vignette.pulse()


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
