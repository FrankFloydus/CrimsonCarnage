class_name HealingResolver
extends RefCounted
## Central healing path. All requests restore only currently living recipients.


static func resolve_and_commit(request: HealingRequest) -> HealingResult:
	if request == null or not is_instance_valid(request.recipient):
		return HealingResult.new(request, 0.0, 0.0, 0.0, &"invalid_recipient")
	if not is_finite(request.requested_amount) or (
			request.mode == HealingRequest.Mode.HEAL and request.requested_amount < 0.0):
		return HealingResult.new(request, 0.0, 0.0, 0.0, &"invalid_healing_amount")
	if not request.mode in HealingRequest.Mode.values():
		return HealingResult.new(request, 0.0, 0.0, 0.0, &"invalid_healing_mode")
	var health := request.recipient.get_value(CombatAttributes.Id.HEALTH)
	if health <= 0.0:
		return HealingResult.new(request, 0.0, 0.0, 0.0, &"recipient_dead")
	if request.mode == HealingRequest.Mode.SNAPSHOT_RESTORE and health + request.requested_amount <= 0.0:
		return HealingResult.new(request, 0.0, 0.0, 0.0, &"invalid_living_health_snapshot")

	var source_scaled := request.requested_amount
	var scaled := source_scaled
	var offered := scaled
	var runtime: GameplayEffectRuntime
	var depleted: Array[int] = []
	if request.mode == HealingRequest.Mode.HEAL:
		var profile := request.profile
		if profile != null:
			var validation := profile.get_validation_error()
			if not validation.is_empty():
				return HealingResult.new(request, 0.0, 0.0, 0.0, validation)
			source_scaled *= profile.source_percent / 100.0
		if not is_finite(source_scaled):
			return HealingResult.new(request, 0.0, 0.0, 0.0, &"invalid_scaled_healing")
		scaled = source_scaled
		var target := AbilitySystem.find_for(request.recipient)
		if target != null and target.attributes == request.recipient:
			runtime = target.effects
		if runtime != null and source_scaled > 0.0 and (profile == null or profile.apply_incoming_modifiers):
			scaled = runtime.resolve_healing_received(source_scaled)
		if not is_finite(scaled) or scaled < 0.0:
			return HealingResult.new(request, 0.0, 0.0, 0.0, &"invalid_incoming_healing")
		offered = scaled
		if runtime != null and scaled > 0.0 and (profile == null or profile.apply_absorption):
			offered = runtime.apply_healing_absorption(scaled, depleted)

	var restored := request.recipient.modify_current(CombatAttributes.Id.HEALTH, offered)
	var result := HealingResult.new(request, source_scaled, scaled, restored, &"", scaled - offered)
	if not depleted.is_empty():
		runtime.finish_healing_absorption(depleted)
	return result
