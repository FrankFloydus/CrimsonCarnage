@tool
extends Node3D
## Runs authored melee clips and applies procedural motion to weapons mounted on the sockets.

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
## Physics layers the visible weapons react to. Include walls and props you want the weapon to avoid.
## Clearing every layer disables both collision compression and the proximity wall tuck.
@export_flags_3d_physics var clearance_mask: int = 1
## Extra space in meters around the weapon's fitted collision bounds.
## Raise it if a blade still clips corners when you approach a wall.
@export_range(0.0, 0.2, 0.001, "suffix:m") var clearance_padding: float = 0.025
## Time in seconds for the weapon to regain its size after being fully compressed at a wall.
## Raise it to soften a sudden pop back to full size. Zero restores the size immediately.
@export_range(0.0, 1.0, 0.01, "suffix:s") var clearance_recovery_time: float = 0.12

@export_group("Weapon Sway")
## Procedural settings shared by both weapon mounts. Use Locomotion for movement lag and lean,
## Bob for the step rhythm and gait transitions, or Jump and Landing for changes in footing.
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
var _sword_mount_was_visible := true
var _was_grounded := false
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
	_rig.set_right_socket(self)
	_rig.set_left_socket(_camera.get_node_or_null(^"LeftWeaponControl") as Node3D)
	_was_grounded = _body.is_on_floor()
	_select_sword(long_sweep if is_instance_valid(long_sweep) else short_sweep)


func _unhandled_input(event: InputEvent) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if InputMap.has_action(&"melee_long_sword") and event.is_action_pressed(&"melee_long_sword"):
		_select_sword(long_sweep)
	elif InputMap.has_action(&"melee_short_sword") and event.is_action_pressed(&"melee_short_sword"):
		_select_sword(short_sweep)
	else:
		return
	get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	_rig.restore_socket_visuals()
	_playback.advance(delta, captured)
	_sync_rig_settings()
	var world_velocity := _body.get_real_velocity()
	var travel := _body.get_position_delta()
	var grounded := _body.is_on_floor()
	if _was_grounded and not grounded and _body.velocity.dot(_body.up_direction) > 0.0:
		play_takeoff_motion()
	_was_grounded = grounded
	_rig.advance(
		delta, Vector2(world_velocity.x, world_velocity.z), Vector2(travel.x, travel.z),
		_body.global_basis, grounded, false, false, captured, _playback.get_active_sweep() != null
	)
	_rig.apply_visuals(
		delta, _camera, clearance_mask, clearance_padding, clearance_recovery_time, _excluded,
		_right_sweep != null and _right_sweep == short_sweep,
		_playback.sway_weight(_right_sweep), _playback.sway_weight(left_sweep)
	)


## Accumulates the pitch and yaw applied by Look between physics ticks.
func add_look_turn(angles: Vector2) -> void:
	if _rig != null and is_physics_processing():
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


## Plays the sword landing pose from Mover's impact speed in meters per second.
func play_landing_motion(impact_speed: float) -> void:
	if _rig != null and is_physics_processing():
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
	_rig.restore_socket_visuals()
	_right_sweep = sweep
	for candidate: MeleeSweep3D in [long_sweep, short_sweep]:
		if is_instance_valid(candidate):
			candidate.get_parent_node_3d().visible = candidate == sweep
	_playback.set_sweeps(sweep, left_sweep)
	_playback.set_clips(carry_animation, right_slash_animation, left_slash_animation)
	_playback.restore_carry_pose()


## Requests a sword swing. The empty prototype rig emits the same start event without playback.
func request_slash() -> void:
	if not is_instance_valid(_right_sweep) or right_slash_animation.is_empty():
		if not is_instance_valid(_right_sweep) and not is_instance_valid(left_sweep) \
				and right_slash_animation.is_empty() and left_slash_animation.is_empty():
			swing_started.emit()
		return
	_rig.restore_socket_visuals()
	_playback.set_clips(carry_animation, right_slash_animation, left_slash_animation)
	_playback.set_reach(slash_reach)
	_playback.set_contact_direction_fallback(contact_direction_fallback)
	_playback.request_slash()


## Suspends sword playback in Spellcaster form and restores sword controls on return.
func set_sword_form_active(active: bool) -> void:
	_rig.restore_socket_visuals()
	if active:
		_was_grounded = _body.is_on_floor()
	else:
		clear_air_motion()
		_sword_mount_was_visible = visible
		if _playback.get_active_sweep() != null:
			animation_player.stop()
	_playback.restore_carry_pose()
	visible = active and _sword_mount_was_visible
	set_physics_process(active)
	set_process_unhandled_input(active)


func _update_reach_preview() -> void:
	for sweep: MeleeSweep3D in [long_sweep, short_sweep, left_sweep]:
		if is_instance_valid(sweep):
			sweep.preview_reach = slash_reach
