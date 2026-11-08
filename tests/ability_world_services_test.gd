extends SceneTree
## Deterministic checks of the session-owned link, threat, pet and lifecycle contracts.

const WORLD := &"world"
const OWNER := &"owner"
const RIVAL := &"rival"
const CREATURE := &"creature"

var _checks: int = 0
var _failures: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_links()
	_test_threat()
	_test_pet_acquisition_and_commands()
	_test_lifecycle()
	print("Ability world services checks: %d passed, %d failed." % [_checks - _failures, _failures])
	quit(0 if _failures == 0 else 1)


func _test_links() -> void:
	var links := AnchorLinkRegistry.new()
	var first := _link(OWNER, &"gateway")
	first.endpoints = [AnchorLinkRegistry.Endpoint.at(&"entry", Vector3.ZERO),
		AnchorLinkRegistry.Endpoint.at(&"exit", Vector3.RIGHT)]
	var handle := links.create(first)
	_check(handle > 0 and links.resolve(OWNER, &"gateway", &"other_world") == null,
		"Gateways require the correct world and a valid pair")
	var invalid := _link(OWNER, &"gateway")
	invalid.replace_existing = true
	_check(links.create(invalid) == 0 and links.resolve_handle(handle, WORLD) != null,
		"Failed replacement preserves the original owner slot")
	var travels: Array[StringName] = []
	var permits := func(traveler_id: StringName, entry: AnchorLinkRegistry.Endpoint) -> bool:
		return traveler_id != &"denied" and entry.id == &"entry"
	var move := func(traveler_id: StringName, position: Vector3) -> bool:
		if position != Vector3.RIGHT:
			return false
		travels.append(traveler_id)
		return true
	_check(not links.try_travel(handle, WORLD, &"entry", &"denied", &"gate", 2.0, permits, move)
		and links.try_travel(handle, WORLD, &"entry", OWNER, &"gate", 2.0, permits, move),
		"Gateway checks permission before safely moving a traveler")
	first.replace_existing = true
	var replacement := links.create(first)
	_check(replacement != handle and links.resolve_handle(handle, WORLD) == null
		and not links.try_travel(replacement, WORLD, &"entry", OWNER, &"gate", 2.0, permits, move)
		and links.try_travel(replacement, WORLD, &"entry", RIVAL, &"gate", 2.0, permits, move),
		"Gateway replacement invalidates the old handle but keeps each traveler's reuse window")
	links.advance(2.0)
	_check(links.try_travel(replacement, WORLD, &"entry", OWNER, &"gate", 2.0, permits, move)
		and travels == [OWNER, RIVAL, OWNER], "A traveler may use the pair again at reuse expiry")
	var tether := _link(OWNER, &"tether")
	tether.kind = AnchorLinkRegistry.Kind.TETHER
	var body := _body()
	tether.endpoints = [AnchorLinkRegistry.Endpoint.at(&"center", Vector3.ZERO),
		AnchorLinkRegistry.Endpoint.actor(CREATURE, body)]
	var tether_handle := links.create(tether)
	_check(links.take_tether_breaks(tether_handle, WORLD, 2.0).is_empty(),
		"A tether holds its original target in range")
	body.position.x = 3.0
	_check(links.take_tether_breaks(tether_handle, WORLD, 2.0) == [CREATURE]
		and links.take_tether_breaks(tether_handle, WORLD, 2.0).is_empty(),
		"The originally acquired target crossing range breaks its tether once")
	body.free()
	_check(links.resolve_handle(tether_handle, WORLD) == null, "Destroyed actors invalidate their links")
	links.unload_world(WORLD)
	_check(links.resolve_handle(replacement, WORLD) == null, "Scene unload invalidates its anchors")


func _test_threat() -> void:
	var threat := ThreatService.new()
	threat.register_observer(&"enemy", true)
	threat.register_observer(&"human", false)
	var damage := ThreatGenerationProfile.new()
	damage.multiplier = 2.0
	var healing := ThreatGenerationProfile.new()
	healing.transaction_tag = &"Threat.Healing"
	threat.redirect_threat(OWNER, RIVAL, damage.transaction_tag, 2.0)
	threat.redirect_threat(RIVAL, CREATURE, damage.transaction_tag, 2.0)
	_check(threat.add_threat(&"enemy", OWNER, 5.0, damage) == RIVAL
		and threat.get_threat(&"enemy", RIVAL) == 10.0 and threat.get_threat(&"enemy", CREATURE) == 0.0,
		"Threat uses the transaction profile and redirects credit only once")
	_check(threat.add_threat(&"enemy", OWNER, 4.0, healing) == OWNER
		and threat.get_threat(&"enemy", OWNER) == 4.0, "Redirects honor their transaction filter")
	var taunt := ThreatTauntProfile.new()
	taunt.override_seconds = 1.0
	taunt.priority = 2
	_check(threat.apply_taunt(&"human", OWNER, taunt) == 0
		and threat.apply_taunt(&"enemy", OWNER, taunt) > 0
		and threat.get_target(&"enemy") == OWNER and threat.get_threat(&"enemy", OWNER) == 10.0,
		"Taunt normalizes and forces AI attention only where the observer permits it")
	var low_priority := ThreatTauntProfile.new()
	low_priority.match_highest_threat = false
	low_priority.override_seconds = 2.0
	threat.apply_taunt(&"enemy", RIVAL, low_priority)
	_check(threat.get_target(&"enemy") == OWNER, "Higher priority taunt wins over a newer override")
	threat.advance(2.0)
	threat.add_threat(&"enemy", CREATURE, 8.0, damage)
	threat.suppress_attention(OWNER, 3.0, true)
	_check(threat.get_target(&"enemy") == CREATURE and threat.get_threat(&"enemy", OWNER) == 0.0
		and threat.get_threat(&"enemy", CREATURE) == 16.0,
		"Feign-style attention suppression clears the owner without affecting independent pet threat")
	threat.advance(3.0)
	_check(threat.add_threat(&"enemy", OWNER, 1.0, damage) == OWNER,
		"Redirect and attention suppression end on their configured expiry")


func _test_pet_acquisition_and_commands() -> void:
	var pets := PetOwnershipService.new()
	var candidate := _candidate(OWNER, CREATURE)
	var rival := _candidate(RIVAL, CREATURE)
	var valid := func(_record: PetOwnershipService.PetRecord, _world_id: StringName) -> bool:
		return true
	var invalid := func(_record: PetOwnershipService.PetRecord, _world_id: StringName) -> bool:
		return false
	var handle := pets.reserve_acquisition(candidate, WORLD, valid)
	_check(handle > 0 and pets.reserve_acquisition(rival, WORLD, valid) == 0
		and pets.reserve_acquisition(_candidate(OWNER, &"other_creature"), WORLD, valid) == 0,
		"Reservations hold both the creature and owner capacity against competing channels")
	_check(not pets.complete_acquisition(handle, WORLD, invalid, valid) and pets.get_record(CREATURE) == null,
		"Failed eligibility after channeling leaves no persistent ownership")
	var canceled := pets.reserve_acquisition(rival, WORLD, valid)
	pets.cancel_actor(RIVAL)
	_check(canceled > 0 and not pets.complete_acquisition(canceled, WORLD, valid, valid),
		"Canceling a disconnected owner releases the tame reservation")
	var committed := pets.reserve_acquisition(candidate, WORLD, valid)
	_check(pets.complete_acquisition(committed, WORLD, valid, valid)
		and not pets.complete_acquisition(committed, WORLD, valid, valid)
		and pets.reserve_acquisition(rival, WORLD, valid) == 0,
		"Persistent ownership commits exactly once and excludes competing owners")
	var restored := PetOwnershipService.new()
	_check(restored.load_records(JSON.parse_string(JSON.stringify(pets.save_records())))
		and restored.get_record(CREATURE).owner_id == OWNER
		and restored.get_active_pet(OWNER, WORLD).is_empty(), "Pet save restores stable records without live bindings")
	_check(pets.set_temporary_pet(OWNER, &"summon", WORLD) and pets.get_record(&"summon") == null
		and not pets.set_temporary_pet(RIVAL, &"summon", WORLD),
		"A temporary pet binds to one owner without creating a persistent record")
	pets.set_active_pet(OWNER, CREATURE, WORLD)
	var payments: Array[StringName] = []
	var dispatches: Array[StringName] = []
	var validate := func(request: PetCommandAdapter.CommandRequest) -> bool:
		return request.executor_id == CREATURE and request.credited_owner_id == OWNER \
			and request.target_id == &"enemy" and request.payer_id == RIVAL
	var pay := func(request: PetCommandAdapter.CommandRequest) -> bool:
		payments.append(request.payer_id)
		return true
	var dispatch := func(request: PetCommandAdapter.CommandRequest, should_pay: bool) -> bool:
		if should_pay:
			payments.append(request.payer_id)
		dispatches.append(request.executor_id)
		return true
	var commands := PetCommandAdapter.new(pets, validate, pay, dispatch)
	var request := PetCommandAdapter.CommandRequest.new()
	request.ability_id = 270
	request.credited_owner_id = OWNER
	request.payer_id = RIVAL
	request.target_id = &"enemy"
	request.world_id = WORLD
	var command := commands.accept(request)
	_check(command > 0 and payments.is_empty() and commands.execute(command)
		and payments == [RIVAL] and dispatches == [CREATURE],
		"Execution payment keeps payer, active pet executor and credited owner distinct")
	request.payment_milestone = PetCommandAdapter.PaymentMilestone.ACCEPTANCE
	command = commands.accept(request)
	pets.unload_world(WORLD)
	_check(command > 0 and not commands.execute(command) and payments == [RIVAL, RIVAL]
		and dispatches == [CREATURE], "Accepted cost remains committed after the pet's world unloads")


func _test_lifecycle() -> void:
	var lifecycle := LifeCycleService.new()
	var original := _body()
	var replacement := _body()
	var source := _body()
	lifecycle.register_actor(OWNER, original)
	lifecycle.register_actor(RIVAL, source)
	var deaths: Array[StringName] = []
	var resurrections: Array[StringName] = []
	lifecycle.died.connect(func(id: StringName) -> void: deaths.append(id))
	lifecycle.resurrected.connect(func(id: StringName, _caster: StringName, _node: Node3D) -> void:
		resurrections.append(id))
	var profile := ResurrectionProfile.new()
	profile.health_fraction = 0.4
	profile.budget_id = &"encounter"
	lifecycle.set_encounter_budget(&"encounter", 1)
	var entitlement := lifecycle.grant_entitlement(OWNER, RIVAL, profile)
	var threat := ThreatService.new()
	threat.suppress_attention(OWNER, 2.0)
	_check(entitlement > 0 and not lifecycle.offer(entitlement) and deaths.is_empty()
		and lifecycle.get_state(OWNER) == LifeCycleService.State.ALIVE,
		"Feign-style attention suppression never creates a real death or resurrection offer")
	_check(lifecycle.begin_death(OWNER) and lifecycle.commit_death(OWNER)
		and not lifecycle.commit_death(OWNER) and lifecycle.mark_corpse(OWNER) and deaths == [OWNER],
		"Committed death enters corpse state and publishes exactly one death")
	original.free()
	lifecycle.advance(0.1)
	_check(lifecycle.get_state(OWNER) == LifeCycleService.State.RELEASED
		and lifecycle.get_body(OWNER) == null and lifecycle.offer(entitlement),
		"Entitlement survives destruction of the original body")
	var restore := func(actor_id: StringName, corpse: Node3D, data: ResurrectionProfile) -> Node3D:
		return replacement if actor_id == OWNER and corpse == null and data.health_fraction == 0.4 else null
	var fail_restore := func(_actor_id: StringName, _corpse: Node3D, _data: ResurrectionProfile) -> Node3D:
		return null
	_check(not lifecycle.restore(entitlement, false, restore) and lifecycle.decline(entitlement)
		and lifecycle.offer(entitlement), "Explicit acceptance is required and a configured decline can retry")
	_check(not lifecycle.restore(entitlement, true, fail_restore)
		and lifecycle.get_encounter_budget(&"encounter") == 1
		and lifecycle.offer(entitlement), "Failed placement rolls back the shared encounter reservation")
	_check(lifecycle.restore(entitlement, true, restore) and not lifecycle.restore(entitlement, true, restore)
		and lifecycle.get_state(OWNER) == LifeCycleService.State.ALIVE
		and lifecycle.get_body(OWNER) == replacement and lifecycle.get_encounter_budget(&"encounter") == 0
		and resurrections == [OWNER], "A valid replacement commits one resurrection and consumes the budget")
	profile.cancel_on_source_death = true
	profile.budget_id = &""
	var dependent := lifecycle.grant_entitlement(OWNER, RIVAL, profile)
	lifecycle.begin_death(RIVAL)
	lifecycle.commit_death(RIVAL)
	lifecycle.begin_death(OWNER)
	lifecycle.commit_death(OWNER)
	_check(dependent > 0 and not lifecycle.offer(dependent), "Configured source death revokes the entitlement")
	replacement.free()
	source.free()


func _link(owner_id: StringName, slot: StringName) -> AnchorLinkRegistry.LinkRecord:
	var record := AnchorLinkRegistry.LinkRecord.new()
	record.owner_id = owner_id
	record.slot_id = slot
	record.world_id = WORLD
	return record


func _candidate(owner_id: StringName, pet_id: StringName) -> PetOwnershipService.PetRecord:
	var record := PetOwnershipService.PetRecord.new()
	record.owner_id = owner_id
	record.pet_id = pet_id
	record.slot_id = &"first_pet"
	record.species_id = &"test_species"
	return record


func _body() -> Node3D:
	var body := Node3D.new()
	root.add_child(body)
	return body


func _check(passed: bool, message: String) -> void:
	_checks += 1
	if not passed:
		_failures += 1
		push_error(message)
