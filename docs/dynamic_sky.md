# Dynamic Sky



Dynamic Sky is a reusable outdoor environment for Godot 4.8 Forward+. The rig owns atmosphere and volumetric clouds, sun and moon lighting, weather profiles and transitions, and camera-relative effects. It uses the sibling engine's Forward+ directional projector for world-anchored sunlight transmission through the cloud layer. [Rig scene](../addons/dynamic_sky/dynamic_sky.tscn) · [Unreal reference map](ultra_dynamic_sky_audit.md)



## Open the demo



Open the project with the [rebuilt editor](../../godot/bin/godot.windows.editor.x86_64.exe), choose **Project → Tools → Open Dynamic Sky Demo**, and press **F6**. Scrub the clock to compare daylight, twilight, and night. Switch between **Open terrace**, **Under shelter**, **Lakeshore**, **Sky survey**, and **Weather apron**. Hold **RMB** to look around, use **WASD** to fly, and use **Q/E** to descend or ascend. [Demo scene](../addons/dynamic_sky/demo/dynamic_sky_demo.tscn)



| Check | What to look for |

| --- | --- |

| **Rain** outside and under the roof | Fine, mostly vertical rain at near, middle, and far distances. The open terrace accumulates water and shows contact splashes. The sheltered foreground suppresses nearby drops and muffles audio. Rain produces distant sheet flashes and thunder automatically. |

| **Snow** and **Blizzard** from **Weather apron** | Irregular, velocity-aligned snow sprites follow cached world-space trajectories, with small lateral twirls and gradual surface coverage. Blizzard increases wind and emission. Optional snow contact enables short-lived impacts and strong-wind ground spindrift. Physics collision clips trajectories at roofs and terrain. |

| **Storm** from **Open terrace** or **Sky survey** | Stronger wind deflection and surface spray. Visible strikes and sheet flashes occur automatically at variable intervals. Thunder arrives after its sound travel time. **Trigger Lightning** requests a visible strike on demand. |

| **Sandstorm** | Suspended grains, saltating grit at the ground, and larger gust billows within moving mineral haze. Shelter suppresses the near grit. |

| **Lakeshore** during **Rain** | Small ripple impacts affect the lake surface. |



The demo contains saved 3D spruce, ground-cover, and terrain assets. Its 4096 × 4096 material maps are baked from original 1254 × 1254 ImageGen masters. The bake estimates surface relief and roughness from that artwork. Falling snow uses a separate original 887 × 1774 packed atlas, imported as 64 × 128 linear, lossless texture data. [ImageGen sources and PBR bake](dynamic_sky_imagegen.md)



## Cloud and color modes



Use **Sky survey** and **Partly Cloudy** to compare the cloud modes. Keep the camera and time fixed to see which paths respond to wind, then scrub the clock to compare lighting.



| Control | Mode | Behavior |

| --- | --- | --- |

| Cloud Mode | Volumetric | Ray-marches a world-space formation volume, fine erosion, light transmission, and distance haze. The shared cloud projector filters the Sun on the local Forward+ build. |

| Cloud Mode | 2D Dynamic | Moves a separate layered cloud texture across the dome with perspective distortion and directional shading. Its projector follows the lower sheet. |

| Cloud Mode | Static | Keeps the authored cloud silhouette fixed while the packed lighting channels follow the sun or moon. Its projector uses a stable ground footprint. |

| Cloud Mode | Space | Shows the celestial background and suspends terrestrial fog and precipitation. |

| Color Mode | Sky Atmosphere | Uses the physical scattering and transmittance tables. |

| Color Mode | Simplified Color | Uses separate art-directed sun and moon tables, editable tints, and the authored fog color. |



Save the modes on the rig's **Sky Material**. Runtime callers can use `set_cloud_mode()` and `set_color_mode()`. Color selection applies to the terrestrial sky modes. Volumetric quality offers a half-resolution **Balanced** pass and a denser full-resolution **High** pass. West Ridge uses High. [Source mode comparison](ultra_dynamic_sky_cloud_modes.md) · [Sky shader](../addons/dynamic_sky/rendering/dynamic_sky.gdshader)



## Add it to a level



Open a scene with a **Node3D** root and choose **Project → Tools → Add Dynamic Sky**. The command inserts the saved rig and supports editor undo. Use a single world environment and let the rig supply the level's main sun and moon lights. The command checks for an existing world environment or directional light before adding the rig. Save the level after adding it. [Editor plugin](../addons/dynamic_sky/plugin.gd)



| To change | Edit |

| --- | --- |

| Clock, latitude, date, or north | **DynamicSky → Clock**. **Day Length Seconds** at zero freezes time. Assign **Astronomy** to use a calendar, longitude, UTC offset, lunar phase, and sidereal stars. The empty setting uses the equinox-style arc and an opposing moon. |

| Starting conditions and automatic changes | **DynamicSky → Weather**. Assign a **Start Weather** resource. Assign **Climate** for weighted seasonal weather changes at real-time, hourly, or daily intervals. |

| Sky colors, cloud shape, aurora, or space | **WorldEnvironment → Environment → Sky → Sky Material → Shader Parameters**. Cloud shadows use the shared lower volume. |

| Light, fog, or temperature | **DynamicSky → Lighting** and **Temperature**. **Lightning Energy** controls the directional scene flash. |

| Lightning distance or impact | **LightningStrikes** sets strike distance, cloud altitude, timing, and the ground collision mask. |

| Precipitation or airborne mist | **Precipitation** owns the Rain and Snowfall scenes, impacts, and the shared camera-relative collision heightfield. **AirborneWeather** owns the Sandstorm Particles scene, drifting volumetric mist, and shelter probes. |

| Weather above clouds or beneath water | **Configuration → Exposure Settings**, or **DynamicSky → Weather → Exposure Settings** when Configuration is empty. Local water footprints use saved **WaterRegion** scenes. |

| Audio | **WeatherAudio** sets listener and occluder detection. The individual player scenes own mix, attenuation, and the open and low-pass clips. |



Duplicate a preset for level-specific values. Wind is horizontal velocity in meters per second along world X and Z. **Gustiness** sets its variation. **Lightning Rate** and **Sheet Lightning Rate** set the mean visible and obscured events per real minute, respectively. **Temperature Offset** shifts the air temperature from the clear day/night baseline. [Presets](../addons/dynamic_sky/presets) · [Weather fields](../addons/dynamic_sky/dynamic_sky_weather.gd)



### Expose internal nodes in the instance Inspector



The native `Node.inspector_exposed_nodes` property embeds selected descendant nodes in a scene root's Inspector. Open a reusable scene, select its root, and add a relative child path such as `WorldEnvironment` under **Node → Inspector → Exposed Nodes**. Save the reusable scene. When that scene is instanced in a level, selecting the instance root shows a collapsible **WorldEnvironment (WorldEnvironment)** section containing the child's native properties and resource editors. This is a generic engine feature; each reusable scene authors its own exposure list. [Node implementation](../../godot/scene/main/node.cpp) · [Native Inspector](../../godot/editor/inspector/editor_inspector.cpp)



Edits target the child directly and use the containing level's undo history. Saving the level stores ordinary instance property overrides. Intermediate ancestors are traversed without saving unrelated changes, and unexposed siblings remain outside this mechanism. Removing an exposure entry hides its controls while retaining existing overrides through a storage-only path list. Empty, missing, absolute, self, ancestor, and property-subname paths are ignored with configuration warnings; repeated invalid paths produce one warning per distinct path.



Resources retain normal Godot sharing rules. Use **Make Unique** when an Environment or another assigned resource needs independent values for one instance, or author the resource with **Local To Scene** enabled when every instance should receive its own copy. Changing a shared external resource still changes that shared resource. Native child properties remain ordinary per-instance overrides. Animation keying is disabled in the embedded child Inspector because the existing keying workflow targets the selected node; use the child's regular Inspector when authoring animation tracks.



The controller adopts a replacement assigned to the actual **WorldEnvironment → Environment**, including a different Sky or ShaderMaterial inside it, on the next normal update. A manual time or weather change also refreshes these references in the editor. Detached resources stop receiving the controller's updates; authored rendering flags and unrelated shader parameters on the replacement remain intact. This uses the existing update path and does not add continuous editor polling.



When **Configuration** supplies an Environment, assigning the configuration or changing that Environment reference explicitly applies it to the child. Later native child replacements take effect without being reverted by unrelated configuration edits. The configuration's Environment remains its startup assignment on reload; update that reference as well when it should become the reusable configured default. With Configuration empty, the saved native child assignment is the startup environment. [Configuration resource](../addons/dynamic_sky/configuration/dynamic_sky_configuration.gd) · [Resource binding](../addons/dynamic_sky/dynamic_sky.gd)



The rebuilt feature is installed in the [root project editor](../../Godot_RPG.exe) and the normal editor/console build outputs in `godot/bin`. The separate [exposed-nodes validation editor](../../godot/bin/godot.windows.editor.x86_64.exposed_nodes.exe) contains the same build, compiled with `tests=yes extra_suffix=exposed_nodes`. Dynamic Sky exposes `WorldEnvironment` by default. Native PackedScene checks passed 52 assertions, including a rerun from the installed root executable, and independent physical scene/resource checks passed 38 assertions. GUI verification of the embedded editing workflow remains pending after Computer Use was interrupted. [Engine references](godot_conventions.md#engine-references) · [Serialization tests](../../godot/tests/scene/test_packed_scene.cpp)



## Local weather and materials



Instance **WeatherZone** and assign a weather resource. Use a box, sphere, or closed `Path3D` with vertical bounds. **Falloff** blends weather outside the region. Higher priorities apply later in overlaps. The active camera samples the local result for the sky and observer effects. Weather-responsive meshes sample the result at their own geometry origin. [Weather Zone](../addons/dynamic_sky/weather/weather_zone.tscn)



**Exposure Settings** filters that camera result after local weather zones. In Volumetric mode, suppression begins at 10% of the cloud layer's thickness and reaches its full multipliers at 65%. Layer base and thickness come from the sky material in kilometers relative to the rig. The default full-height result removes rain, snow, dust, weather fog, and automatic thunder events while retaining half the observer wind. Static, Clear, and Dynamic 2D bypass this height rule. Global weather, physical wind queries, cloud advection, and surface accumulation continue from the unfiltered state. [Exposure settings](../addons/dynamic_sky/weather/exposure/exposure_settings.gd) · [Observer filter](../addons/dynamic_sky/weather/exposure/weather_exposure.gd)



Enable **Global Water Enabled** and set **Global Water Level** for a constant absolute world Y surface. For a bounded lake, instance **WaterRegion** and assign its Box or Sphere footprint. Its origin sets the horizontal surface height; rotation around Y and authored scale affect the footprint. The highest enabled surface in the same World3D wins. A camera exactly on the surface is above water, and any point below the surface inside its horizontal footprint is submerged. The region's vertical size is ignored. West Ridge saves a Box footprint matching its lake. Water geometry is not inferred or captured automatically. [Water Region scene](../addons/dynamic_sky/weather/exposure/water_region.tscn) · [Region query](../addons/dynamic_sky/weather/exposure/water_region.gd)



Submersion immediately hides existing precipitation and airborne debris, suppresses weather fog and new automatic thunder, and retains wind. The native environment's volumetric fog is suspended and restored on exit. Underwater audio uses the muffled route, including thunder queued before entry. By default the lens clears underwater and wets on emergence after one second of runtime; startup teleports and switching to a different camera do not create an emergence event. The settings resource owns these screen and audio switches. The cloud-height rule and water mask affect observer presentation without changing the weather transition or each surface's accumulation.



Assign the weather material to a mesh and add **DynamicSkySurface** beneath it. **Exposure** controls how much rain, snow, and dust reach that mesh. Use a low value for sheltered surfaces. Water builds up in rain and dries with temperature. Snow collects on upward-facing surfaces and melts faster in warmer air or rain. Rain washes off deposited dust. The material uses **R** for ambient occlusion, **G** for roughness, and **B** for metallic in its optional ORM input. [Weather surface script](../addons/dynamic_sky/surfaces/weather_surface.gd) · [Saved material](../addons/dynamic_sky/surfaces/weather_surface.tres)



For a surface that crosses a shelter edge, **Shelter Bounds** stores the world X/Z center and local half extents. **Shelter Yaw Degrees** orients the footprint. Use matching values on adjoining materials to carry the irregular drift across the seam. The demo's outdoor terrain and pavers share the deposition curve and the fine 1.6 m snow projection. Terrain also blends a broader snow texture scale at distance and retains broad bedrock relief beneath the coating. The material uses the neutral snow artwork, slope retention, accumulated coverage, and shelter exposure to calculate its result. [Shelter mask shader](../addons/dynamic_sky/surfaces/surface_shelter.gdshaderinc) · [Snow deposition](../addons/dynamic_sky/surfaces/snow_deposition.gdshaderinc)



The terrain material reads **R** as meadow suitability, **G** as worn trail, **B** as drainage, and **A** as forest cover from the saved mesh's vertex colors. Slope and height blend exposed rock, scree, soil, and meadow. **Rock Slope Degrees** controls the transition to bedrock. **Bedrock Height Range** adds exposed alpine ground between 180 and 420 m by default, while **Natural Snowline** spans 420–580 m on the current mountain geometry. Material maps and their physical scales belong to the terrain's saved ShaderMaterial. [Terrain shader](../addons/dynamic_sky/demo/landscape/terrain.gdshader) · [Saved demo](../addons/dynamic_sky/demo/dynamic_sky_demo.tscn)



The shared sampler blends three randomly offset and rotated texture cells for each triplanar projection. Albedo, normal, and ORM use the same cell transforms and weights. Explicit texture gradients keep mip selection independent of cell boundaries, and tangent normals rotate back into the projection basis. Fine surface detail blends with a separate 32 m geological normal and ORM bake, so mountain shading retains relief at distance. Rain darkens the substrate and lowers roughness, with smoother accumulation in suitable drainage and trail patches. Dust adds a matte coating. These adjustments use each mesh's existing weather state and shelter mask. [Shared PBR sampler](../addons/dynamic_sky/surfaces/material_sampling.gdshaderinc) · [Geological bake](../addons/dynamic_sky/demo/materials/bake_rock_macro.py)



The saved boulder material uses the reusable weather shader's optional world triplanar projection and the same stochastic PBR sampler. Its fine and broad normal strengths and scales can be tuned independently of the terrain. These are shading controls over the authored mesh geometry. [Boulder material](../addons/dynamic_sky/demo/materials/alpine_boulder.tres) · [Weather shader](../addons/dynamic_sky/surfaces/weather_surface.gdshader)



The terrain workflow follows the slope layering, texture variation, cell bombing, and distance blending described in Unreal Sensei's landscape material reference. Sharing biome masks between the surface and vegetation follows Epic's Open World Tools guidance. The saved material maps use the original generated masters listed in the artwork document. [Unreal Sensei landscape material](https://www.unrealsensei.com/asset/ue5landscape) · [Epic Open World Tools](https://dev.epicgames.com/documentation/unreal-engine/open-world-tools-tips-in-unreal-engine) · [Artwork provenance](dynamic_sky_imagegen.md)



**RigidBodyWind** and **FoliageWind** are optional mesh or physics receivers. They sample local wind from the same world and have independent authoring controls. [Wind scenes](../addons/dynamic_sky/weather/wind)



Enable **WindDebris** for sparse three-dimensional fragments in strong wind. The shipped rig keeps it optional. **RainRunoff** follows an editable eave path and uses cached static contacts for drips and floor impacts. [Wind Debris scene](../addons/dynamic_sky/weather/wind_debris/wind_debris.tscn) · [Rain Runoff scene](../addons/dynamic_sky/precipitation/runoff/rain_runoff.tscn)



## Runtime



Call `set_weather(profile)` for an immediate change or `set_weather(profile, 3.0)` to blend over three real seconds. A request during a blend starts from the values currently in effect. The rig emits `weather_transition_finished(profile)` after an immediate change or completed blend. `get_weather_state()` returns the global snapshot. Use `get_weather_at(position)`, `get_temperature_at(position)`, and `get_wind_at(position)` for location-specific conditions. [Runtime controller](../addons/dynamic_sky/dynamic_sky.gd)



Set `time_of_day` to jump to an hour. `trigger_lightning()` requests a distant visible strike. `trigger_lightning_at(position)` requests a known ground endpoint. A first return stroke or an obscured sheet flash emits `lightning_struck(position, intensity)` and queues delayed spatial thunder. [Lightning scene](../addons/dynamic_sky/lightning/lightning.tscn) · [Weather Audio](../addons/dynamic_sky/audio/weather_audio.tscn)



`capture_state()` returns an independent resource for explicit saves with Godot's `ResourceSaver`. `restore_state(snapshot)` restores the clock, cloud and color modes, wind phase, global weather, and the original timing of a transition already underway. The running scene supplies its authored climate, local zones, and per-mesh surface state. [Snapshot fields](../addons/dynamic_sky/weather/weather_snapshot.gd)



## Rendering and collision



The saved **Snowfall → Settings** resource owns the falling-snow spawn volume, physical sprite scale, trajectory cache, and rates. Stock settings use a camera-biased horizontal disc with 20 m radius and 6 m height, a 1 cm sprite scale randomized from 1 to 2.4 times that size, 2000 cached paths, and a maximum path lifetime of 3 seconds. Full-intensity emission is 20,000 particles per second multiplied by `snow^1.5`; the Snow preset's 0.6 intensity gives about 9295 particles per second before camera-motion compensation. Paths are traced backward against the incoming direction to reject covered spawn points, then forward to clip their endpoint and lifetime. Snow's cached physics rays are independent of the rain collision heightfield. [Snow scene](../addons/dynamic_sky/precipitation/snow/snowfall.tscn) · [Saved settings](../addons/dynamic_sky/precipitation/snow/snow_settings.tres) · [Path cache](../addons/dynamic_sky/precipitation/snow/snow_path_cache.gd)



The air-snow material follows the source packed-atlas path: green stores the sharp irregular silhouette, blue stores its defocused profile, and each particle chooses one of four cells. A source-style world-normal tilt, alpha distribution, velocity stretch, scene-color contribution, depth fade, and manual depth rejection replace the earlier geometric stars and analytic soft blobs. Camera DOF parameters default to zero and can be authored on the saved material. The artwork is newly generated, so the cells are not pixel-identical to the Unreal sheet. Godot vertex lighting also differs from Unreal's filtered translucent-lighting volume. The current demo uses MSAA with TAA disabled; a post-temporal transparency pass would be needed to preserve the source's history exclusion if TAA or motion blur is enabled later. [Draw shader](../addons/dynamic_sky/precipitation/snow/snow_particle_draw.gdshader) · [Process shader](../addons/dynamic_sky/precipitation/snow/snow_particle_process.gdshader) · [Artwork provenance](dynamic_sky_imagegen.md#packed-air-snow-atlas)



The Volumetric sky and shadow pass share world-space density. Dynamic 2D projects its lower advected sheet, and Static uses a separate stable footprint. The local Forward+ build filters direct sunlight through those textures. Other builds use global cloud attenuation. The precipitation heightfield uses the highest opaque surface per horizontal cell on its visual mask. The audio and mist shelter probes use physics collision layers. Give a roof both visible opaque geometry and a collider to cover these paths. [Cloud shadow component](../addons/dynamic_sky/rendering/cloud_shadows/cloud_shadows.tscn) · [Airborne Weather](../addons/dynamic_sky/weather/airborne/airborne_weather.tscn) · [Reference particle paths](ultra_dynamic_sky_precipitation.md)
