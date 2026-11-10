class_name FirstPersonCrouch
extends Node
## Owns crouch stance, capsule clearance, and a smooth, ceiling-limited eye-height transition.

## Emitted after the collision capsule adopts the new stance.
signal stance_changed(crouched: bool)

## Character whose collision mask and exceptions define standing obstructions.
@export var body: CharacterBody3D
## Upright capsule collider attached directly to the body; its saved transform defines standing.
@export var collision: CollisionShape3D
## Saved eye pivot whose local height changes with stance without changing its pitch.
@export var eye: Node3D
## Editable crouch input mode, dimensions, and visual transition.
@export var settings: FirstPersonCrouchSettings

## Actual stance, which can remain crouched when a standing request lacks clearance.
var is_crouching: bool:
	get:
		return _is_crouching

var _is_crouching: bool = false
var _stand_pending: bool = false
var _capsule: CapsuleShape3D
var _standing_shape: CapsuleShape3D
var _standing_collision_transform: Transform3D
var _standing_eye_height: float
var _transition_start_height: float
var _target_eye_height: float
var _transition_elapsed: float = 0.0
var _camera: Camera3D


func _ready() -> void:
	_standing_collision_transform = collision.transform
	_standing_eye_height = eye.position.y
	_transition_start_height = _standing_eye_height
	_target_eye_height = _standing_eye_height
	_camera = eye.get_node("Camera3D")
	_standing_shape = collision.shape.duplicate() as CapsuleShape3D
	# Shapes in a PackedScene may be shared; resizing must affect only this player.
	_capsule = collision.shape.duplicate() as CapsuleShape3D
	collision.shape = _capsule


func _process(delta: float) -> void:
	if settings.transition_time <= 0.0:
		eye.position.y = _target_eye_height
		return
	if is_equal_approx(eye.position.y, _target_eye_height):
		eye.position.y = _target_eye_height
		return
	_transition_elapsed = minf(_transition_elapsed + maxf(delta, 0.0), settings.transition_time)
	var weight := smoothstep(0.0, settings.transition_time, _transition_elapsed)
	var height := lerpf(_transition_start_height, _target_eye_height, weight)
	var clear_height := _clear_eye_height(height)
	if clear_height < height:
		# Resume from a ceiling correction so leaving its edge cannot raise the descending eye.
		_transition_start_height = clear_height
		_transition_elapsed = 0.0
	eye.position.y = clear_height


## Changes physical stance if the capsule fits, without interpreting player input.
func try_set_crouched(requested: bool) -> bool:
	if requested == _is_crouching:
		_stand_pending = false
		return true
	if not is_node_ready() or not body.is_inside_tree() or (not requested and not can_stand()):
		return false
	_stand_pending = false
	_is_crouching = requested
	var height := _standing_shape.height
	if _is_crouching:
		height = clampf(settings.crouched_height, _standing_shape.radius * 2.0, height)
	_capsule.height = height
	# Keep the capsule bottom fixed at the authored feet instead of moving the body.
	collision.position = _standing_collision_transform.origin - Vector3.UP * (
			(_standing_shape.height - height) * 0.5
	)
	_transition_start_height = eye.position.y
	_transition_elapsed = 0.0
	_target_eye_height = (
			minf(settings.crouched_eye_height, minf(height, _standing_eye_height))
			if _is_crouching else _standing_eye_height
	)
	if settings.transition_time <= 0.0:
		eye.position.y = _target_eye_height
	stance_changed.emit(_is_crouching)
	return true


## Release or interruption requests standing as soon as the full capsule can fit.
func request_stand() -> void:
	_stand_pending = not try_set_crouched(false)


## Retries a released stance on the locomotion physics step after an obstructed stand.
func retry_standing() -> void:
	if _stand_pending:
		try_set_crouched(false)


## Checks the entire authored standing capsule, including obstructions beside the head center.
func can_stand() -> bool:
	var excluded: Array[RID] = [body.get_rid()]
	for exception in body.get_collision_exceptions():
		excluded.append(exception.get_rid())
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _standing_shape
	query.transform = body.global_transform * _standing_collision_transform
	query.collision_mask = body.collision_mask
	query.exclude = excluded
	return body.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func _clear_eye_height(height: float) -> float:
	if not _is_crouching or height <= _target_eye_height:
		return height
	# The collider shrinks immediately, so entering a roof can precede visual crouch completion.
	var padding := maxf(0.05, _camera.near)
	var start := body.to_global(Vector3(eye.position.x, _target_eye_height, eye.position.z))
	var end := body.to_global(Vector3(eye.position.x, height + padding, eye.position.z))
	var excluded: Array[RID] = [body.get_rid()]
	for exception in body.get_collision_exceptions():
		excluded.append(exception.get_rid())
	var query := PhysicsRayQueryParameters3D.create(start, end, body.collision_mask, excluded)
	query.hit_from_inside = true
	var hit := body.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return height
	var hit_position: Vector3 = hit.position
	return maxf(_target_eye_height, minf(height, body.to_local(hit_position).y - padding))
