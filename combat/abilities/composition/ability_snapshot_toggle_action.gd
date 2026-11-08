@tool
class_name AbilitySnapshotToggleAction
extends AbilityActionDefinition
## Captures an authored snapshot on first use and restores its one owned instance on next use.

## Timed snapshot effect to apply to the caster. Its effect ID identifies the captured instance.
@export var snapshot_effect: GameplayEffectDefinition


func get_validation_error() -> StringName:
	if snapshot_effect == null or snapshot_effect.effect_id <= 0:
		return &"missing_snapshot_effect"
	for component in snapshot_effect.components:
		if component is SelectiveResourceSnapshotEffectComponent and component.restore_on_manual_removal:
			return snapshot_effect.get_validation_error()
	return &"snapshot_requires_manual_restore"


func execute(context: AbilityPhaseContext, _targets: AbilityTargetSet) -> int:
	if context == null or context.cast == null or not get_validation_error().is_empty():
		return -1
	var system := context.cast.get_system()
	if not is_instance_valid(system) or system.effects == null:
		return -1
	var result := system.effects.restore_snapshot(snapshot_effect.effect_id)
	if result != 0:
		return result
	return 1 if system.apply_effect_spec_to_self(context.cast.make_effect_spec(snapshot_effect)) > 0 else -1


func get_effect_payload() -> Array[GameplayEffectDefinition]:
	var result: Array[GameplayEffectDefinition] = []
	if snapshot_effect != null:
		result.append(snapshot_effect)
	return result
