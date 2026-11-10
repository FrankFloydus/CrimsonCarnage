class_name FirstPersonStairStepper
extends RefCounted
## Validates capsule stair clearance and retains terrain contacts for one movement instance.

const MIN_MOTION_SQUARED := 0.00000001
const FRACTION_TOLERANCE := 0.0001

var _contact_cache: Dictionary = {}


func reset() -> void:
	_contact_cache.clear()


## Tests the complete body path, then applies only the vertical part of a step.
## The caller must immediately move_and_slide() with its original horizontal velocity.
func try_step(
		body: CharacterBody3D,
		horizontal_motion: Vector3,
		max_step_height: float,
		max_slope_angle: float,
		delta: float
) -> bool:
	if max_step_height <= 0.0 or not body.is_inside_tree():
		return false
	var up := body.up_direction.normalized()
	var motion := horizontal_motion.slide(up)
	if motion.length_squared() <= MIN_MOTION_SQUARED or up.is_zero_approx():
		return false
	var start := body.global_transform
	var margin := maxf(body.safe_margin, 0.0001)
	var slope_cos := cos(clampf(max_slope_angle, 0.0, PI * 0.5))
	var downward_motion := maxf(-body.velocity.dot(up) * delta, 0.0)
	var actual_motion := motion - up * downward_motion
	var blocking := PhysicsTestMotionResult3D.new()
	_test_motion(body, start, motion, margin, blocking, true)
	var contacts: Array[Dictionary] = []
	for index in blocking.get_collision_count():
		if not blocking.get_collider(index) is CharacterBody3D:
			contacts.append({
				"normal": blocking.get_collision_normal(index),
				"point": blocking.get_collision_point(index),
				"rid": blocking.get_collider_rid(index),
			})
	for index in body.get_slide_collision_count():
		var previous := body.get_slide_collision(index)
		for collision in previous.get_collision_count():
			if not previous.get_collider(collision) is CharacterBody3D:
				contacts.append({
					"normal": previous.get_normal(collision),
					"point": previous.get_position(collision),
					"rid": previous.get_collider_rid(collision),
				})
	if not _contact_cache.is_empty():
		var cached := _contact_cache
		var age: int = Engine.get_physics_frames() - int(cached["frame"])
		var displacement: Vector3 = start.origin - cached["position"]
		var cache_distance := max_step_height + motion.length() * 2.0 + margin * 4.0
		if age >= 0 and age <= 1 and displacement.length() <= cache_distance:
			var previous_normal: Vector3 = cached["normal"]
			var tangent := displacement.slide(up).slide(previous_normal.slide(up).normalized())
			contacts.append({
				"normal": previous_normal,
				"point": cached["point"] + tangent,
				"rid": cached["rid"],
			})
		else:
			reset()
	if contacts.is_empty():
		return false
	var foot_height := _capsule_bottom(body, up)
	if not is_finite(foot_height):
		return false

	var upward := PhysicsTestMotionResult3D.new()
	var lift := max_step_height
	if _test_motion(body, start, up * lift, margin, upward):
		lift = clampf(upward.get_travel().dot(up), 0.0, max_step_height)
	if lift <= margin:
		return false
	var raised := start
	raised.origin += up * lift
	var forward := PhysicsTestMotionResult3D.new()
	if not _can_complete_motion(body, raised, motion, margin, forward):
		return false
	var ahead := raised
	ahead.origin += motion
	var downward := PhysicsTestMotionResult3D.new()
	if not _test_motion(body, ahead, -up * (lift + max_step_height + margin * 2.0), margin, downward):
		return false
	var actual_lift := lift + downward.get_travel().dot(up)
	if actual_lift > max_step_height + margin:
		return false

	# At a convex tread edge, the capsule contact normal is steeper than the tread.
	# Check the real surface just across the opposing riser, not along camera facing.
	var direction := motion.normalized()
	var has_tread := false
	var verified_contact: Dictionary = {}
	for contact in contacts:
		var normal: Vector3 = contact["normal"]
		var inward := -normal.slide(up).normalized()
		if normal.dot(up) >= slope_cos or inward.dot(direction) <= FRACTION_TOLERANCE:
			continue
		var probe_point: Vector3 = contact["point"] + inward * maxf(0.005, margin * 4.0)
		var query := PhysicsRayQueryParameters3D.create(
				probe_point + up * (max_step_height + margin * 2.0),
				probe_point - up * (max_step_height + margin * 2.0),
				body.collision_mask
		)
		var excluded: Array[RID] = [body.get_rid()]
		for exception in body.get_collision_exceptions():
			excluded.append(exception.get_rid())
		query.exclude = excluded
		query.collide_with_areas = false
		var tread := body.get_world_3d().direct_space_state.intersect_ray(query)
		if tread.is_empty() or tread["collider"] is CharacterBody3D:
			continue
		var tread_normal: Vector3 = tread["normal"]
		var tread_position: Vector3 = tread["position"]
		var rise := tread_position.dot(up) - foot_height
		if (tread_normal.dot(up) < slope_cos or rise <= margin
				or rise > max_step_height + margin * 2.0):
			continue
		if tread["rid"] != contact["rid"]:
			continue
		for support in downward.get_collision_count():
			if (downward.get_collider_rid(support) == tread["rid"]
					and downward.get_collision_normal(support).dot(up) > 0.0):
				has_tread = true
				break
		if has_tread:
			verified_contact = contact
			break
	if not has_tread:
		return false

	# Verify the actual lift too: a clear path at maximum height is insufficient.
	actual_lift = minf(maxf(actual_lift, 0.0) + margin * 2.0 + downward_motion, lift)
	var actual_start := start
	actual_start.origin += up * actual_lift
	var actual_forward := PhysicsTestMotionResult3D.new()
	if not _can_complete_motion(body, actual_start, actual_motion, margin, actual_forward):
		# Jolt may return the deeper floor contact instead of a shallow rounded edge.
		# Find the smallest clearance along the already verified upward path.
		var low := actual_lift
		var high := lift
		for iteration in 9:
			var candidate := (low + high) * 0.5
			actual_start.origin = start.origin + up * candidate
			if _can_complete_motion(body, actual_start, actual_motion, margin, actual_forward):
				high = candidate
			else:
				low = candidate
		actual_lift = high
	var actual_up := PhysicsTestMotionResult3D.new()
	if not _can_complete_motion(body, start, up * actual_lift, margin, actual_up):
		return false
	actual_start.origin = start.origin + up * actual_lift
	if not _can_complete_motion(body, actual_start, actual_motion, margin, actual_forward):
		return false
	body.global_position += up * actual_lift
	_contact_cache = {
		"normal": verified_contact["normal"],
		"point": verified_contact["point"],
		"rid": verified_contact["rid"],
		"position": body.global_position,
		"frame": Engine.get_physics_frames(),
	}
	return true


func _test_motion(
		body: CharacterBody3D,
		from: Transform3D,
		motion: Vector3,
		margin: float,
		result: PhysicsTestMotionResult3D,
		recovery_as_collision: bool = false
) -> bool:
	var parameters := PhysicsTestMotionParameters3D.new()
	parameters.from = from
	parameters.motion = motion
	parameters.margin = margin
	parameters.max_collisions = 32
	parameters.recovery_as_collision = recovery_as_collision
	return PhysicsServer3D.body_test_motion(body.get_rid(), parameters, result)


func _can_complete_motion(
		body: CharacterBody3D,
		from: Transform3D,
		motion: Vector3,
		margin: float,
		result: PhysicsTestMotionResult3D
) -> bool:
	var collided := _test_motion(body, from, motion, margin, result, true)
	if not collided:
		return true
	if result.get_collision_safe_fraction() < 1.0 - FRACTION_TOLERANCE:
		return false
	for index in result.get_collision_count():
		if result.get_collision_normal(index).dot(motion) < -0.0000001:
			return false
	return true


func _capsule_bottom(body: CharacterBody3D, up: Vector3) -> float:
	var bottom := INF
	for child in body.get_children():
		if not child is CollisionShape3D or child.disabled or not child.shape is CapsuleShape3D:
			continue
		var capsule: CapsuleShape3D = child.shape
		var pose: Transform3D = child.global_transform
		var extent := (
				absf(up.dot(pose.basis.x)) * capsule.radius
				+ absf(up.dot(pose.basis.y)) * capsule.height * 0.5
				+ absf(up.dot(pose.basis.z)) * capsule.radius
		)
		bottom = minf(bottom, pose.origin.dot(up) - extent)
	return bottom
