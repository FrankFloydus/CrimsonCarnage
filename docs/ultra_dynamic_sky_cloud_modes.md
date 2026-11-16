# Ultra Dynamic Sky 9.7 cloud and color modes

The mode controls in 9.7 select independent axes. The Sky Mode chooses how clouds and the background are rendered. The Color Mode chooses how terrestrial sky color is calculated. The source evidence includes the two enum packages under `Blueprints/Enum/`, the embedded technical manual, the material graph paths, and the saved DemoMap rendered in UE 5.8.4. [9.7 documentation](https://ultradynamicsky.com/Documentation/V9/9-7) · [Package index](ultra_dynamic_sky_packages.json)

## Cloud modes in scope

| Mode | Observed reference behavior |
| --- | --- |
| Volumetric | A world-space cloud component ray-marches density and extinction. The conservative density uses formation, a height profile, and regional coverage. Higher-frequency erosion adds perimeter detail. The density field also supplies cloud shadows and cloud-interior fog. |
| 2D Dynamic | Panning material textures on the sky sphere give an apparent cloud height, layer movement, and fake perspective. Coverage, softness, sun and moon shading, and distribution can be edited independently. There is no scene-volume geometry on this path. |
| Static | A fixed cloud panorama packs lighting from different angles. The cloud layout stays in place, while the apparent light changes with the sun and moon. The authoring tool can capture a chosen volume formation into a new reusable texture. |
| Space | The space background omits terrestrial sky scattering and clouds while retaining the celestial visuals. Space Layer is an independent option for planets, rings, and other additions in terrestrial sky modes. |

In the saved Unreal scene, the default **Partly Cloudy** preset has coverage 3.8 on the weather scale. The lower volume starts at about 0.60 km and is about 0.70 km thick. Its authored profile changes thickness, vertical extinction, and erosion independently with coverage. A partly cloudy daytime reference has distinct, rounded cloud bodies, blue-gray underside shading, broken light rims, and smaller distant banks. The overcast path blends into a connected deck and uses a reduced view-sample scale.

The demo's `VolumetricCloudComponent` uses a dynamic instance of `Volumetric_Clouds`. The actor binds `FormationVolume` (256 × 256 × 128), a quality-specific erosion volume, and `Cloud_Profile` (64 × 256). The material function preview uses `3D_Cells_32`; the live actor supplies the formation texture. `Volumetric_Clouds_Conservative_Density` thresholds the formation against local coverage, shifts the condensation height, and applies profile taper. `Volumetric_Clouds_Extinction` subtracts cubed erosion, applies up to two fine-noise octaves, and multiplies by the cubed profile extinction channel. The profile packs taper, extinction, and erosion amplitude in RGB. The authoring tool blends profile heights and evaluates the two curve keys at that blended height. The formation volume's third axis drives shape evolution; a separate offset moves the field horizontally. The saved demo selects formation mip level zero.

The thin high-cloud wisps are an independent layer in the Unreal material. In the early Godot renderer, reuse of the cloud weather texture for anisotropic wisps created repeated radial flecks. A same-frame A/B removed the flecks by disabling that layer. A separate constant ray-offset A/B removed fixed checkerboard grain in the lower volume. These checks isolated the two artifacts from cloud coverage and color tuning.

## Godot volume field

The current Godot renderer evaluates formation support, altitude-dependent taper and extinction, then three-dimensional erosion. The source audit established the channel roles and approximate spatial scales; the shipping volume textures are independently generated. The 128³ formation and erosion textures and 64 × 256 profile are linear numerical data. The [generator](../addons/dynamic_sky/rendering/tools/generate_cloud_formation.py) reads [authored profile curves](../addons/dynamic_sky/rendering/tools/cloud_profile_curves.json) and reproduces the three saved images without an Unreal project or asset export. The profile blends its curve keys at the interpolated layer height. The field uses extinction per meter and converts kilometer ray segments for integration.

The main view combines direct light, cloud self-shadowing, three scattering terms, and altitude-dependent ambient light. The short secondary light ray and projected overcast variation follow the reference material structure; the local diffuse visibility and air haze are Godot approximations. The native directional projector uses the same field without the observer fade. Clear skips the volume; the 2D Dynamic, Static, Space, and color mode paths retain their own materials and settings. The volumetric sky pass does not integrate against opaque scene depth yet.

The visible Volumetric sky blends a faint high cirrus layer in clear weather. The shipped Sky Materials use an editable **Clear Wisp Texture** and **Clear Wisp Amount** of 0.22. Two mirrored texture samples drift across the dome and blend as the pattern moves. The layer fades out as low cloud coverage rises to 0.18. Set the amount to zero for a clear sky without cirrus. [Original cirrus mask](../addons/dynamic_sky/rendering/cloud_modes/clear_cirrus.png)

In an isolated 1280 × 720 D3D12 Forward+ comparison on the RTX 4090, High median viewport GPU time rose from 0.61 to 1.81 ms facing the horizon, 0.26 to 0.87 ms overhead, and 1.12 to 1.63 ms for overcast. Clear remained below 0.1 ms in that fixture. These are isolated sky measurements rather than full demo frame times. The saved demo comparison also checked the native projector, both color modes, and the other cloud modes. The new field adds coherent cloud bodies and underside variation; distant banks can still show repeated bands.

**Exposure Settings → Cloud Interior Fog Strength** controls the extinction of nearby geometry when the active camera enters the volumetric field. The saved default is 0.06. The Forward+ effect requires native volumetric fog and uses the active Environment's fog length, which is 64 m in the demo. It samples the same formation, altitude profile, and erosion as the sky before the sky's near-camera fade. A gap in the field stays clear at the same altitude as a cloud. The setting is independent of the above-cloud weather multipliers. Set it to zero to disable the local effect.

## Color modes

| Mode | Observed reference behavior |
| --- | --- |
| Sky Atmosphere | Unreal Sky Atmosphere calculates scattering and transmittance. Atmosphere properties control Rayleigh color, absorption, and sky luminance during overcast conditions. Aerial perspective affects distant scene color. |
| Simplified Color | The sky material samples separate sun and moon scattering volumes using camera direction and celestial position. Authored color and intensity controls give direct control over the day, twilight, and night palette, and the light and dark colors of the 2D and static cloud paths. Distance fog uses the authored fog colors. |

The **Sky survey** viewpoint in West Ridge Observatory frames the sky above the valley. Compare **Partly Cloudy** near noon, dusk facing the sun, and **Overcast** at the same time and camera. For 2D Dynamic and Static, keep the time fixed and observe wind movement, then move the time slider and check lighting. For Color Mode, keep the camera, weather, and cloud mode fixed and compare noon, twilight, and night. [Godot demo](../addons/dynamic_sky/demo/dynamic_sky_demo.tscn)
