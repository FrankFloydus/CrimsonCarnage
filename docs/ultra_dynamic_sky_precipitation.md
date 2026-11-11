# Ultra Dynamic Sky 9.7 precipitation and airborne effects

The package index and [reference map](ultra_dynamic_sky_audit.md) cover the full distribution. This page follows the rain, snow, and dust paths from the local Unreal project through the particle systems and the atmosphere. Evidence comes from UE 5.8.4 object reflection, Blueprint pins, the embedded 9.7 technical manual, and offscreen Play In Editor runs with the saved DemoMap. Emitter names below identify systems within the assets. Unreal assets remain in the reference project.

## Rain

The Weather actor updates the resolved rain spawn rate and activates `Particles/Rain.uasset` when the rain particle option is enabled. The rate is the authored maximum of 20,000 multiplied by `(rain / 10)^1.7`. The saved **Rain** preset has rain 7, wind 3, fog 3, and cloud coverage 7.5 on the source scales. This gives roughly 55% of maximum spawn rate and a nearly vertical shared particle direction. **Rain Thunderstorm** drives rain and wind to 10, with fog 6.5 and cloud coverage 8. It creates a denser field with a much stronger lean. The Weather class defaults to an 18 m/s wind velocity scale, drop scale and alpha of 1, refraction intensity of 1, and sparkle of 3. These are authored Niagara inputs. The maximum spawn input describes the source system and should be compared through its visible density and motion.

| Emitter in Rain | Role |
| --- | --- |
| `CPU_Collision_0`, `GPU_Collision_2` | Build valid particle paths for the selected collision mode. The saved DemoMap uses Simple Collision. |
| `GPU_Rain_0` | Visible falling drops. `Rain_Sprite_Appearance`, `Rain_Update_Parameters`, and `Set_Weather_Sprite_Velocity` handle appearance and motion. `Materials/Weather/Rain_ParticleMat.uasset` samples the linear 64 × 128 `Textures/Weather/RainSnow_Sheet.uasset`. |
| `GPU_Splashes_0`, `GPU_Splash_Droplets_3` | A visible impact shape and secondary rebound droplets. The selected splash material path affects whether the secondary droplets are enabled. The Weather class defaults to decal mode, with a 0.02 minimum upward normal and 22 cm maximum duplicate radius. |
| `GPU_Drop_Decal_7`, `GPU_Rain_Ripples_1` | Small wet impact marks and normal response at contact. Both decal options are enabled in the desktop DemoMap. They use `Materials/Weather/Rain_Spot_Decal.uasset` and `Rain_Ripple_Decal.uasset`. |

The **Rain Drip Spline** actor in DemoMap is a separate authored runoff effect. It uses `Particles/Dripping_Curve.uasset` with `Drips`, `Splashes`, and `Collision_Cache`. The saved actor spawns at 100 drops per meter against the class default of 250. Rain under the test roof recedes near the observer while exposed ground beyond it still shows rain and impacts. The saved baseline enables wind fog and leaves screen droplets and wind debris disabled.

## Automatic lightning and thunder

`Blueprints/Weather_Effects/Weather_Presets/Rain.uasset` sets **Thunder/Lightning** to 4. `Rain_Thunderstorm.uasset` sets it to 10. In `Blueprints/Ultra_Dynamic_Weather.uasset`, `Lightning Flash Spawning` schedules full-flash attempts at `60 / 14` seconds with a random multiplier from 0.5 to 1.5. The first timer defaults to 2 s. `Global Lightning Internal` then requires the resolved local Thunder/Lightning value to exceed a random threshold from 5 to 10. Rain does not pass that threshold. Its automatic activity comes from the separate `Obscured Lightning Current Spawn Rate` and `AU - Update Thunder/Lightning Sound Parameter` paths.

The obscured emitter's nominal spawn rate is `2.5 × clamp((Thunder/Lightning − 2) / 6, 0, 1)`, giving about 0.83/s in Rain and 2.5/s in Thunderstorm. Niagara masking and particle appearance determine how often a visible flash results. `Particles/Obscured_Lightning.uasset` has separate glow, flare, and illuminated rain paths. The full `Particles/Lightning_Strike.uasset` has `Lightning_Bolt_2`, `Lightning_Flare_0`, and `Rays_0`. Its Blueprint defaults choose a root at the cloud base, 1.55–6.5 km from the viewer, within 100° of camera forward on either side. Full flash duration is 1.75–2.2 s. The source close-thunder delay is 0.15 s/km.

Godot saves **Rain** at 3.2 sheet-flash events per minute and **Storm** at 11 full-flash and 3.5 sheet-flash events per minute. The rates drive the resolved local weather, and the sheet path illuminates the cloud deck and queues thunder without a visible bolt mesh. Headless checks verified automatic dispatch for both presets. The Godot sound delay deliberately uses listener-to-strike distance at 343 m/s. A Forward+ run is needed to judge the flash appearance and mix. [Rain preset](../addons/dynamic_sky/presets/rain.tres) · [Storm preset](../addons/dynamic_sky/presets/storm.tres) · [Lightning controller](../addons/dynamic_sky/lightning/lightning.gd) · [Weather audio](../addons/dynamic_sky/audio/weather_audio.gd)

## Snow and blizzard

| Saved preset | Cloud | Fog | Snow | Wind | Material snow |
| --- | ---: | ---: | ---: | ---: | ---: |
| Light Snow | 6 | 3 | 3 | 1 | 0.5 |
| Snow | 8.5 | 5 | 6 | 4 | 1.0 |
| Blizzard | 10 | 10 | 10 | 10 | 1.0 |

`Particles/Snow.uasset` contains `CPU_Collision_0`, `GPU_Collision_2`, `GPU_Snow_0`, and `GPU_Stuck_Snow_3`. The first two support cached collision paths. The falling flakes use velocity-aligned sprites, scale variation, and `Snow_Twirl`, with spawn rate `20,000 × (snow / 10)^1.5`. The authored wind velocity scale is 15 m/s. `Snow_ParticleMat.uasset` and `Stuck_Snow_Decal_Mat.uasset` share `RainSnow_Sheet.uasset`. The contact emitter uses `Sample_Snow_Impact`, `Pin_to_Depth`, and `Move_With_Velocity_Buffer`. The default 1.5 s duration leaves a short-lived surface fleck.

The exact air-snow graph uses a linear 64 × 128 packed sheet: green is the sharp mask and blue is the defocused mask, with four independently selected cells. Its alpha channel is opaque and does not supply opacity. Particle alpha is `lerp(0.15, 0.6, random^15)` before speed and camera-distance multipliers. The world-space normal is independently tilted, and desktop emission includes 0.55 times the sampled scene color. The active renderer is velocity-aligned with pivot `(0.5, -0.5)`, no pixel-coverage expansion, and no motion-vector output. The material is composited after motion blur and temporal resolve; native fogging and hardware depth testing are disabled in that actual pass, while the material performs its own depth collapse and 1 mm soft intersection. Serialized rapid-iteration caller parameters supply the active 130 cm/s stretch denominator and 2000 cm/s speed-alpha denominator; the standalone functions' zero defaults are not the running values.

The blizzard preset drives the same particle system with stronger wind and a deeper moving whiteout. **Post Process Wind Fog** supplies the moving veil. A separate local actor can use `Particles/Radial_Storm.uasset` for fog sprites, shadow modulation, and obscured lightning. `Particles/DLWE_Interaction_System.uasset` supplies `Snow_Trail` for interacting actors. `Particles/Standalone/FreezingBreath.uasset` is an opt-in effect.

### Settled snow on materials

`Materials/Weather/DLWE_Snow.uasset` builds the longer-running snow cover separately from particles. The Weather class supplies a near-white linear base color of `(0.9, 0.9, 0.9)`, an alpha multiplier of 8, a 14 cm depth, a 0.66 upward-normal cutoff, and a 5 m texture scale. `Materials/Material_Functions/DLWE_SnowCoverage.uasset` shapes coverage using slope and world-space variation. `DLWE_VariationClouds.uasset` samples `Textures/Weather/DLWE_Noise.uasset` at the separate default 500 m variation scale. Authored surface masks, water level, and interaction trails can further affect the coverage. Depth uses world-position and pixel-depth offsets or Nanite displacement, according to the material settings.

`Snow_Normal.uasset` and `Rough_Snow.uasset` are 4K linear normal maps. The 4K linear `Snow_Scatter.uasset` is a separate coverage input, and the 512² `Windswept_Snow_Normal.uasset` aligns detail to wind. `Map_Material_Snow_Textures.uasset` provides triplanar mapping. `Snow_Sparkle.uasset` supplies a separate emissive detail path. The offscreen Blizzard reference shows a mostly continuous pale blanket on upward surfaces, with soft variation and restrained normal detail. Compare broad coverage at terrace distance and normal response close to the surface.

## Dust and sandstorms

`Particles/Dust.uasset` embeds `CPU_Collision_0`, `GPU_Collision_2`, `GPU_Dust_0`, and `GPU_Dust_Spots_3`. The latter two use `Dust_Card_Appearance` and `Dust_Spot_Appearance`. Broad translucent cards supply coarse moving concentrations and the spot layer supplies smaller visible particles. The spawn factor ramps from source dust 3 to 10 and scales a maximum count of 1,000. The Weather class supplies a 14 m/s wind velocity scale and an alpha control of 0.6, which yields a sprite alpha input of 0.33 at full dust. The source uses a 512² `Textures/Weather/Dust_Alpha.uasset` and a translucent 2 × 2 dust sheet in `Materials/Weather/Dust_ParticleMat.uasset`, with a 25 cm minimum authored size. A separate scene-fog path raises dust density sharply with the fourth power of the dust amount and suppresses direct shadows.

**Sand Dust Storm** and **Sand Dust Calm** both author dust 10, fog 1, cloud coverage 0, and full surface dust. Wind is 10 in the storm and 1 in the calm case. Matching offscreen runs retained the tan background fog with particles and wind fog disabled. Enabling them added moving near-field structure. Calm dust retained the haze with slower advection.

## Shared wind, mist, and exposure

**Post Process Wind Fog** is a separate depth-bounded ray march through advected 3D noise. The saved DemoMap uses it with regular volumetric fog off. It samples an interior weather-occlusion mask, with directional player occlusion as a fallback. The material defaults to an 18 m ray, 1.2 m steps, and a 20 m noise scale. The material composites the result into the camera view before depth of field.

The Weather actor takes the larger of a weather sum and a wind-only term, divides it by five, then applies a global gain. The saved weather sum uses a fog ramp above 4, squared rain and snow fractions, and a linear dust contribution. The wind term ramps above 3. The resulting targets at default gain are .1372 for Rain, .3967 for Rain Thunderstorm, .56 for Blizzard, and .70 for both Dust presets. High wind changes advection even when airborne density stays constant.

`Particles/Wind_Debris.uasset` is opt-in in the reference. It has two collision emitters and `Wind_Debris_Particles_1`, a separate twig-and-leaf renderer. Its count uses a squared ramp from wind 6 to 10 and a seasonal multiplier. In the saved DemoMap, wind debris is disabled by default. Ground accumulation, cloud shadows, audio occlusion, screen droplets or frost, and rain interacting with water each have separate controls.

## Godot comparison status

The saved rig uses three camera-relative rain volumes, with the near layer feeding impact splashes and the middle layer feeding stronger wind-driven contact spray. Air snow now uses one source-style velocity-aligned sprite layer, a newly generated packed green/blue atlas, and a CPU trajectory cache sampled at GPU particle birth. Snow's saved settings carry the source volume, rates, scale, and finite path lifetime. Optional contact flakes and strong-wind spindrift remain separate effects. Sandstorm separates suspended grit, bouncing ground particles, and larger moving billows. Moving mist is a world-space FogVolume with a ground probe and local roof attenuation. Rain uses the opaque heightfield; the snow cache and audio probe physics occluders. [Rain scene](../addons/dynamic_sky/precipitation/rain/rain.tscn) · [Snowfall scene](../addons/dynamic_sky/precipitation/snow/snowfall.tscn) · [Snow settings](../addons/dynamic_sky/precipitation/snow/snow_settings.tres) · [Sandstorm scene](../addons/dynamic_sky/weather/sandstorm/sandstorm_particles.tscn)

Forward+ captures exercised particle motion, rain impacts, shelter, and snow accumulation on the saved demo. Final visual parity for density, contacts, distance fade, and settled surfaces remains open. [Godot guide](dynamic_sky.md) · [Original ImageGen artwork](dynamic_sky_imagegen.md)

Compare **Rain** and **Storm** at the same camera and clock, first exposed and then under cover. Check that Rain produces automatic cloud illumination and delayed thunder without a visible channel. Check that Storm also produces full strikes. Use the lakeshore for impact ripple scale and the same upward-facing ground patches for **Snow** and **Blizzard**. For dust, compare **Sand Dust Storm** and **Sand Dust Calm** with fixed camera and lighting so faster advection can be distinguished from the persistent haze. [Reference capture setup](ultra_dynamic_sky_audit.md#reproduce-the-checks)
