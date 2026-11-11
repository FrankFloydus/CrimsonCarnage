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

The thin high-cloud wisps are an independent layer in the Unreal material. In the early Godot renderer, reuse of the cloud weather texture for anisotropic wisps created repeated radial flecks. A same-frame A/B removed the flecks by disabling that layer. A separate constant ray-offset A/B removed fixed checkerboard grain in the lower volume. These checks isolated the two artifacts from cloud coverage and color tuning.

## Color modes

| Mode | Observed reference behavior |
| --- | --- |
| Sky Atmosphere | Unreal Sky Atmosphere calculates scattering and transmittance. Atmosphere properties control Rayleigh color, absorption, and sky luminance during overcast conditions. Aerial perspective affects distant scene color. |
| Simplified Color | The sky material samples separate sun and moon scattering volumes using camera direction and celestial position. Authored color and intensity controls give direct control over the day, twilight, and night palette, and the light and dark colors of the 2D and static cloud paths. Distance fog uses the authored fog colors. |

The **Sky survey** viewpoint in West Ridge Observatory frames the sky above the valley. Compare **Partly Cloudy** near noon, dusk facing the sun, and **Overcast** at the same time and camera. For 2D Dynamic and Static, keep the time fixed and observe wind movement, then move the time slider and check lighting. For Color Mode, keep the camera, weather, and cloud mode fixed and compare noon, twilight, and night. [Godot demo](../addons/dynamic_sky/demo/dynamic_sky_demo.tscn)
