class_name ProjectileCastExecution
extends AbilityExecution
## Plays an authored cast animation and delivers ability-selected effects through its release event.

## Animation containing the release method key and any authored cast presentation.
@export var animation_name: StringName = &""
## Gameplay event tag sent by the animation method key to release the projectile once.
@export var release_event: StringName = &"Event.Combat.ProjectileRelease"
## Saved projectile scene containing an AbilityProjectile root, validated before spending costs.
@export var projectile_scene: PackedScene
## Spawn offset in the casting origin's local coordinates, in meters.
@export var spawn_offset: Vector3 = Vector3.ZERO
## Crosshair aim trace length in meters. Zero launches along the aim origin’s forward axis.
@export_range(0.0, 500.0, 0.1, "or_greater") var aim_trace_distance: float = 0.0
## Effects selected by this ability and supplied to the projectile at release.
@export var on_hit_effects: Array[GameplayEffectDefinition] = []


func get_validation_error(system: AbilitySystem) -> StringName:
	if not is_finite(aim_trace_distance) or aim_trace_distance < 0.0:
		return &"invalid_aim_trace_distance"
	if on_hit_effects.is_empty():
		return &"missing_effect_payload"
	for effect in on_hit_effects:
		if effect == null or not effect.get_validation_error().is_empty():
			return &"invalid_effect_payload"
	if projectile_scene == null or not projectile_scene.can_instantiate():
		return &"missing_projectile"
	var probe := projectile_scene.instantiate()
	var valid_root := probe is AbilityProjectile
	probe.free()
	if not valid_root:
		return &"invalid_projectile_root"
	if system.cast_origin == null or not system.cast_origin.is_inside_tree():
		return &"missing_cast_origin"
	if system.animation_player == null or not system.animation_player.has_animation(animation_name):
		return &"missing_animation"
	var animation: Animation = system.animation_player.get_animation(animation_name)
	if animation.loop_mode != Animation.LOOP_NONE:
		return &"looping_cast_animation"
	return &"" if _get_release_time(animation) >= 0.0 else &"missing_release_event"


func _get_release_time(animation: Animation) -> float:
	var first_time := INF
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_METHOD \
				or not animation.track_is_enabled(track):
			continue
		for key in animation.track_get_key_count(track):
			var event: Dictionary = animation.track_get_key_value(track, key)
			var args: Array = event.get("args", [])
			if StringName(event.get("method", "")) == &"handle_animation_event" \
					and not args.is_empty() and StringName(args[0]) == release_event:
				var key_time := animation.track_get_key_time(track, key)
				if key_time >= 0.0 and key_time <= animation.length:
					first_time = minf(first_time, key_time)
	return first_time if is_finite(first_time) else -1.0


func begin(cast: AbilityCast) -> void:
	var system := cast.get_system()
	if system == null:
		return
	var animation := system.animation_player.get_animation(animation_name)
	var release_time := _get_release_time(animation) if animation != null else -1.0
	if release_time < 0.0:
		cast.cancel()
		return
	cast.data[&"release_time"] = release_time
	var release_task := AbilityTaskWaitGameplayEvent.new(release_event)
	release_task.event_received.connect(_on_release_event.bind(cast))
	cast.start_task(release_task)
	var speed := cast.get_animation_playback_rate(animation.length)
	var animation_task := AbilityTaskPlayAnimationAndWait.new(animation_name, speed, true)
	animation_task.completed.connect(cast.finish)
	animation_task.interrupted.connect(cast.cancel)
	cast.start_task(animation_task)


## Reports actual animation windup progress, or -1 when there is no visible windup.
func get_windup_progress(cast: AbilityCast) -> float:
	if cast == null or cast.released or cast.finished:
		return -1.0
	var system := cast.get_system()
	if system == null or system.get_animation_cast() != cast:
		return -1.0
	var player := system.animation_player
	var release_time := float(cast.data.get(&"release_time", -1.0))
	if not is_instance_valid(player) or not player.is_playing() \
			or player.current_animation != animation_name or release_time <= 0.0:
		return -1.0
	return clampf(player.current_animation_position / release_time, 0.0, 1.0)


func _on_release_event(_event_tag: StringName, _payload: Dictionary, cast: AbilityCast) -> void:
	if cast.released or cast.finished:
		return
	var system := cast.get_system()
	if system == null or system.cast_origin == null:
		cast.cancel()
		return
	var instance := projectile_scene.instantiate()
	var projectile := instance as AbilityProjectile
	if projectile == null:
		instance.free()
		push_warning("Projectile scene must have an AbilityProjectile root.")
		cast.cancel()
		return
	cast.released = true
	var origin := system.cast_origin.global_transform.orthonormalized()
	var aim := system.aim_origin if is_instance_valid(system.aim_origin) else system.cast_origin
	var transform := aim.global_transform.orthonormalized()
	var view_origin := transform.origin
	transform.origin = origin * spawn_offset
	if aim_trace_distance > 0.0:
		var forward := -transform.basis.z
		var aim_point := view_origin + forward * aim_trace_distance
		var excluded: Array[RID] = []
		if is_instance_valid(system.actor_body):
			excluded.append(system.actor_body.get_rid())
		var query := PhysicsRayQueryParameters3D.create(
				view_origin, aim_point, projectile.collision_mask, excluded)
		var contact := aim.get_world_3d().direct_space_state.intersect_ray(query)
		if not contact.is_empty():
			aim_point = contact["position"]
		if forward.dot(aim_point - transform.origin) > 0.0:
			transform = transform.looking_at(aim_point, transform.basis.y)
		elif not contact.is_empty():
			# Cover between the camera and muzzle blocks the shot at release.
			projectile.free()
			return
	cast.context.prime_effects(on_hit_effects)
	var specs: Array[GameplayEffectSpec] = []
	for definition: GameplayEffectDefinition in on_hit_effects:
		specs.append(cast.make_effect_spec(definition))
	var world: Node = system.get_tree().current_scene
	if world == null:
		world = system.get_tree().root
	world.add_child(projectile)
	projectile.global_transform = transform
	projectile.launch(cast.context, specs, system.actor_body)
	cast.data[&"projectile"] = weakref(projectile)


func get_animation_name() -> StringName:
	return animation_name


func get_effect_payload() -> Array[GameplayEffectDefinition]:
	return on_hit_effects
