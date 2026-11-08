# Composable ability v2 coverage

This audit follows §28 and Appendix C of the supplied v2 specification. The source contains 50 consecutive reference IDs W01–W50 and 622 consecutive Skyrim index IDs. The 18 domain totals match their Appendix C headings. The reference profiles describe behavior. Their game-specific coefficients, schools, class resources, variant rules, and historical balance require separate source verification.

The saved [Blood Lash and Crimson Bolt fixtures](ability_v2_fixtures.md) are the authored v2 acceptance recipes. The W01–W50 rows below report which parts of each reference can be composed or exercised with existing primitives. Every W profile still needs its own end-to-end recipe test. The Skyrim table tracks coverage by domain. The per-entry 622-recipe and test matrix remains open.

| Status | Meaning |
| --- | --- |
| Composable | The relevant behavior can be represented with the current authoring primitives using this project's stat and school catalogue. |
| Partial | Relevant implementation exists and a named behavior or proof still needs work. |
| Adapter required | The reference needs a game-domain adapter beyond the current combat scene or services tested with an adapter fixture. |

## W01–W50 reference workflows

| ID | Reference | Status | Available path and remaining check |
| --- | --- | --- | --- |
| W01 | Frostbolt | Composable | Projectile impact can apply Cold damage and a distinct slow status. Blood Lash tests independent slow eligibility and absorption. Verify the full projectile recipe. |
| W02 | Arcane Missiles | Composable | The delivery fixture verifies launched pulse projectiles continue after channel interruption and future pulses stop. Arcane is outside the current damage-school catalogue. |
| W03 | Arcane Explosion | Partial | Caster area burst and an `On Hit` reaction once per execution can award an existing pool. Arcane Charge is outside the current resource catalogue. |
| W04 | Blink | Adapter required | Activation exceptions and tag-based removal cover the control policy. Safe teleport and atomic commitment with control removal need a movement adapter. |
| W05 | Counterspell | Composable | The Interrupt Cast action uses the actual interrupted school and applies lockout on success. Execution checks cover matching school and no-op failures. Verify the hostile-target recipe. |
| W06 | Polymorph | Partial | A timed status can break on damage and occupy an exclusive source-owned slot. Creature filters can use authored actor tags. A presentation/body override and target recovery profile still need their game integration. |
| W07 | Ice Barrier | Composable | A retained effect supplies finite absorption and committed-hit observers. The effect suite verifies that an observer can react to the contact that exhausts the shield. |
| W08 | Spellsteal | Composable | Transfer Effect selects one opt-in effect by ID and asset tags, then applies time and stack limits. A targeted phase test verifies preservation of a spent shield and source rollback when the recipient rejects it. |
| W09 | Alter Time | Composable | Snapshot Toggle captures selected pools and an optional body transform. The effect suite verifies same-world, range and swept collision checks and a later retry after a rejected restore. |
| W10 | Touch of the Magi | Partial | An effect can accumulate damage for its source and target, then publish one amount at expiry. An outcome-driven area detonation still needs a composed action path. |
| W11 | Corruption | Composable | Direct and periodic damage can use separate effects, and periodic effects support source-owned refresh. Crimson Bolt covers that core path. Select a live school for the equivalent recipe. |
| W12 | Agony | Partial | A retained ramp can increase periodic damage and keep its state on refresh. The shard pool and the edition-specific generation model need separate design. |
| W13 | Drain Life | Composable | Beam targeting and channel pulses can deliver damage with a source-scoped lifesteal reaction. Beam pulse costs and damage-based lifesteal are tested separately. The combined recipe remains unverified. |
| W14 | Unstable Affliction | Composable | A Dispel action records reason and instigator. An effect removal reaction can target the dispeller with damage and a silence status. Verify the DoT and both backlash effects through a saved cleanse recipe. |
| W15 | Seed of Corruption | Partial | Damage thresholds and natural expiry share an effect-owned publication gate, and reactions have bounded causal dispatch. Area detonation, nearby DoT application and seed chaining still need a composed path and test. |
| W16 | Havoc | Partial | An exclusive slot can resolve a linked target and echo source-stage damage through its defenses with copied provenance. General payload echo with attached non-damage effects still needs a contract. |
| W17 | Summon Felhunter | Adapter required | A temporary pet binding can identify a commandable actor, and the pet can use the shared interruption primitive. Spawning, loadout, owner slots, replacement cleanup and summon AI need a world adapter. |
| W18 | Demonic Circle: Teleport | Adapter required | The anchor registry resolves a versioned owner slot and invalidates replaced or unloaded anchors. Safe teleport and its atomic control removal need the movement adapter. |
| W19 | Demonic Gateway | Adapter required | The link fixture verifies pair resolution, traveler-specific reuse and permission/placement callbacks. Actual endpoint scenes and interaction routing need world integration. |
| W20 | Soulstone | Adapter required | The lifecycle fixture verifies stable entitlement, consent, body replacement, single consumption and shared budget rollback. Actual representation, resource restoration and world acceptance need game integration. |
| W21 | Charge | Adapter required | Typed channels, control status and resource recovery are available. Collision-aware displacement and contact commitment require a movement adapter. |
| W22 | Mortal Strike | Composable | A damage payload can attach a retained incoming-healing multiplier. Ordinary healing and lifesteal share `HealingResolver`. Verify the selected stacking rule with an authored weapon strike. |
| W23 | Execute (Arms variable-Rage profile) | Partial | Variable spending produces an immutable receipt usable as an amount basis. Authored activation conditions can require a target Health fraction before payment. Rage is outside the current resource catalogue. |
| W24 | Whirlwind (Fury empowerment profile) | Composable | Area bursts can attach retained damage-echo empowerment. Outcome checks verify a finite use covers multiple damage packets and nearby targets on one attack. The full initial strike and empowerment recipe still needs its saved-asset test. |
| W25 | Pummel | Composable | Reuse the Interrupt Cast action with a short hostile range. The interrupt result carries the failed or interrupted state and school. Verify the melee variant end to end. |
| W26 | Shield Block | Partial | A retained Block policy can filter damage tags, owner tags and facing, then reduce damage after defenses. Live shield equipment and the Shield Slam variant still need their gameplay bindings. |
| W27 | Spell Reflection | Composable | A finite-use reflection can redirect matching spell payloads before defenses. The runtime test verifies that the original target's shield stays intact. Auxiliary magic protection can use a separate effect component. |
| W28 | Ignore Pain | Partial | An Absorb component has a fractional per-hit limit, a finite budget and a recast cap. Rage and the profile's source-specific budget scaling need a dedicated recipe. |
| W29 | Taunt | Adapter required | Threat tests verify normalization, priorities, expiry and observer opt-in. Live AI must read target selection and provide eligibility. |
| W30 | Bladestorm | Composable | Channel pulses, immunity tags, and authored channel conflicts can model a mobile cast with separate defensive allowances. Verify simultaneous movement and defensive activation through an authored ability. |
| W31 | Holy Shock | Partial | Friendly and hostile phase targeting can use separate healing and damage actions. A resource award can use once-per-execution scoping. Holy damage and Holy Power are outside the current catalogue. |
| W32 | Word of Glory | Partial | Friendly targeting, typed cost and central healing are available. The exact Holy Power pool is outside the current catalogue. |
| W33 | Consecration | Composable | A stationary field can periodically query hostile occupants at its contact point. Verify the recipe keeps its location while the caster moves and includes later entrants. |
| W34 | Hammer of Justice | Composable | A timed stun can publish counted control tags for interruption, activation and player movement. Verify the full hostile-target recipe with an immunity profile. PvP diminishing returns require a separate policy. |
| W35 | Cleanse (Holy profile) | Composable | The Dispel action filters by effect identity and asset tags, caps removal count and carries dispeller attribution into removal reactions. Verify the ally cleanse and backlash interaction in a saved recipe. |
| W36 | Blessing of Freedom | Composable | Category tags can select existing impairments for removal and grant immunity to incoming matching statuses. Separate unrelated DoT effects keep their own handles. Verify this combination through a saved ally recipe. |
| W37 | Blessing of Protection | Partial | Target-tag gates, physical-only immunity and a recipient-scoped restriction can be represented. Atomic application of protection and restriction needs a specific multi-caster test and commit policy. |
| W38 | Blessing of Sacrifice | Partial | A capped fraction can route to the original source before either Health pool commits. Derived routing is blocked. The exact variant's source-health threshold and child mitigation rules need recipe-level verification. |
| W39 | Beacon of Light | Composable | A linked healing reaction chooses before-overheal or actual-restoration basis and excludes copied provenance. The outcome fixture verifies separate incoming healing and clamping. The historical whitelist needs its own recipe data. |
| W40 | Divine Shield | Partial | Damage, status and control immunity are separate primitives and can use tags and activation exceptions. Verify combined cleanse and protection with recipient restrictions and the intended bypass categories. |
| W41 | Aimed Shot | Partial | Cast-time delivery, payment timing and recharge pools are available. The execution suite covers charge availability and interruption. Focus is outside the current resource catalogue. |
| W42 | Kill Command (Beast Mastery profile) | Adapter required | The command fixture resolves the active pet and verifies separate payer, executor and credit with acceptance or execution payment. A pet ability dispatcher must validate real targets and wire attribution. |
| W43 | Mend Pet | Adapter required | Stable pet identity and central healing support the base behavior. An active-pet target selector and periodic healing recipe still need pet-domain integration. |
| W44 | Disengage | Adapter required | The player movement controller owns collision and locomotion. A reusable backward displacement action with swept trajectory and cancellation needs its adapter. |
| W45 | Freezing Trap | Composable | Trap arming, single activation and independent Break On Damage control are covered by primitive tests. The combined trap and retained status recipe remains unverified. |
| W46 | Binding Shot (rooting profile) | Adapter required | The tether fixture verifies one-shot range crossing for original members. Live anchor delivery and threshold-to-root dispatch need game integration. |
| W47 | Misdirection | Adapter required | Typed threat redirects have bounded lifetimes and preserve combat credit. An encounter adapter must ingest committed outcomes and start the redirect on the first qualifying attack. |
| W48 | Feign Death | Adapter required | Threat suppression and true lifecycle are independent, and the fixture verifies that suppression leaves pet threat and resurrection entitlement intact. AI reevaluation and authored presentation need integration. |
| W49 | Tame Beast | Adapter required | Creature and slot reservations, commit rollback, cancellation and record reload are fixture-tested. Tameability, channel ownership and the gameplay handoff need the pet adapter. |
| W50 | Aspect of the Turtle | Partial | Deflection, block/reduction and action-tag restrictions are distinct primitives. Verify the combined profile's nondeflected damage, source attribution and permitted defensive actions. |

## Skyrim research domains

These counts are the attachment's normalized atlas classification. A row describes shared implementation and its integration boundary across the domain.

| Primary domain | Indexed rows | Status | Available path and boundary |
| --- | ---: | --- | --- |
| Attack | 66 | Partial | Live Fireball, action-scoped weapon damage, hostile Accuracy, Armor, resistance, criticals and area burst cover the main damage paths. Full perk, enchantment, shout and weapon grant combinations remain unverified. |
| Damage over time | 30 | Partial | Retained ticks, duration, end-tick policy, source stacking and field, aura and trap carriers cover generic periodic damage. Crimson Bolt verifies the direct-plus-periodic recipe. Specific cloak and rune integrations still need recipe tests. |
| Debuff | 22 | Partial | Timed/infinite modifiers, a movement multiplier, source scope, removal and category immunity are implemented. Disease, item poison and world-specific eligibility depend on game adapters. |
| Control | 77 | Partial | Status profiles, action interruption, school lockout, root/stun movement gates and break on damage exist. AI fear, frenzy, calm, command, paralysis representation and associated restoration need game integration. |
| Defense | 65 | Partial | Armor, resistance, finite absorption, immunity, facing-aware block, reflection, deflection and routing to the original source cover reusable defense policies. Shield equipment, ward collision and arbitrary routing recipients remain open. |
| Buff | 49 | Partial | Owned modifiers, counted tags, grants, duration and exclusivity cover reversible buffs. Equipment, potion and progression bindings still need their respective domain adapters. |
| Healing | 36 | Partial | Central healing, healing received, absorption, overheal, copied healing and lifesteal primitives are available. Full cleanse recipes, cure categories, healing fields and live resurrection require more integration. |
| Resources | 63 | Partial | Clamped Health, Stamina and Mana, typed cost/recovery, spent receipts, passive regeneration and recharge pools are implemented. Extra class resources, transferable soul charges and item costs require their own domains. |
| Summoning | 79 | Adapter required | Pet ownership, stable slots and command coordination are fixture-tested. Scene spawning, summon caps, corpse reanimation, bound items and AI require domain integration. |
| Transformation | 5 | Adapter required | Grants and retained modifiers can provide scoped numeric changes. Full forms need a representation, controller, hitbox and equipment adapter with reliable restoration. |
| Mobility | 10 | Partial | Live jump, sprint and movement speed/control use the shared actor system. Dash, safe teleport, mounts and actor-local time control need movement and world adapters. |
| Stealth | 19 | Adapter required | Tags and effect lifetimes can carry stealth state. Sight, hearing, detection, silent interaction and stealth presentation need their game services. |
| Perception | 16 | Adapter required | Actor targeting can support spatial selection. Detection rules, light, night vision, reveal and visibility filtering need a perception adapter. |
| Manipulation | 7 | Adapter required | Targeting and anchors provide validated location and actor identities. Telekinesis, soul trap, weather and other world mutations need their gameplay transactions. |
| Interaction | 26 | Adapter required | Gameplay events and phases can coordinate an action. Locks, pickpocketing, permissions, inventory, dialogue and crime need their domain adapters. |
| Crafting | 29 | Adapter required | Modifiers can describe effects of crafted items. Recipe validation, materials, enchantment, transmutation and quality require a crafting adapter. |
| Economy | 17 | Adapter required | Carried Weight and Carry Capacity exist as actor attributes. Vendor, item ownership, currency, loot and barter transactions require game services. |
| Progression | 6 | Adapter required | The project has numeric character-level rules and ability grants. Skill XP, book effects, perk trees and respec/refunds need progression integration. |
| **Total** | **622** |  |  |

## Primitive verification

- Timed costs, variable spending, school lockout, channel compatibility and charge persistence. [Execution checks](../tests/ability_v2_execution_test.gd)
- Beam costs, detached projectile pulses, aura occupancy, trap arming and prepayment conditions. [Delivery checks](../tests/ability_v2_delivery_test.gd)
- Damage and status immunity, absorption, reflection, routing, retained state and explicit removal. [Effect runtime checks](../tests/effect_v2_runtime_test.gd)
- Shared event scoping, lifesteal and linked damage/healing copying. [Outcome checks](../tests/combat_outcomes_test.gd)
- Independent targeting, slow eligibility, hit reactions, projectile delivery and periodic scheduling. [Blood Lash and Crimson Bolt checks](../tests/ability_v2_fixtures_test.gd)
- Authored transfer selection, caps, destination rejection and spent shield state through the targeted activation path. [Transfer checks](../tests/ability_transfer_effect_test.gd)
- Link replacement, traveler reuse, tether break, threat attribution, pet acquisition and lifecycle restoration through test adapters. [World service checks](../tests/ability_world_services_test.gd)
