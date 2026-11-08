# Ability world services

The [ability framework](ability_system.md) owns local casts, attributes and effects. The helpers in [`combat/services/`](../combat/services/) own state that spans multiple actors or an actor's current representation. A world or encounter coordinator creates them, passes stable actor and world IDs, advances their clocks with simulation time, and calls the documented cleanup methods. They have no autoload or Inspector node. Threat and resurrection policies are editable Resources. The helpers currently run in the headless fixture, with gameplay adapters supplied by the caller.

## Anchors and links

Create an `AnchorLinkRegistry.LinkRecord` with an owner ID, an owner-exclusive slot ID, a world ID, and one or more endpoints. Use `Endpoint.at()` for a fixed position and `Endpoint.actor()` for a live `Node3D`. `create()` returns a handle. A valid replacement can invalidate the previous handle if `replace_existing` is enabled. A failed replacement keeps the existing slot. A different owner can use the same slot name independently.

- `resolve()` and `resolve_handle()` validate the world and endpoints and return a snapshot for immediate use. Endpoint bodies are weak references. A duration of zero keeps the link until removal or invalidation.
- `try_travel()` resolves the other endpoint of a pair and checks the entry adapter's permission before the placement adapter runs. Only successful placement starts the traveler's reuse window. The reuse group survives replacement of the endpoint pair and can be shared by multiple pairs.
- `Kind.TETHER` uses the first endpoint as the tether center and the remaining endpoints as the original acquisition set. `take_tether_breaks()` returns each live endpoint once when it moves beyond the supplied distance. Disappearance of one target leaves the other tethers active.
- `advance()`, `unload_world()` and `remove_owner()` enforce expiration and cleanup. Listen to `invalidated` if an external effect or delivery owns additional state for the link.

This service covers the link operations for the v2 Demonic Circle, Demonic Gateway and Binding Shot references. Surface validation, interaction scenes, placement safety and on-break ability payloads require a world adapter. Live links and reuse windows are session state and are recreated or dropped on load.

## Threat and attention

Register an observer with `ThreatService.register_observer()` and declare whether its rules permit forced target overrides. Feed a committed outcome to `add_threat()` for each eligible observer with an explicit actor credit and `ThreatGenerationProfile`. The profile scales the input and labels its category. Observer selection and whether healing, proximity or an immune actor should generate threat belong to the calling encounter rules.

- `apply_taunt()` can normalize the taunting actor's threat to the highest recorded amount and set a temporary target override. Higher priority wins. The newest override wins ties. A human-controlled observer can decline overrides by policy.
- `redirect_threat()` returns a timed handle. The latest matching redirect rewrites the credit once per transaction. The original damage or healing outcome is unaffected.
- `suppress_attention()` removes an actor from target selection for a duration and optionally clears its existing ledger entries. Suppression leaves pet entries and actor lifecycle state independent. `attention_changed` tells an AI adapter to read the current selection.
- `remove()`, `remove_actor()` and `advance()` clean up overrides, redirects, suppression and ledger entries. Threat state is scoped to the encounter.

The ledger checks cover the v2 Taunt, Misdirection and Feign Death primitives. NPC target choice and automatic ingestion of committed combat outcomes still require an encounter adapter.

## Pet acquisition and commands

`PetOwnershipService.reserve_acquisition()` holds a stable creature ID and an owner slot during a tame channel. The caller supplies a read-only eligibility check for species, capacity and world rules. `complete_acquisition()` runs the eligibility check again and calls the scene's synchronous ownership adapter. The adapter must leave ownership unchanged on failure. `cancel_acquisition()`, `cancel_actor()` and `unload_world()` release pending reservations. A committed record owns its slot and creature until the pet domain changes its persistent records.

`set_active_pet()` associates a committed record with a currently available representation. `set_temporary_pet()` associates a summon that has a distinct stable ID and no persistent record. `PetCommandAdapter` resolves the active executor, validates a granted ability and target through the dispatch adapter, and keeps the payer and credited owner explicit. An acceptance cost remains spent if the target later becomes invalid. An execution cost commits with successful dispatch through the supplied transaction adapter. Commands carry handles that can be canceled while pending.

`save_records()` returns a versioned value-only payload for the pet domain. `load_records()` validates it atomically and restores owned slots. Scene bindings and reservations start fresh. The headless fixture proves one-owner acquisition under competing requests, rollback and owner/executor/payer separation. Creature eligibility, summon spawning, pet representations, real payment and dispatch require the corresponding gameplay adapters before Felhunter, Kill Command, Mend Pet or Tame Beast can be signed off.

## Actor lifecycle and resurrection

`LifeCycleService.register_actor()` associates stable identity with a weak body reference. The actor adapter calls `begin_death()` and either `cancel_death()` or `commit_death()`. Only committed death emits `died`. The world can mark a live representation as a corpse and release its body while retaining actor identity. `advance()` also detects released corpses when their representation disappears.

An authored `ResurrectionProfile` defines expiration, optional encounter budget, acceptance and decline rules, source-death policy and requested resource fractions. `grant_entitlement()` returns a handle. The caller offers it after death using `offer()`. `restore()` takes acceptance and a synchronous adapter that validates safe placement and returns the restored live representation. Returning null means the adapter applied no changes. The service reserves the shared budget before restore and returns it on failure. A successful restore consumes the entitlement, commits the budget and emits `resurrected` once.

Entitlements survive body disposal during the session. Combat uses `AbilitySystem`'s actor-local health and death handling. The fixture demonstrates the Soulstone entitlement contract through a test world adapter. A live resurrection path needs safe player-body replacement and resource restoration. Cross-session entitlements and reanimation need separate game adapters.

## Headless verification

```powershell
godot --headless --path . --editor --import --quit
godot --headless --path . --script res://tests/ability_world_services_test.gd
```

The fixture checks committed state and cleanup for link replacement, traveler cooldowns, tether displacement, timed threat overrides, redirect attribution, pet acquisition and save/reload, and resurrection after body destruction.
