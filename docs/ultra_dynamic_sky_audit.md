# Ultra Dynamic Sky 9.7 reference map

## Source and evidence

The reference is Everett Gunther's Ultra Dynamic Sky 9.7 under `C:/Users/Drako/Documents/PROJECTS/_UNREAL/Untitled/Content/UltraDynamicSky`. The serialized version label in `Blueprints/System/Editor_UI/UDS_CurrentVersion.uasset` is **9.7**. That package records Unreal's 5.5 release branch. The host project declares Unreal 5.8, and the locally installed editor is 5.8.4. The source is a Content distribution under `/Game/UltraDynamicSky`, with no `.uplugin`, native source, or standalone license text in the inspected folder. The Godot addon is independently authored from the feature map and contains original Godot resources. [Publisher documentation for 9.7](https://www.ultradynamicsky.com/Documentation/V9/9-7) · [Publisher listing](https://www.fab.com/listings/84fda27a-c79f-49c9-8458-82401fb37cfb)

The file inventory comes from the local folder and matches the Unreal Asset Registry scan. Headless UE 5.8.4 loaded 125 Blueprint and widget packages, including editor utilities. Reflection collected graph names across those packages and K2 nodes and pins for the four main actors and libraries listed below. The bundled manual in `Blueprints/System/Editor_UI/UDS_Readme_Entries.uasset`, including its technical notes, supplies behavior and call-flow evidence. A string or package reference by itself establishes presence. This map distinguishes documented behavior from what the registry and graph reflection establish.

Multiplayer replication, Voxel Clouds, and cloud painting are excluded from the Godot parity scope. Their packages remain in the source inventory.

## Asset inventory

| Directory | Packages | Contents |
| --- | ---: | --- |
| `Blueprints/` | 258 | Sky and Weather actors, enum assets, data definitions, presets, utilities, widgets, and editor tools |
| `Maps/` | 4 | `DemoMap.umap`, plus the three materials under `DemoMaterials/` |
| `Materials/` | 233 | Sky, cloud, fog, post-process, space, weather, material functions and instances, and curves |
| `Meshes/` | 34 | Effect and utility geometry, editor labels, and snow pile meshes |
| `Particles/` | 63 | Niagara systems, emitters, reusable modules, and three standalone effects |
| `Sound/` | 99 | Weather loops and one-shots, MetaSounds, buses, attenuation, and an example forest soundscape |
| `Textures/` | 157 | Sky and cloud textures, volume textures, space maps, icons, weather masks, and effect textures |
| **Total** | **848** | **847 `.uasset` files and one `.umap`** |

The Blueprint tree contains 42 enum packages, 65 packages under `System/Editor_UI/`, 13 weather presets, 23 climate presets, six planet presets, and five runtime widgets. The DemoMap has 52 direct package references, including both main actors, a partly cloudy preset, landscape and wall materials, surface interaction and rain drip actors, and selected render and audio resources. The three demo materials are `Landscape_Example`, `Landscape_Example_Distant`, and `Wall_Example`. [Exact package paths, classes, and internal dependencies](ultra_dynamic_sky_packages.json)

All 2,131 direct internal hard and soft references in the registry resolve within the 848-package inventory. External references use the `/Engine`, `/Niagara`, and `/Script` mounts. Referenced modules include Engine, Landscape, Niagara, MetaSound, UMG, Water, and editor utility APIs. The registry identifies DemoMap's exact cloud texture dependency as `Textures/3D_Clouds/3D_Cells_64.uasset`. The host project descriptor also lists unrelated dependencies such as GameplayAbilities.

| Reflected Blueprint | Graphs | K2 nodes |
| --- | ---: | ---: |
| `Blueprints/Ultra_Dynamic_Sky.uasset` | 569 | 13,564 |
| `Blueprints/Ultra_Dynamic_Weather.uasset` | 376 | 7,220 |
| `Blueprints/Functions/UltraDynamicSky_Functions.uasset` | 19 | 124 |
| `Blueprints/Functions/UltraDynamicWeather_Functions.uasset` | 23 | 136 |

These graph counts include editor and nested graphs. K2 node counts exclude non-K2 annotations.

Focused reflection also inspected `Blueprints/Weather_Effects/Radial_Storm.uasset` (579 K2 nodes), `Weather_Override_Volume.uasset` (1,127), and the weather mask and player occlusion Blueprints listed below. For the precipitation material and Niagara paths, see the [particle and surface audit](ultra_dynamic_sky_precipitation.md).

### Editable property inventory

Native Unreal reflection records each declared property, its type and default, tooltip, clamp and slider metadata, edit flags, and category visibility. The inventory also contains the referenced struct schemas and enum choices. The separate Godot mapping records reviewed Inspector bindings and leaves unreviewed fields unmapped. That mapping is a review snapshot and does not automatically follow later root settings additions; its mapped-field count is not a current parity score. A conceptual binding alone does not establish matching visual behavior. [Machine-readable property inventory and mapping](ultra_dynamic_sky_properties.json)

| Source class | Declared properties | Instance-editable flags | Category-visible controls | Applicable top-level controls |
| --- | ---: | ---: | ---: | ---: |
| Ultra Dynamic Sky | 949 | 622 | 584 | 567 |
| Ultra Dynamic Weather | 607 | 398 | 384 | 383 |
| **Main actors combined** | **1,556** | **1,020** | **968** | **950** |

Declared counts include runtime state. Category visibility comes from Unreal's `FEditorCategoryUtils`, which hides 52 of the instance-editable fields. Applicable counts additionally exclude nine Voxel, five multiplayer/server, and four cloud-painting controls. Conditional UI rules can reduce the fields visible for a selected mode. The two classes inherit another 232 Actor properties, counted separately. The inventory records 26 unique referenced struct definitions with 664 fields, including 514 fields of Unreal's `PostProcessSettings`, and 45 referenced enums. Arrays, maps, and struct instances are counted once in the top-level totals. Their nested schemas may also be referenced by internal state.

## Runtime ownership and update flow

### Sky

`Blueprints/Ultra_Dynamic_Sky.uasset` owns time, celestial orientation, scene lighting, the sky material, fog, and related effects. Construction, BeginPlay, and runtime reconfiguration share the startup path. Startup initializes the renderer-facing components and performs a first static and active update. Static settings cover configuration that rarely changes during play. Active updates apply time- and weather-dependent values.

Graph links show that construction passes through location, time string, and editor tick setup before `Startup Sky`. The runtime path checks authority and initial replication state. Sky tick records delta, dispatches two tick lanes that can alternate, and updates cloud movement separately.

Game mode spreads expensive calculations over time. The sky stores old and new cached property values and blends between them on active updates. It adjusts the cache interval as the rate of time or weather change increases. Cloud movement has a separate cache for wind-driven position offsets and applies the interpolated offset on tick. The volumetric cloud material, cloud fog, and cloud shadows share cloud parameters.

| Subsystem | Observed Unreal design and evidence |
| --- | --- |
| Clock and calendar | A day clock drives the default sun and moon paths. Animation and system time can drive it, with date rollover at midnight. Calendar/date/DST assets live under `Blueprints/System/`. The astronomical option uses location, time, and date for approximate sun, moon, and star orientation. Manual orientation and lunar phase are separate controls. Clock and sunrise/sunset dispatchers support gameplay. |
| Atmosphere and sky composition | `Materials/Ultra_Dynamic_Sky_Mat.uasset` references base color and directional scattering, celestial disks, stars, wisps, cloud layers, aurora, and the space composite. Sky Atmosphere uses Unreal's scattering system. Simplified Color samples sun and moon lookup volumes with editable color controls. |
| Direct and ambient lighting | Dedicated sun and moon directional lights can update independently of their visual sky positions. The skylight can capture the sky or use a cubemap, including a grayscale cubemap tinted by calculated ambient fog colors. Exposure, interior response, light shafts, lens flare, and shadow controls are separate concerns. |
| Cloud representations | The default is volumetric. Other source modes include moving 2D clouds, static clouds, volumetric aurora, space, and a clear option. Cloud height, coverage, motion, extra layers, and painted coverage/profile resources are authored separately. `Materials/Volumetric_Clouds.uasset` references a coarse density function and a detailed extinction function under `Materials/Material_Functions/`. |
| Cloud shadows and fog | `Materials/Cloud_Shadows_and_Caustics.uasset` and light-function instances use shared volumetric density for 3D clouds or a separate approximation for 2D clouds. Fog couples atmospheric color and density with cloud, fog, and dust inputs. `Global_Volumetric_Fog`, `Cloud_Fog_PostProcess`, and related materials handle local noise, cloud interiors, and ground or water masking. |
| Night and space | Tiled and astronomical star options, an illuminated moon, aurora, planets, rings, and nebulae are distinct content paths. `Materials/Space/`, `Textures/Space/`, and `Blueprints/System/Planet_Presets/` support the space layer. |
| Quality and compatibility | Project Mode selects real-time caching, higher-fidelity per-frame updates for cinematics, or stereo-oriented VR behavior. Feature Level selects mobile-compatible fallback modes. Path tracing uses its own sky and fog accommodations. |
| Modifiers and persistence | `Blueprints/System/UDS_Modifier.uasset` and related state/interface assets apply layered color, float, and post-process overrides. A modifier can fade, take a manual weight, or follow a time range. The base values are saved separately for interpolation. `UDS_and_UDW_State.uasset` represents combined sky and weather save state. |

### Height fog calibration

The placed UDS 9.7 DemoMap uses **Current Fog Density** to combine a `0.0055` base, `0.002 × overcast`, and the greater of `0.1 × normalized Fog⁴` and `0.5 × normalized Dust⁴`. Day and night density multipliers are both `1.0`. The **Fog Height Falloff** and **Fog Start Distance** graphs set separate component properties. UE 5.8's `SceneCore.cpp` divides density by `1000` in centimeter units. Converting to meters and accounting for both base-2 factors in `HeightFogCommon.ush` gives Godot's horizontal natural-exponential coefficient `0.1 × ln(2)² × UE component density`. The graph evaluation reproduces the existing Rain and Storm runtime component readings.

| UDS preset | UE component density | UE height falloff | UE start distance | Saved Godot Fog Density (m⁻¹) |
| --- | ---: | ---: | ---: | ---: |
| Clear Skies | 0.005500000 | 0.06500 | 73.58 m | 0.000264249 |
| Partly Cloudy | 0.005510000 | 0.06000 | 73.48 m | 0.000264730 |
| Rain Light | 0.006883958 | 0.04900 | 61.00 m | 0.000330742 |
| Overcast | 0.007550625 | 0.04475 | 55.66 m | 0.000362772 |
| Rain | 0.008310000 | 0.03950 | 50.09 m | 0.000399256 |
| Snow | 0.013750000 | 0.03250 | 22.75 m | 0.000660623 |
| Rain Thunderstorm | 0.025350625 | 0.02725 | 3.32 m | 0.001217978 |
| Snow Blizzard | 0.107500000 | 0.01500 | 0 m | 0.005164870 |
| Sand Dust Storm | 0.505500000 | 0.03000 | 0 m | 0.024286900 |

These are preset endpoints for horizontal attenuation. The custom Forward+ engine also integrates altitude-dependent extinction from the authored start distance. The Godot presets store vertical falloff in inverse meters as `0.1 × ln(2) × UE height falloff` and store start distance in meters. The stock rig enables **Drive Height Fog From Weather** so both values interpolate with density during transitions and local weather mixing. At the calibrated Blizzard coefficient, Forward+ distance fog alone produced a hard ridge edge against the visible sky. The saved Storm and Blizzard paths blend low sky angles toward the same resolved fog color, with stronger native sky fog influence in Blizzard. The tested Blizzard setting retains more near-rock detail and a faintly visible lake. The separate Fog Amount channel supplies both rainbow moisture and the weather weight for sky-to-fog continuity. [Height fog authoring](dynamic_sky.md#height-fog) · [Godot authoring guide](dynamic_sky.md#author-effects-on-the-main-rig) · [Saved presets](../addons/dynamic_sky/presets/)

### Weather

`Blueprints/Ultra_Dynamic_Weather.uasset` finds the sky actor and controls the sky's weather-driven inputs when both are present. Startup initializes weather objects, starts configured random variation, and applies the first update. The global state combines the current preset, transitions, random weather, and optional material accumulation. The local state then layers location-dependent effects such as override volumes, radial storms, and above-cloud adjustments. Changes that cross a threshold trigger the relevant particle, material, and audio updates.

The primary graphs show the call direction between the actors. Sky startup resolves Weather and calls its initialization. Sky dispatches Weather's runtime tick through an interface. Weather builds global state before local state, then runs custom behavior. Sky pulls the resolved cloud coverage, fog, dust, wind, rain, and snow inputs for its own update. Weather's active path updates gusts and changed properties before writing material parameters and processing lightning.

| Subsystem | Observed Unreal design and evidence |
| --- | --- |
| Presets and climate | `Blueprints/Weather_Effects/System/UDS_Weather_Settings.uasset` and `UDW_WeatherState_Structure.uasset` define weather data. The 13 presets span clear, cloud, fog, rain, thunderstorm, dust, and snow variants. Climate presets and `Random_Weather_Variation.uasset` govern seasonal probabilities. Variation uses intervals or the sky clock for hourly and daily changes. Weather can also change explicitly or be keyed for cinematics. |
| Spatial weather | `Weather_Override_Volume` blends weather in a spline-authored region using a transition band and a priority. `Radial_Storm` adds a movable circular blend and can draw its own cloud and lightning effects with the volumetric sky. `Weather_Mask_Brush` and `Weather_Mask_Projection_Box` affect material weather masks. Local weather and material masking have separate roles. |
| Particle exposure and collision | Rain, snow, dust, and debris spawn in a bounded region around the viewer. Niagara supports simple collision, distance field collision, and collision-free spawning. CPU/GPU collision emitters populate path data used by presentation emitters. Rain also has surface splashes. A kill sphere supports moving interiors. Player occlusion, occlusion volumes, and portals supply additional scene queries for exposure and audio. |
| Lightning and wind | A visible strike effect and concealed cloud lightning have separate paths. `UDW_Lightning_Spawn_Manager.uasset` and its strikable-actor interface support strike selection. Weather controls particle drift and can drive cloud motion, foliage deformation, rigid-body wind forces, and camera shake. |
| Material response | `UDW_Material_State_Manager.uasset` either evolves wetness, dust, and snow over time or takes them from weather state. Shared material parameters feed surfaces, foliage, landscapes, glass droplets, and water ripples. Dynamic landscape interaction adds tracks and ripples from moving actors. Other saved effects cover drip splines, snow piles, vehicle windows, and puddle fluid volumes. |
| Audio | MetaSounds handle rain, wind, snow, dust, and thunder layers. Weather updates levels and occlusion periodically. Non-spatial and directional channels meet in a weather bus and mixer, which use occlusion from Sky. Environmental audio has its own time/weather-aware asset type and forest example. |
| Temperature and actor response | `UDW_Temperature_Manager.uasset` and `Temperature_Volume.uasset` derive temperature from weather, time, and local overrides. `Actor_Weather_Status.uasset` tracks exposure and can drive actor materials and signals. Water-level interfaces coordinate underwater effects. Standalone Niagara examples cover freezing breath and drips from rigid or skeletal meshes. |

### Radial storm, surface masks, and shelter

`Blueprints/Weather_Effects/Radial_Storm.uasset` defaults to `Rain_Thunderstorm`, priority 1, a 4 km outer radius, and an inner radius fraction of 0.4. In `Get Alpha with Location`, horizontal distance blends the weather from full weight inside 2.08 km to zero at 4 km with a 1.4 power falloff. Runtime spawn, fade, linear travel, and optional destruction move the footprint over time. The weather override remains usable in 2D and Static modes. In Volumetric mode, `Local State Update - Apply Radial Storm to Weather` preserves the inherited cloud coverage scalar. `Lerp Between Weather States` eases rain, snow, and thunder based on the change in precipitation and the lower of the two cloud coverage values. At 3.04 km into the default storm from clear, the physical weight is 0.378929 and the resolved normalized rain is 0.000425. `Draw to Cloud Paint Target` draws an independent world-space coverage footprint that can add or remove clouds. `Draw to WOV Target` separately writes the local surface state with a full-weight radius of 1.6 km at the default settings.

`Particles/Radial_Storm.uasset` supplies distant fog sprites, obscured lightning, and shadow modulation. Source class defaults include 75 fog sprites, a 20 km effect fade distance, and a 25 km thunder range. Distant visual effects are enabled only in Volumetric mode. The saved `Maps/DemoMap.umap` has no placed Radial Storm, weather override volume, or weather-mask actor. The existing roof test verifies particle shelter in a controlled fixture.

`Blueprints/Weather_Effects/Components/Weather_Mask_Brush_Component.uasset` projects a rotated or scaled shape or painted texture down the vertical axis. `Weather_Mask_Projection_Box_Component.uasset` captures the shapes of roof or other geometry from above, with independent snow and wetness blur slopes and optional actor exclusions. The Weather actor defaults to a camera-centered 500 m by 500 m mask target at 1,000² pixels, updating every 0.05 s. `Materials/Material_Functions/Sample_Weather_Mask_Brushes.uasset` reads wetness suppression from R and snow/dust suppression from G. A separate height target limits masking vertically, with a 0.5 m fade. Materials can opt out of each mask independently.

`Blueprints/System/UDS_PlayerOcclusion.uasset` supplies interior lighting and audio with camera-centered collision queries. Sky class defaults include a 45 m maximum trace distance, 12 horizontal and four vertical trace steps, and a 0.55 s update period. `Blueprints/Occlusion/UDS_Occlusion_Volume.uasset` can override interior response and optionally block particles. `UDS_Occlusion_Portal.uasset` can reduce occlusion through a clear opening. `Particles/WeatherOcclusionVolumeSystem.uasset` separately builds a distance-field cache used by wind fog. Its default area is 60 m, with 40 m trace distance and a 2 s sampling period.

## Editor authoring and public surfaces

| Entry point | Role |
| --- | --- |
| `Blueprints/Configuration_Manager.uasset` and `Blueprints/Tools/Configuration_Buttons.uasset` | Save, apply, and switch reusable configurations. The shared configuration assets and Sky/Weather-specific definitions live in `Blueprints/System/`. |
| `Blueprints/Volumetric_Cloud_Painter.uasset` | Paint world-space cloud coverage. Supporting data, brushes, and capture assets live under `Blueprints/System/` and `Blueprints/System/Editor_UI/Cloud_Painter/`. |
| `Blueprints/Tools/Cloud_Profile_Authoring_Tool.uasset` and `Static_Clouds_Authoring_Tool.uasset` | Author a cloud profile lookup or capture clouds into a static texture. |
| `Blueprints/Tools/Sky_Modifier_Editor.uasset` and `Weather_Mask_Brush_Painter.uasset` | Author sky overrides and draw custom weather masks. |
| `Blueprints/README.uasset`, `Mini_Controls.uasset`, and `Blueprints/System/Editor_UI/` | In-editor documentation, level toolbar, quick editing, viewport labels and handles, and editor tick/Sequencer support. |
| `Blueprints/Functions/`, `Utilities/`, `Widgets/`, and `Sound/` | Shared queries and control functions, a day/night light toggle, client helper, clocks, on-screen controls, weather and temperature display, and time-aware sound support. |

## Godot coverage and remaining gaps

[Cloud and color mode audit](ultra_dynamic_sky_cloud_modes.md) · [Rain, snow, dust, wind, and mist audit](ultra_dynamic_sky_precipitation.md)

| Reference behavior | Saved Godot behavior | Remaining comparison or scope |
| --- | --- | --- |
| Time, celestial visuals, and lighting | Solar clock, optional astronomical sun and moon, lunar phase, sidereal stars, synchronized directional lights, immediate system-time synchronization, and civil-hour/date/sunrise/sunset/midnight events. [Sky scene](../addons/dynamic_sky/dynamic_sky.tscn) · [Clock](../addons/dynamic_sky/weather/clock/sky_clock.gd) | Source interior-lighting policies, occlusion volumes, and portals remain open. |
| Cloud and color modes | Volumetric, 2D Dynamic, Static, and Space, with separate Atmosphere and Simplified Color. Forward+ sunlight projection uses the local engine. The comparison Snow profile enables daylight atmosphere light and material emission for its visible volumetric clouds. [Cloud and color mode audit](ultra_dynamic_sky_cloud_modes.md) | Cloud profile controls, independently authored additional volumetric layers, the wet-weather horizon transition, and Snow receiver lighting remain open. Cloud painting is excluded by request. |
| Global and local weather | Thirteen weather presets, interruptible transitions, seasonal climate scheduling, and prioritized box, sphere, spline, and Radial Storm regions. Radial Storms travel and fade, add or remove local volumetric cloud coverage, and draw a depth-tested exterior precipitation shaft with localized flashes. The sky, shadow projector, and in-cloud fog share the coverage field. Compatible meshes resolve the separate radial coating field at fragment positions. The opt-in scheduler uses the source wait, route, fade, and seasonal defaults. Above-cloud observer weather follows the source's linear 10–65% volumetric layer ramp. [Weather controller](../addons/dynamic_sky/dynamic_sky.gd) · [Presets](../addons/dynamic_sky/presets/) · [Radial Storm](dynamic_sky.md#radial-storm) | Storm-specific ambient darkening, the lighting and material response at a storm edge, global weather-transition easing, and radial snow depth and track physics remain under comparison. |
| Precipitation and wind | Near/middle/far rain, collision spray, three-dimensional snowfall, dust grains and billows, runoff, stuck snow, moving near-ground mist, and optional wind debris. [Precipitation scene](../addons/dynamic_sky/precipitation/precipitation.tscn) · [Particle comparison](ultra_dynamic_sky_precipitation.md) | Rendered motion, shelter, and contacts were exercised in Forward+. Visual parity for motion, distant fade, and surface response is still open. |
| Automatic lightning and thunder | Rain dispatches sheet flashes and delayed thunder. Storm dispatches both sheet and full strikes. Full strikes have independent direct light, screen glow, and depth-tested Forward+ cloud rays. The saved rig exposes ray intensity and the ray envelope. Rendered comparisons cover 20:00 and 23:30, including opaque occlusion and above-cloud visibility checks. Radial Storm uses a separate, spatial 25 km thunder bed. [Lightning scene](../addons/dynamic_sky/lightning/lightning.tscn) · [Lightning settings](../addons/dynamic_sky/configuration/effects/lightning_settings.gd) · [Weather audio](../addons/dynamic_sky/audio/weather_audio.tscn) | The broad flash shape, calibrated nighttime exposure, and distant thunder mix remain under comparison. The source also supports an optional strikeable-actor interface. |
| Spatial weather audio | Opt-in 48-ray geometry sampling drives four world-oriented rain and wind beds, centered close rain, and a separate gust-driven wind whistle. Authored portal markers contribute sound through clear openings. Stereo tests exercise an offset doorway, listener orientation, door closure, underwater muffling, and whistle activation across wind strengths. [Audio authoring](dynamic_sky.md#runtime) · [Saved emitter scene](../addons/dynamic_sky/audio/cardinal_weather_beds.tscn) | Source rain layer recordings and one-shots, continuous per-direction filters, the full surround mix, and the broader source whistle spectrum remain open. |
| Surface weather | Weather-responsive materials accumulate water, snow, and dust over time. A shared soft shelter footprint lets terrain and pavers carry the same snow drift. The prototype grid uses a shared shader include and root-managed per-instance weather. Local track receivers displace authored mesh vertices and add packed snow and piled edges. [Surface material](../addons/dynamic_sky/surfaces/weather_surface.tres) · [Custom shader hook](../addons/dynamic_sky/surfaces/weather_layer.gdshaderinc) · [Snow tracks](dynamic_sky_snow_tracks.md) | The source uses a scrolling terrain-wide mask with parallax depth and separate contact particles. Godot currently uses bounded receiver fields and a subdivided mesh. Painted and geometry-projected material masks, snow pile and vehicle overlays remain open. The custom shader hook requires final view-space normals. |
| Shelter and temperature | Geometry-based particle shelter, physics probes for mist and audio, and temperature sampled from the day/night cycle and weather offset. Global water levels and saved Box/Sphere water regions suppress observer weather underwater, muffle audio, and wet the lens on emergence. [Precipitation scene](../addons/dynamic_sky/precipitation/precipitation.tscn) · [Weather controller](../addons/dynamic_sky/dynamic_sky.gd) · [Water Region](../addons/dynamic_sky/weather/exposure/water_region.tscn) | Source occlusion portals and volumes, interior temperature overrides, geometry-derived water capture, and actor exposure remain open. |
| Editor workflow and state | An editor plugin, the saved West Ridge Observatory demo, reusable root Configuration and typed effect settings, and explicit Resource capture and restore for the clock, renderer, global weather, and active transition. The local native editor exposes WorldEnvironment child properties with per-instance overrides and an editable-resource copy action. [Root authoring](dynamic_sky.md#author-effects-on-the-main-rig) · [Demo scene](../addons/dynamic_sky/demo/dynamic_sky_demo.tscn) | Rain and cloud-shadow settings plus material-default-aware cloud/color selectors are bound on the main root and reusable Configuration. Native shader authoring stays in the exposed Environment/Sky section; low-level snow-material and audio-player controls remain in saved component assets. Full source modifier/configuration parity remains open. |

## Reproduce the checks

In a scratch project with the source mounted at `/Game/UltraDynamicSky`, inspect class defaults and graph pins using the Unreal Python commandlet with `-run=pythonscript -nullrhi -unattended`. Use `BlueprintEditorLibrary` for K2 graphs and pins, `MaterialEditingLibrary` for material function expression inputs, and loaded `NiagaraNodeFunctionCall` objects for the embedded emitter stacks. The package inventory resolves each source path used above.

For rendered references, load `/Game/UltraDynamicSky/Maps/DemoMap` in offscreen Play in Editor with D3D12 and SM6. Use the resolved **Local Weather State** after the weather update to record actual values. The fixture used camera position `(320.25, 657.8, 245)` cm, pitch `+4.5°`, yaw `−110°`, and 960 × 540 captures. The reference map and companion audits distinguish class defaults, saved map settings, and temporary fixture overrides. [Cloud and color mode audit](ultra_dynamic_sky_cloud_modes.md) · [Precipitation and airborne effects audit](ultra_dynamic_sky_precipitation.md)
