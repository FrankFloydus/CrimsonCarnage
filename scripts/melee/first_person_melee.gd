@tool
extends Node3D
## Alternates the authored right and left slashes on the Playground's mounted swords.

## Emitted when a new slash starts.
signal swing_started
## Relays the active weapon's first contact with each body in the hit window.
signal surface_contact(collider: CollisionObject3D, point: Vector3, normal: Vector3, direction: Vector3)

const IDLE := &"idle"
const SLASH_RIGHT := &"slash"
const SLASH_LEFT := &"slash_left"
const HIT_START := &"HitStart"
const HIT_END := &"HitEnd"
const MAX_SAMPLE_INTERVAL := 1.0 / 60.0
const WeaponClearance := preload("res://scripts/melee/weapon_clearance.gd")

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
## Physics layers that keep the visible weapon clear of walls and other bodies. Zero disables clearance.
@export_flags_3d_physics var clearance_mask: int = 1
## Extra space kept between the fitted weapon bounds and world collision, in meters.
@export_range(0.0, 0.2, 0.001, "suffix:m") var clearance_padding: float = 0.025
## Time to return from full compression to the authored size. Zero restores it immediately.
@export_range(0.0, 1.0, 0.01, "suffix:s") var clearance_recovery_time: float = 0.12

var _right_sweep: MeleeSweep3D
var _active_sweep: MeleeSweep3D
var _next_slash := SLASH_RIGHT
var _slash_buffered := false
var _active_reach: MeleeAttackReach
var _excluded: Array[RID]
var _slash_time: float = 0.0
var _hit_start: float = 0.0
var _hit_end: float = 0.0
var _sweeping: bool = false
var _previous_pose: Transform3D
var _previous_motion_point: Vector3
var _right_clearance := WeaponClearance.new()
var _left_clearance := WeaponClearance.new()

@onready var _camera := get_parent() as Camera3D


func _ready() -> void:
	if Engine.is_editor_hint():
		set_physics_process(false)
		set_process_unhandled_input(false)
		_update_reach_preview()
		return
	_excluded = [(owner as CollisionObject3D).get_rid()]
	long_sweep.surface_contact.connect(surface_contact.emit)
	short_sweep.surface_contact.connect(surface_contact.emit)
	left_sweep.surface_contact.connect(surface_contact.emit)
	_select_sword(long_sweep)
	_left_clearance.set_visuals(left_sweep.get_parent().get_node_or_null(^"Visuals") as Node3D)


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
	if _active_sweep == null:
		animation_player.advance(delta)
	elif Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_play_idle()
	else:
		_advance_slash(delta)
	_right_clearance.update(delta, _camera, clearance_mask, clearance_padding, clearance_recovery_time, _excluded)
	_left_clearance.update(delta, _camera, clearance_mask, clearance_padding, clearance_recovery_time, _excluded)


func _select_sword(sweep: MeleeSweep3D) -> void:
	if _right_sweep == sweep:
		return
	_right_sweep = sweep
	long_sweep.get_parent_node_3d().visible = sweep == long_sweep
	short_sweep.get_parent_node_3d().visible = sweep == short_sweep
	_play_idle()
	_right_clearance.set_visuals(sweep.get_parent().get_node_or_null(^"Visuals") as Node3D)


func _play_idle() -> void:
	_sweeping = false
	_active_reach = null
	_active_sweep = null
	_slash_buffered = false
	animation_player.play(IDLE)
	animation_player.advance(0.0)


func _request_slash() -> void:
	if _active_sweep == null:
		_start_slash()
	else:
		_slash_buffered = true


func _start_slash() -> void:
	var slash := _next_slash
	if not animation_player.has_animation(slash):
		push_warning("WeaponControl needs the %s animation." % slash)
		return
	var clip := animation_player.get_animation(slash)
	if not clip.has_marker(HIT_START) or not clip.has_marker(HIT_END):
		push_warning("Slash needs HitStart and HitEnd markers.")
		return
	_hit_start = clip.get_marker_time(HIT_START)
	_hit_end = clip.get_marker_time(HIT_END)
	if _hit_start < 0.0 or _hit_end <= _hit_start or _hit_end > clip.length:
		push_warning("Slash hit markers must define a window inside the clip.")
		return
	_slash_time = 0.0
	_active_sweep = _right_sweep if slash == SLASH_RIGHT else left_sweep
	_active_reach = slash_reach.duplicate() as MeleeAttackReach if slash_reach != null else null
	_active_sweep.begin_swing()
	_next_slash = SLASH_LEFT if slash == SLASH_RIGHT else SLASH_RIGHT
	swing_started.emit()
	animation_player.play(slash)
	animation_player.advance(0.0)


func _advance_slash(delta: float) -> void:
	var length := animation_player.current_animation_length
	var next_time := minf(_slash_time + delta, length)
	if next_time >= _hit_start and _slash_time < _hit_end:
		var trace_start := maxf(_slash_time, _hit_start)
		var trace_end := minf(next_time, _hit_end)
		if not _sweeping:
			animation_player.seek(maxf(trace_start - MAX_SAMPLE_INTERVAL, 0.0), true, true)
			_previous_motion_point = _active_sweep.sample_motion_point()
			animation_player.seek(trace_start, true, true)
			_previous_pose = _active_sweep.sample_pose()
			var motion_point := _active_sweep.sample_motion_point()
			var direction := _contact_direction(motion_point)
			_active_sweep.trace_segment(_previous_pose, _previous_pose, _excluded, _active_reach, direction)
			_previous_motion_point = motion_point
			_sweeping = true
		var steps := ceili((trace_end - trace_start) / MAX_SAMPLE_INTERVAL)
		for index in range(1, steps + 1):
			var sample_time := lerpf(trace_start, trace_end, float(index) / steps)
			animation_player.seek(sample_time, true, true)
			var pose := _active_sweep.sample_pose()
			var motion_point := _active_sweep.sample_motion_point()
			var direction := _contact_direction(motion_point)
			_active_sweep.trace_segment(_previous_pose, pose, _excluded, _active_reach, direction)
			_previous_pose = pose
			_previous_motion_point = motion_point
	_slash_time = next_time
	if next_time >= length:
		var chain_slash := _slash_buffered
		_play_idle()
		if chain_slash:
			_start_slash()
	elif not is_equal_approx(animation_player.current_animation_position, next_time):
		animation_player.seek(next_time, true, true)


func _contact_direction(motion_point: Vector3) -> Vector3:
	var displacement := motion_point - _previous_motion_point
	if displacement.length_squared() > 0.000001:
		return displacement.normalized()
	var fallback := _camera.global_basis * contact_direction_fallback
	return -_camera.global_basis.z if fallback.is_zero_approx() else fallback.normalized()


func _update_reach_preview() -> void:
	if is_instance_valid(long_sweep):
		long_sweep.preview_reach = slash_reach
	if is_instance_valid(short_sweep):
		short_sweep.preview_reach = slash_reach
	if is_instance_valid(left_sweep):
		left_sweep.preview_reach = slash_reach
