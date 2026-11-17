extends Node3D
## Previews the player's screen effects, directional damage HUD, and weapon gait styles.

const DAMAGE_PREVIEW_DISTANCE := 8.0
const BOB_STYLES := [
	preload("res://data/melee/bob_styles/balanced.tres"),
	preload("res://data/melee/bob_styles/light_footed.tres"),
	preload("res://data/melee/bob_styles/long_stride.tres"),
	preload("res://data/melee/bob_styles/heavy_braced.tres"),
]

## Maximum distance from the camera to the mannequin's torso for the lens preview, in meters.
## Zero disables this preview.
@export_range(0.0, 10.0, 0.1, "or_greater", "suffix:m") var mannequin_lens_blood_range: float = 3.0

var _lens_played_this_swing: bool = false

@onready var _mannequin: Node3D = $BloodTestTarget
@onready var _player: Node3D = $Player
@onready var _camera: Camera3D = $Player/Look/Camera3D
@onready var _weapon := _camera.get_node(^"WeaponControl")
@onready var _presentation: PlayerPresentation = $Player/PlayerPresentation


func _ready() -> void:
	_weapon.swing_started.connect(_on_swing_started)
	_weapon.surface_contact.connect(_on_surface_contact)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
	if code == KEY_P:
		_presentation.toggle_painterly_preview()
		get_viewport().set_input_as_handled()
		return
	var style_index := code - KEY_1
	if key.alt_pressed and style_index >= 0 and style_index < BOB_STYLES.size():
		_weapon.preview_bob_style(BOB_STYLES[style_index])
		get_viewport().set_input_as_handled()
		return
	if code < KEY_1 or code > KEY_8:
		return

	var angle := float(code - KEY_1) * PI / 4.0
	var local_direction := Vector3(sin(angle), 0.0, -cos(angle))
	var world_offset := _player.global_basis * local_direction * DAMAGE_PREVIEW_DISTANCE
	_presentation.show_incoming_hit(_player.global_position + world_offset)
	get_viewport().set_input_as_handled()


func _on_swing_started() -> void:
	_lens_played_this_swing = false


func _on_surface_contact(
		collider: CollisionObject3D, _point: Vector3, _normal: Vector3, _direction: Vector3
) -> void:
	if _lens_played_this_swing or not _mannequin.is_ancestor_of(collider):
		return

	var torso_position := _mannequin.global_position + Vector3.UP
	var distance_squared := _camera.global_position.distance_squared_to(torso_position)
	if distance_squared >= mannequin_lens_blood_range * mannequin_lens_blood_range:
		return

	_lens_played_this_swing = true
	_presentation.play_lens_blood()
