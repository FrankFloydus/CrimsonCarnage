# UDW DemoMap comparison

Open **UDW DemoMap** and press **F6**. The saved comparison starts at **09:36** in **Blizzard**. Press **Tab** to show the view, weather, and clock controls, then select **Partly Cloudy** to reproduce the source map’s starting condition. Hold **RMB** to look around, use **WASD** to fly, and use **Q/E** to change height. [DemoMap scene](udw_demo_map.tscn) · [Dynamic Sky rig](../../dynamic_sky.tscn)

The layout is based on the local Ultra Dynamic Sky 9.7 `DemoMap` reflected in Unreal 5.8.4. A source point in centimeters maps to Godot meters as `(UE_Y, UE_Z, -UE_X) × 0.01`. The source ground spans 241.92 m on each horizontal axis and contains 189 × 189 quads at 1.28 m spacing. All 36,100 source landscape samples are flat at elevation zero. The editable Godot mesh and collider use that ground footprint. A 6.4 × 6.4 m inset adds vertices at 2.5 cm spacing for the orbiting sphere’s snow track. The Landscape uses the near material, with the source's distant LOD material recorded on the Terrain node.

| Source object | Godot node | Measured size or state |
| --- | --- | --- |
| Cube | `Props/Cube` | 2 m edge, matte gray material |
| Sphere | `Props/Sphere` | 2.121689 m diameter, weather-responsive wall material |
| Sphere2 | `Props/Sphere2` | 0.4 m diameter, matte gray material |
| Rain drip spline | `RainDripSpline` | Closed four-point path about 6.6062 m long, 100 drops/s/m at full rain plus 1 drop/s/m at full sphere wetness, 30 m spawn cull |
| Player Start | `PlayerStart` | Saved source spawn marker |

`ReferenceViews/DefaultCapture` matches the fixed Unreal comparison capture. Its vertical FOV is 73.7398°, which gives 106.2602° horizontally at 16:9. The source capture logs a nominal 90° horizontal FOV. The effective lens was checked against the cube's projected corners. `ReferenceViews/SunsetCapture` stores the second audited heading.

The comparison uses **4× MSAA** for geometry silhouettes. Set **Comparison MSAA** on the scene root to **Disabled** to use the viewport's existing setting. Leaving the comparison restores the previous viewport setting.

The comparison's [Environment](comparison_environment.tres) uses five SDFGI cascades at the rig's default 0.20 m near cell size. The additional cascade keeps the far ground within the indirect-light field and reduces the dark horizon band in daylight Blizzard. Edit it under **DynamicSky → WorldEnvironment**. The additional cascade used about 99 MiB in the 960 × 540 Forward+ comparison on an RTX 4090.

The small sphere starts at its saved editor position. During play it follows the source level script's 2 m radius and 85° per second orbit at a fixed height of 0.16 m. Disable **Animate Small Sphere** to inspect the authored pose. Capture scripts can call `select_view(NodePath("ReferenceViews/DefaultCapture"))` and `set_small_sphere_orbit_time(seconds)` on the scene root. Set `animate_small_sphere` to false to hold a chosen phase.

Once **Snow** or **Blizzard** has accumulated, watch a full lap to see the sphere press a continuous track into the snow. **Terrain → SnowTrackReceiver** owns the local field and the 14 cm uncompressed depth. The comparison ground material uses the compressed depth and **Track Cavity Half Width** to estimate how much sky light reaches the groove. The surrounding snow keeps its original lighting. Movement and contact queries use the flat substrate collider. The large sphere’s wall material uses its upward-facing coverage mask and finer triplanar samples of the original snowpack color, normal, and roughness maps. The powder detail is strongest along the transition from the cap to the exposed sphere. [Track authoring](../../../../docs/dynamic_sky_snow_tracks.md) · [Landscape material](materials/landscape_example.tres) · [Wall material](materials/wall_example.tres)

**Light Snow** shows a patchy coat at its authored .50 coverage. The landscape uses an original 3 m scatter field for the powder edges and a broader 500 m variation field for local accumulation. Snow rises where that accumulation supports it and reaches 14 cm at full cover near the camera. Track compression stays within the local layer as it builds and thaws. The dense track inset and the surrounding landscape use the same coarse edge heights through the 42–60 m displacement fade. [Landscape material](materials/landscape_example.tres)

The rain spline uses narrow, scene-lit droplets and brief crown splashes. The large sphere’s material wetness sustains a few residual drops after rain ends. The path, emission rates and collision settings are editable on **RainDripSpline**. [Drip scene](rain_drip_spline.tscn)

The comparison landscape’s **Source Rain** shader group controls the wet film and shallow pools. Accumulated wetness changes the tile roughness across the floor, including in sheltered areas. The original ground variation places compact pools on the level floor. An original 2.5 m normal atlas runs at 30 fps within those pools and combines rain and wind gradients. Collision-driven splashes and surface contacts use the precipitation system. [Landscape material](materials/landscape_example.tres) · [Pool shader](materials/comparison_rain.gdshaderinc)

## Comparison weather and clock

The weather menu uses 13 editable resources in [weather](weather/). Unreal 5.8.4 reflected the endpoint values from the corresponding UDS 9.7 assets under `/Game/UltraDynamicSky/Blueprints/Weather_Effects/Weather_Presets`. Cloud coverage, fog amount, rain, and snow use the source 0–10 values divided by ten. Physical height fog uses the audited DemoMap density, falloff, and start distance conversion. [Source audit](../../../../docs/ultra_dynamic_sky_audit.md)

| Comparison preset | Source asset | Cloud / fog | Rain / snow / dust | Material wet / snow / dust |
| --- | --- | --- | --- | --- |
| Clear | `Clear_Skies` | 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| Partly Cloudy | `Partly_Cloudy` | .38 / .10 | 0 / 0 / 0 | 0 / 0 / 0 |
| Cloudy | `Cloudy` | .50 / .10 | 0 / 0 / 0 | 0 / 0 / 0 |
| Overcast | `Overcast` | .75 / .15 | 0 / 0 / 0 | 0 / 0 / 0 |
| Foggy | `Foggy` | 0 / 1 | 0 / 0 / 0 | .55 / 0 / 0 |
| Light Rain | `Rain_Light` | .60 / .15 | .30 / 0 / 0 | .75 / 0 / 0 |
| Rain | `Rain` | .75 / .30 | .70 / 0 / 0 | 1 / 0 / 0 |
| Storm | `Rain_Thunderstorm` | .80 / .65 | 1 / 0 / 0 | 1 / 0 / 0 |
| Light Snow | `Snow_Light` | .60 / .30 | 0 / .30 / 0 | 0 / .50 / 0 |
| Snow | `Snow` | .85 / .50 | 0 / .60 / 0 | 0 / 1 / 0 |
| Blizzard | `Snow_Blizzard` | 1 / 1 | 0 / 1 / 0 | 0 / 1 / 0 |
| Calm Dust | `Sand_Dust_Calm` | 0 / .10 | 0 / 0 / 1 | 0 / 0 / 1 |
| Sandstorm | `Sand_Dust_Storm` | 0 / .10 | 0 / 0 / 1 | 0 / 0 / 1 |

The table records the source asset inputs. The two Dust profiles retain Godot’s previously authored wind, .97 airborne dust, and optical settings during Dust validation. Other wind speeds use `15 × (source intensity / 10)²` m/s toward Godot +Z, which corresponds to the placed Unreal weather actor’s 180° direction. Each resource records raw source wind and thunder values in its metadata. The comparison retains the Godot lightning scheduler’s authored event rates.

The `source_material_state` metadata holds the reference wetness, snow, and dust as a `Vector3`. The comparison applies these values at startup and for explicit settled captures. This lets a **Foggy** reference show wet materials while rain remains at zero, or a **Light Snow** reference show the asset's .50 snow coverage. The cube and small sphere use the source plain material assignment.

Timed preview changes simulate the source buildup and melt on the Landscape and large Sphere. From a dry start, **Snow** reaches full coverage in 100 seconds and **Blizzard** reaches it in 60 seconds at their settled intensities. A full layer melts over 90 seconds after snowfall stops. Rain wets the surface at its own intensity-scaled rate, and clear daylight dries a wet surface in 90 seconds. The **Source Snow and Wetness** group on the comparison root exposes these rates and the meltwater contribution. Disable **Simulate Source Material Timing** to ease between the authored material endpoints.

Use `set_comparison_weather(profile, 0.0)` on the comparison root for an instant reference capture. A positive duration blends the atmosphere and starts the timed material response from the current surface. Set **Weather Transition Seconds** to zero to select instant references from the weather menu.

The comparison uses the source’s Volumetric Clouds and Sky Atmosphere selections, the 09:36 source clock, and the comparison solar arc at latitude 30° and north rotation 0°. The Unreal reference started in Partly Cloudy and used capture-based sky lighting with real sun, moon, and stars simulation disabled.

The source map’s unbound post-process volume uses a cosine-fourth vignette at intensity .50. The editable **ReferenceVignette → LensFalloff** material approximates that falloff after Godot tone mapping. It applies over the weather image, while the controls draw above it. The reference also uses separate contrast, bloom, and histogram exposure settings.

**BlizzardLightingCalibration** uses the live cloud, fog, and snow values and the Sun and Moon elevations. It applies the source Sun intensity ratio of .06125 and its 5° angular diameter in daylight, then blends exposure and fog radiance through twilight and into moonlight. Full Blizzard fades the direct shadows and reduces direct moonlight, which is mostly scattered by the overcast in the reference. It also shortens and weakens screen-space indirect lighting to reduce the dark halo around props while retaining SDFGI. The terrain and shallow sky rays share a distance fog tint, with separate daylight curves for the visible sky veil and near wind mist. The preset’s fog density and height falloff stay intact. The rig returns to its authored lighting as Blizzard clears. Disable **Enabled** on this comparison scene node to inspect the base lighting.

The comparison's **Blowing Snow Layer** uses the Terrain elevation and the existing wind field. It attenuates and scatters light along each ray up to 300 m, stopping at opaque geometry. The longer paths blend the distant terrain edge into the same moving mist as the sky. **Blowing Snow Extinction** at zero leaves the short wind mist available for comparison.

The comparison’s **DynamicSky → Snow Settings** resource lowers overall flake opacity and feathers the near field out to 2 m in strong daylight Blizzard. It keeps distant flakes visible against the calibrated sky. As daylight fades, the regular flake opacity and near-field fade return. [Comparison snow settings](comparison_snow_settings.tres)

The comparison inherits **Source Snow and Dust** from Dynamic Sky. Calm Dust and Sandstorm use finite dust paths with coarse cards, fine spots, and depth-bounded local mist. A resolved roof masks the particles underneath and keeps dust moving beyond its eaves. The rig's **Exposure Settings** blends in bounded adaptation after dusk when the active camera uses default exposure. [Shared wind fog defaults](../../weather/airborne/wind_fog_settings.tres) · [Shared exposure defaults](../../weather/exposure/exposure_settings.tres)

The landscape and checker sphere apply the DemoMap’s `.5` maximum dust coverage to the weather profile’s material dust value. The landscape uses a slope threshold, 500 m variation, 3 m scatter, and `.70` coating roughness. The sphere uses its own facing response, 3.5 m triplanar scatter, and `.80` dry coating roughness. Both use the source’s linear dust tint `(.260417, .235053, .191244)` with original procedural scatter. [Landscape material](materials/landscape_example.tres) · [Checker sphere material](materials/wall_example.tres)

| Source capture | Time | Weather or view |
| --- | --- | --- |
| Saved map | 09:36 | Partly Cloudy, default heading |
| Day and weather comparisons | 12:00 | Clear, Partly Cloudy, Rain, Storm, Snow, Blizzard, and Sandstorm |
| Evening | 18:10 | Partly Cloudy, default heading |
| Night | 01:00 | Partly Cloudy, default heading |
| Sunset-facing capture | 17:45 | Partly Cloudy, sunset heading |

The comparison uses independently authored Godot meshes, collision shapes, and materials. The separate [Snow Tracks demo](../snow_tracks_demo.tscn) offers a grazing view of the same deformation system. [Dynamic Sky authoring guide](../../../../docs/dynamic_sky.md)
