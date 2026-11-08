extends RefCounted
## Validates saved wiring before replacing runtime Fireball tuning in one isolated fixture.

const FIREBALL: int = 6
const TEST_CLIP: StringName = &"fixture/fireball"
const CLIP_LENGTH: float = 0.8
const RELEASE_TIME: float = 0.33
const COST: float = 15.0
const COOLDOWN: float = 1.5
const COMMITMENT = preload("res://tests/ability_commit_fixture.gd")


static func install(system: AbilitySystem) -> bool:
	var animation_player := system.animation_player
	var authored := system.get_ability_definition(FIREBALL)
	var saved_execution := authored.execution as PhasedAbilityExecution if authored != null else null
	var valid := saved_execution != null and authored.get_validation_error().is_empty() \
			and authored.resource_costs.size() == 1 and authored.charge_pool != null \
			and saved_execution.get_validation_error(system).is_empty() \
			and system.aim_origin != null
	if not valid:
		return false

	var definition := authored.duplicate() as AbilityDefinition
	var execution := saved_execution.duplicate_deep(Resource.DEEP_DUPLICATE_ALL) as PhasedAbilityExecution
	definition.execution = execution
	definition.resource_costs = [COMMITMENT.make_cost(AmountDefinition.Pool.MANA, COST)]
	definition.charge_pool = COMMITMENT.make_cooldown(COOLDOWN)
	execution.animation_name = TEST_CLIP
	execution.delivery.spawn_offset = Vector3.ZERO
	execution.targeting.max_range = 100.0
	execution.targeting.allegiance = AbilityTargetingDefinition.Allegiance.ANY
	var effect := GameplayEffectDefinition.new()
	effect.executions = [GameplayEffectDamageExecution.new()]
	effect.get_damage_execution().amount = AmountDefinition.fixed(20.0)
	effect.damage_type = GameplayEffectDefinition.DamageType.MAGIC
	var action := execution.phases[0].actions[0] as AbilityApplyEffectsAction
	action.effects = [effect]
	var projectile := AbilityProjectile.new()
	projectile.speed = 18.0
	projectile.lifetime = 5.0
	projectile.collision_mask = 1
	execution.delivery.projectile_scene = PackedScene.new()
	var packed := execution.delivery.projectile_scene.pack(projectile)
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
