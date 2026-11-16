@tool
extends Node3D
## Runs authored melee clips and procedural motion for any assigned weapon sweeps.

## Emitted when a new slash starts.
signal swing_started
## Relays the active weapon's overlap with each body in the hit window.
signal world_contact(collider: Node3D)
## Relays the active weapon's first contact with each body in the hit window.
signal surface_contact(collider: CollisionObject3D, point: Vector3, normal: Vector3, direction: Vector3)

const WeaponSwaySettings := preload("res://scripts/melee/weapon_sway_settings.gd")
const BobStyleResource := preload("res://scripts/melee/weapon_bob_style.gd")

## Player rig AnimationPlayer. The rig advances it in physics so visuals and contacts use the same pose.
@export var animation_player: AnimationPlayer
## Player locomotion component that supplies floor, stair support, and dash state for weapon bob.
@export var movement: FirstPersonMovement
## Right-hand long sword sweep, selected with the first comparison input.
@export var long_sweep: MeleeSweep3D
## Right-hand short sword sweep, selected with the second comparison input.
@export var short_sweep: MeleeSweep3D
## Left-hand sword sweep, used on alternating slashes.
@export var left_sweep: MeleeSweep3D
## Reach and placement for either hand's slash, applied to the attacking sword's base sweep.
@export var slash_reach: MeleeAttackReach:
	set(value):
		slash_reach = value
		if Engine.is_editor_hint() and is_node_ready():
			_update_reach_preview()

## Camera-local direction used for contact effects when the blade barely moves.
@export var contact_direction_fallback: Vector3 = Vector3.LEFT

@export_group("Weapon Clearance")
## Physics layers that keep the visible weapon clear of walls and other bodies. Zero disables clearance.
@export_flags_3d_physics var clearance_mask: int = 1
## Extra space kept between the fitted weapon bounds and world collision, in meters.
@export_range(0.0, 0.2, 0.001, "suffix:m") var clearance_padding: float = 0.025
## Time to return from full compression to the authored size. Zero restores it immediately.
@export_range(0.0, 1.0, 0.01, "suffix:s") var clearance_recovery_time: float = 0.12

@export_group("Weapon Sway")
## Directional look poses and locomotion response. The left hand mirrors the right hand's poses.
@export var sway_settings: WeaponSwaySettings

@export_group("Animation Clips")
## Clip sampled at time zero when carrying a sword or finishing an attack.
@export var carry_animation: StringName = &""
## Animation played by the right-hand sword sweep.
@export var right_slash_animation: StringName = &""
## Animation played by the left-hand sword sweep. Leave empty to attack with only the right hand.
@export var left_slash_animation: StringName = &""

var _right_sweep: MeleeSweep3D
var _excluded: Array[RID]
var _playback: CrimsonMeleePlayback
var _rig: CrimsonWeaponRig
var _configured_sway: WeaponSwaySettings
@onready var _camera := get_parent() as Camera3D
@onready var _body := owner as CharacterBody3D


func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		set_process_unhandled_input(false)
		_update_reach_preview()
		return

	_excluded = [_body.get_rid()]
	for sweep: MeleeSweep3D in [long_sweep, short_sweep, left_sweep]:
		if is_instance_valid(sweep):
			sweep.world_contact.connect(world_contact.emit)
			sweep.surface_contact.connect(surface_contact.emit)

	_playback = CrimsonMeleePlayback.new()
	_playback.configure(animation_player, _camera, _excluded, swing_started.emit)
	_rig = CrimsonWeaponRig.new()
	_sync_rig_settings()
	if is_instance_valid(left_sweep):
		_rig.set_left_visuals(left_sweep.get_parent().get_node_or_null(^"Visuals") as Node3D)
	_select_sword(long_sweep if is_instance_valid(long_sweep) else short_sweep)


func _unhandled_input(event: InputEvent) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event.is_action_pressed(&"melee_long_sword"):
		_select_sword(long_sweep)
	elif event.is_action_pressed(&"melee_short_sword"):
		_select_sword(short_sweep)
	elif event.is_action_pressed(&"melee_slash"):
		_request_slash()
	else:
		return
	get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	_playback.advance(delta, captured)
	_sync_rig_settings()
	var has_movement := is_instance_valid(movement)
	var world_velocity := _body.get_real_velocity()
	_rig.advance(
		delta, Vector2(world_velocity.x, world_velocity.z),
		movement.get_ground_travel() if has_movement else Vector2.ZERO,
		_body.global_basis, has_movement and movement.is_grounded(),
		has_movement and movement.did_dash_last_step(),
		has_movement and movement.is_ground_braking(), captured, _playback.get_active_sweep() != null
	)
	_rig.apply_visuals(
		delta, _camera, clearance_mask, clearance_padding, clearance_recovery_time, _excluded,
		_right_sweep == short_sweep, _playback.sway_weight(_right_sweep), _playback.sway_weight(left_sweep)
	)


## Accumulates the pitch and yaw applied by Look between physics ticks.
func add_look_turn(angles: Vector2) -> void:
	if _rig != null:
		_rig.add_look_turn(angles)


## Previews a style on this player. Passing null restores the style in Sway Settings.
func preview_bob_style(style: BobStyleResource) -> void:
	if _rig != null:
		_rig.preview_bob_style(style)


## Plays the authored jump pose until the player lands.
func play_takeoff_motion() -> void:
	if _rig != null:
		_sync_rig_settings()
		_rig.play_takeoff_motion()


## Scales the landing reaction to pre-contact downward speed in meters per second.
func play_landing_motion(impact_speed: float) -> void:
	if _rig != null:
		_sync_rig_settings()
		_rig.play_landing_motion(impact_speed)


## Resets in-flight pose offsets after an external move.
func clear_air_motion() -> void:
	if _rig != null:
		_rig.clear_air_motion()


func _sync_rig_settings() -> void:
	if _configured_sway != sway_settings:
		_configured_sway = sway_settings
		_rig.configure(sway_settings)


func _select_sword(sweep: MeleeSweep3D) -> void:
	if not is_instance_valid(sweep) or _right_sweep == sweep:
		return
	_right_sweep = sweep
	for candidate: MeleeSweep3D in [long_sweep, short_sweep]:
		if is_instance_valid(candidate):
			candidate.get_parent_node_3d().visible = candidate == sweep
	_playback.set_sweeps(sweep, left_sweep)
	_playback.set_clips(carry_animation, right_slash_animation, left_slash_animation)
	_playback.restore_carry_pose()
	_rig.set_right_visuals(sweep.get_parent().get_node_or_null(^"Visuals") as Node3D)


func _request_slash() -> void:
	if not is_instance_valid(_right_sweep) or right_slash_animation.is_empty():
		return
	_playback.set_clips(carry_animation, right_slash_animation, left_slash_animation)
	_playback.set_reach(slash_reach)
	_playback.set_contact_direction_fallback(contact_direction_fallback)
	_playback.request_slash()


func _update_reach_preview() -> void:
	for sweep: MeleeSweep3D in [long_sweep, short_sweep, left_sweep]:
		if is_instance_valid(sweep):
			sweep.preview_reach = slash_reach
