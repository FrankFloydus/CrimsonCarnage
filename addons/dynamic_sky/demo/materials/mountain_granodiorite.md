# Mountain granodiorite material

The mountain terrain uses original generated color and separately generated structural height. The two masters in `masters/` are **1254 × 1254** pixels. The bake produces **4096 × 4096 derived storage maps**; resampling does not create native 4K photographic detail. These are authored material estimates rather than measured scan channels. The original prompts remain in [mountain_granodiorite_prompts.txt](mountain_granodiorite_prompts.txt).

The structural height preserves the large joined planes and recessed seams while suppressing the diffuse image's mica and mineral flecks. Those flecks remain color variation. Fine normal relief therefore does not turn every dark mineral into a deep pit. A seeded microscopic grain contributes at most **0.10 mm** of full height range.

| Output | Role |
| --- | --- |
| [Albedo](pbr/mountain_granodiorite_albedo.webp) | Original diffuse artwork with periodic edge conditioning; no diffuse gain. |
| [Normal](pbr/mountain_granodiorite_normal.webp) | OpenGL tangent normal from the structural height over a 12 m tile. |
| [ORM](pbr/mountain_granodiorite_orm.webp) | Linear ambient visibility in R, roughness in G, and zero dielectric metallic in B. |
| [Ambient occlusion](pbr/mountain_granodiorite_ao.png) | Separate 8-bit copy of the fine ORM ambient-visibility channel. |
| [Roughness](pbr/mountain_granodiorite_roughness.png) | Separate 8-bit copy of the fine ORM roughness channel. |
| [Metallic](pbr/mountain_granodiorite_metallic.png) | Black 8-bit dielectric data. |
| [Height](pbr/mountain_granodiorite_height.png) | Unsigned 16-bit normalized source data spanning 0.16 m. |
| [Macro normal](pbr/mountain_granodiorite_macro_normal.webp) | A smoother structural field over a 36 m tile. |
| [Macro ORM](pbr/mountain_granodiorite_macro_orm.webp) | Matching macro ambient visibility, roughness, and zero metallic. |
| [Macro height](pbr/mountain_granodiorite_macro_height.png) | Unsigned 16-bit normalized source data spanning 0.45 m. |

Run `python addons/dynamic_sky/demo/materials/bake_mountain_granodiorite.py` from the project root to regenerate the maps. The script uses the existing periodic-boundary preparation, wrapped resampling, Sobel normals, and eight-direction heightfield horizon integration. [Bake script](bake_mountain_granodiorite.py) · [Measured output ranges and seam statistics](mountain_granodiorite_bake.json)

Before material strength multipliers, the fine normal's median slope is approximately **5.19°** and the macro normal's median slope is **2.09°**. Steeper values occur along the sparse seams. The old diffuse-derived alpine rock field had a median fine-normal slope near 37°, which produced dense embossed relief on broad mountain faces. Fine ambient visibility spans approximately 0.54–1.0 and roughness 0.78–0.86; metallic remains zero.

The saved terrain material samples the fine set at **1/12 repeats per meter** and the macro set at **1/36 repeats per meter**. Its macro normal strength is **0.5**, selected from fixed-camera rendered comparisons; the raw macro-height source remains 0.45 m. Fine normals also use the terrain's detail strength and pixel-footprint filtering. These normal maps alter shading over the mesh. They do not displace its vertices or create the mountain silhouette. [Terrain shader](../landscape/terrain.gdshader) · [Saved demo](../dynamic_sky_demo.tscn)

Runtime albedo and ORM import as BC7, normals as linear BC5 with OpenGL Y orientation, and all five runtime maps have mipmaps. The PNG height files retain 16-bit data on disk. The current engine PNG loader converts them to 8-bit luminance when importing a Texture2D; the terrain uses normals baked directly from the float height field and does not sample those imported height PNGs. [PNG loader](../../../../../godot/drivers/png/png_driver_common.cpp)

The public [Poliigon Mountain Cliff Rock](https://www.poliigon.com/texture/mountain-cliff-rock-texture/10047) and [Weathered Cliff Rock Wall](https://www.poliigon.com/texture/weathered-cliff-rock-wall-texture/10913) pages supplied photographic evaluation references and examples of separate PBR channels. Their runtime assets were not downloaded or copied into this project.
