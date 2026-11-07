# Composable ability fixtures

The two saved abilities under [tests/fixtures/ability_v2](../tests/fixtures/ability_v2) are editable recipe examples. Grant a copy through an actor's **AbilitySystem → Granted Abilities** to try it in a scene. Assign a faction to each actor and add the intended enemy factions to the source's **Hostile Factions**. For projectile delivery, the source needs a casting origin and an aim origin, and target hitboxes must be on a layer selected by the projectile. The saved fixture projectile is a collision carrier; attach presentation to a copy of its scene when making a gameplay asset.

To bind a fixture in a copy of the example caster scene, grant the ability and set **AbilityInput → Ability Id** to its saved ID, `fixture_blood_lash` or `fixture_crimson_bolt`. The caster input activates that grant on F or the left mouse button.

These recipes use Necrotic damage and omit payment and cooldown for testing. Blood Lash uses a ±2 m vertical tolerance and a two-second slow. Crimson Bolt uses 40 direct damage. Set those values for your gameplay ability before granting it.

## Blood Lash

1. Create an **AbilityDefinition** with **Phased Ability Execution**. Set **Targeting** to a caster-centered **Disk** with radius 20 m, the desired vertical tolerance, **Hostile** allegiance, and **Max Targets** 0. The selection uses one entry per actor, including actors on the horizontal and vertical boundaries.
2. Set **Delivery** to **Area Burst**. Add a `delivery.impact` phase with one **Apply Effects** action using **Delivered Hit**. Add an instant damage effect with **Gameplay Effect Damage Execution → Amount → Fixed** set to 20 and select the damage type and school.
3. Add a separate timed effect to the same action. Use a **Movement Speed** modifier with operation **Final Movement Percent** and value −50. Author duration and stacking, and set a **Slow** status profile with the tags that grant slow immunity.
4. On the ability, add a reaction on **Hit**, select **Credited Owner**, and set **Once Policy** to **Per Execution Target**. Add **Restore Resource** for Mana. Use a **Resource Percent** amount with **Source** as the actor, **Mana** as the pool, **Maximum** as the basis, **Snapshot** timing, and **Percentage** 1.

An absorbed contact can qualify for the refund and the target's slow has its own immunity check. A fully rejected payload does not qualify. Set the reaction trigger to **On Health Damaged** when the refund should require positive Health loss. With 200 captured maximum Mana and four qualifying enemies, the request totals eight Mana before clamping.

## Crimson Bolt

1. Create a **Phased Ability Execution** with **Targeting → Point**, **Aim** origin, **Hostile** allegiance, and a range. Select **Projectile** delivery and assign a scene whose root uses the **AbilityProjectile** script.
2. Add a `delivery.impact` phase with one **Apply Effects** action using **Delivered Hit**. Add an instant effect with **Gameplay Effect Damage Execution** and set its fixed amount to the chosen direct damage.
3. Attach a reaction to that instant effect. Select **On Health Damaged**, **Direct** timing, and **Credited Owner**. Add a **Heal** action with **Outcome Percent**, **Actual Health Damage** basis, and **Percentage** 10. Configure a healing profile if the ability needs specific healing rules.
4. Add a separate damage effect to the same impact action. Use **Duration** 5 seconds, **Period** 1 second, **Execute Periodic On Application** disabled, and **Tick At End** enabled. Set each tick's amount to 20. The fixture refreshes and resets a single stack per source on reapplication. **Snapshot Source** captures the damage input, while each tick evaluates the target's current defenses.

An impact that removes 25 Health requests 2.5 healing. Overkill uses actual Health lost. The periodic effect ticks at 1, 2, 3, 4, and 5 seconds after impact, with its final tick before expiry.

## Validation

Import the project once and pass related ability and effect files in one invocation so duplicate IDs are checked across the collection. The validator reports the path and property or referenced resource for each issue.

```powershell
godot --headless --path . --editor --import --quit
godot --headless --path . --script res://tools/validate_combat_resources.gd -- res://tests/fixtures/ability_v2/blood_lash.tres res://tests/fixtures/ability_v2/crimson_bolt.tres
godot --headless --path . --script res://tests/ability_v2_fixtures_test.gd --fixed-fps 60
```

Asset validation checks IDs, tags, dependencies, resource cycles, and definition rules. Actor-specific scene wiring still runs through activation validation. The separate behavior tests construct in-memory recipes and exercise the normal activation, projectile, effect, and resource paths.
