class_name MaintainEffectExecution
extends AbilityExecution
## Retains an authored effect on the actor for the lifetime of this activation.

## Infinite Gameplay Effect maintained on the ability owner while active.
@export var effect: GameplayEffectDefinition
## While active, finishes this execution on this event or a child tag. Empty leaves completion to its caller.
@export var end_on_event_tag: StringName = &""


func get_validation_error(_system: AbilitySystem) -> StringName:
	if effect == null:
		return &"missing_effect_payload"
	var indefinite := effect.timing == GameplayEffectDefinition.Timing.INFINITE \
			or (effect.timing == GameplayEffectDefinition.Timing.DURATION and effect.duration == 0.0)
	if effect.is_damage_effect() or not indefinite:
		return &"effect_must_be_indefinite"
	return effect.get_validation_error()


func begin(cast: AbilityCast) -> void:
	var refresh := _on_retained_effects_changed.bind(weakref(cast))
	cast.data[&"effect_refresh"] = refresh
	cast.get_system().effects.retained_effects_changed.connect(refresh)
	_ensure_effect(cast)


func advance(cast: AbilityCast, _delta: float) -> void:
	# A synchronous callback can invalidate the effect before its first handle is returned.
	if not cast.data.has(&"effect_handle"):
		_ensure_effect(cast)


func handle_gameplay_event(cast: AbilityCast, event_tag: StringName, _payload: Dictionary) -> void:
	if GameplayTagSet.matches(event_tag, end_on_event_tag):
		cast.finish()


func end(cast: AbilityCast, _cancelled: bool) -> void:
	var effects := cast.get_system().effects
	var refresh: Callable = cast.data.get(&"effect_refresh", Callable())
	if refresh.is_valid():
		effects.retained_effects_changed.disconnect(refresh)
		cast.data.erase(&"effect_refresh")
	var handle: int = cast.data.get(&"effect_handle", 0)
	cast.data.erase(&"effect_handle")
	effects.remove_effect(handle)


func get_effect_payload() -> Array[GameplayEffectDefinition]:
	return [effect] if effect != null else []


func _on_retained_effects_changed(cast_ref: WeakRef) -> void:
	var cast := cast_ref.get_ref() as AbilityCast
	if cast != null:
		_ensure_effect(cast)


func _ensure_effect(cast: AbilityCast) -> void:
	if cast.finished or cast.data.has(&"applying_effect"):
		return
	var effects := cast.get_system().effects
	var handle: int = cast.data.get(&"effect_handle", 0)
	if effects.has_retained_effect(handle):
		return
	cast.data.erase(&"effect_handle")
	cast.data[&"applying_effect"] = true
	handle = effects.apply_effect_spec(cast.make_effect_spec(effect))
	cast.data.erase(&"applying_effect")
	if cast.finished:
		effects.remove_effect(handle)
	elif effects.has_retained_effect(handle):
		cast.data[&"effect_handle"] = handle
