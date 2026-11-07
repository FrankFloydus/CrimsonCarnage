class_name GameplayEffectComponent
extends Resource
## Shared effect behavior. Application state belongs to the retained instance or its cleanup callback.


func get_validation_error(_definition: GameplayEffectDefinition) -> StringName:
	return &""


## Gates an actual application. Inspection and preflight do not run this hook.
func can_apply(_runtime: GameplayEffectRuntime, _spec: GameplayEffectSpec) -> bool:
	return true


## Called for every accepted application, including instant effects and successful reapplications.
func on_applied(_runtime: GameplayEffectRuntime, _spec: GameplayEffectSpec) -> void:
	pass


## Installs an owned contribution when an effect starts or stops being inhibited.
## Return its cleanup callback so the runtime can reverse it on inhibition or removal.
func on_active(_runtime: GameplayEffectRuntime, _spec: GameplayEffectSpec, _handle: int) -> Callable:
	return Callable()
