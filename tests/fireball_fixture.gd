extends RefCounted
## Validates saved wiring before replacing runtime Fireball tuning in one isolated fixture.

const FIREBALL: StringName = &"fireball"
const TEST_CLIP: StringName = &"fixture/fireball"
const CLIP_LENGTH: float = 0.8
const RELEASE_TIME: float = 0.33
const COST: float = 15.0
const COOLDOWN: float = 1.5
const ABILITY_EFFECTS = preload("res://tests/ability_effect_fixture.gd")


static func install(system: AbilitySystem) -> bool:
	var animation_player := system.animation_player
	var authored := system.get_ability_definition(FIREBALL)
	var saved_execution := authored.execution as ProjectileCastExecution if authored != null else null
	var valid := saved_execution != null and authored.get_validation_error().is_empty() \
			and authored.cost_effect != null and authored.cooldown_effect != null \
			and saved_execution.get_validation_error(system).is_empty() \
			and system.aim_origin != null
	if not valid:
		return false

	var definition := authored.duplicate() as AbilityDefinition
	var execution := saved_execution.duplicate() as ProjectileCastExecution
	definition.execution = execution
	definition.cost_effect = ABILITY_EFFECTS.make_cost(CombatAttributes.Id.MANA, COST)
	definition.cooldown_effect = ABILITY_EFFECTS.make_cooldown("Cooldown.FireballFixture", COOLDOWN)
	execution.animation_name = TEST_CLIP
	execution.spawn_offset = Vector3.ZERO
	execution.aim_trace_distance = 100.0
	var effect := GameplayEffectDefinition.new()
	effect.executions = [GameplayEffectDamageExecution.new()]
	effect.base_magnitude = 20.0
	effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	execution.on_hit_effects = [effect]
	var projectile := AbilityProjectile.new()
	projectile.speed = 18.0
	projectile.lifetime = 5.0
	projectile.collision_mask = 1
	execution.projectile_scene = PackedScene.new()
	var packed := execution.projectile_scene.pack(projectile)
	projectile.free()
	if packed != OK:
		return false

	var clip := Animation.new()
	clip.length = CLIP_LENGTH
	var track := clip.add_track(Animation.TYPE_METHOD)
	clip.track_set_path(track, animation_player.get_parent().get_path_to(system))
	clip.track_insert_key(track, RELEASE_TIME,
			{"method": &"handle_animation_event", "args": [execution.release_event]})
	var library := AnimationLibrary.new()
	library.add_animation(&"fireball", clip)
	animation_player.add_animation_library(&"fixture", library)
	system.cast_origin.global_position = system.aim_origin.to_global(Vector3(0.25, -0.2, -0.6))
	system.revoke_ability(FIREBALL)
	return system.grant_ability(definition)
