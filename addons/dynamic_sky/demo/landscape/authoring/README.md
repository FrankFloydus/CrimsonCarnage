# West Ridge landscape authoring

The demo uses saved, editable meshes, materials, MultiMesh resources, collision shapes, and scene instances. These offline Python scripts preserve the original geometry and placement source. They are not used at runtime. They require Python with NumPy and SciPy; the small plant builders also read the original groundcover artwork through Pillow. The rock builder uses scikit-image 0.25.2 and PyMeshLab 2025.7.post1 for offline meshing and simplification. These tools are not runtime dependencies. No script downloads content or generates raster artwork.

The local coordinate system belongs to the demo's **Lookout** node, which supplies the site transform. The terrain spans X/Z −3,000 to 3,000 m and uses 330,481 vertices and 658,664 triangles. The outer 1,200 m around the original site uses 24 m grid spacing. Vertex colors store meadow suitability in **R**, worn trail in **G**, drainage in **B**, and forest suitability in **A**. Surface materials and plant placement use this same field. `terrain_sampling.py` samples the actual terrain triangles to keep roots on the mesh.

| Source | Saved output |
| --- | --- |
| `site_spec.json`, `landform_spec.json`, `authored_site_source.npz`, `build_alpine_valley.py` | `lookout_terrain.obj` and the sampled `terrain_field.npz` |
| `build_forest.py` | `vegetation/forest.tscn`, using the separately authored compact and mature-open spruce meshes |
| `build_meadow.py` | Three short-grass meshes and `vegetation/meadow_carpet.tscn` |
| `build_grass_accents.py` | Three taller grass meshes and `vegetation/ground_cover.tscn` |
| `build_low_shrub.py` | `vegetation/low_shrub.obj` |
| `build_botanical_details.py` | Fern, seedhead, and fallen-branch meshes |
| `build_jointed_outcrop.py` | Large `details/ridge_outcrop.obj` and small `details/ridge_outcrop_small.obj`, including face UVs and normals |
| `build_trail_staging.py` | `details/ridge_trail.tscn`, with rocks, talus, plants, and fallen branches |
| `rebuild_collisions.gd` | Terrain and outcrop collision shapes, after Godot imports the OBJ files |

`landform_spec.json` defines broad uplift zones, valley paths, harder rock belts, secondary spurs and gullies, and the outer ranges. The offline terrain processes route drainage through connected catchments, cut bedrock with a stream power rule, and settle released rock as a separate sediment layer. They produce authored landforms and do not model geological time. `authored_site_source.npz` supplies the earlier lookout, trail, rock footprints, and wet lake triangles independently of the generated field. The west bank tapers into the valley beyond the built lookout. The saved lake and its water region are 190 × 395 m, centered at local `(0, -29, -237.5)`. Re-bake `../lake_bake_bathymetry.py` whenever terrain triangles beneath X ±95 m and Z −435 to −40 m change.

The forest saves **18,879 trees in 494 patches**: 7,898 retained from the authored site and 10,981 seeded infill. The builder keeps retained rotation, size, and horizontal position, and samples their height from the current triangles. Patches use the 8,780-triangle model nearby, 876 triangles in the middle distance, and 428 triangles far away. The 67,188-triangle model is limited to the four manual foreground trees in the main scene. Patch boundaries use 120 and 650 m after subtracting a 70 m patch radius. These distances apply to the whole stand.

The saved short meadow has **644,578 clumps in 171 patches**. Its meshes contain 192, 56, and 12 triangles, with boundary distances 18 and 65 m after subtracting the 12 m patch radius. The medium grass adds **66,867 clumps in 626 patches**, with 348, 96, and 16 triangles, boundary distances 22 and 100 m, and a 12 m patch radius. Grass instance color carries subtle color variation and dry straw weight. The fern, low shrub, and seedhead groups use actual leaf or blade geometry. The forest and grass builders omit empty patches before saving their weather and wind receivers.

The large outcrop has **18,000 triangles**, and the small boulder has **10,000**. Both retain the centered 1.4 × 1.08 × 1.16 m authoring envelope, with distinct fracture patterns and silhouettes. Four large trail outcrops use the large mesh; the five manual foreground boulders and the TrailBlock and BeddedStone use the small mesh. Each uses matching collision and the original [ridge gneiss material](../../materials/ridge_gneiss.md). Face UVs provide the imported tangent basis for the normal map while textures project in world space. Small talus retains the separate alpine boulder material.

To rebuild, run the terrain builder first, then the forest, meadow, grass, and trail placement builders from any working directory. Plant and outcrop mesh builders are independent of the terrain. All asset writes use temporary files followed by replacement. Reimport the changed assets in Godot, then run `rebuild_collisions.gd` with the project path selected. Re-bake lake bathymetry when required, and inspect the actual scene in the six saved views before keeping the outputs. Never overwrite scene edits from a running editor with an older generated main scene; the generators do not write `dynamic_sky_demo.tscn`.

For visual checks, use the actual saved scene and set fixed clocks or weather in memory. The project enables HDR 2D, so a viewport image can arrive as linear RGBH or RGBAH. Call `linear_to_srgb()` before saving those floating-point formats to PNG. RGB8 and RGBA8 images already carry display values. Earlier raw HDR PNGs remain useful for silhouettes, but they cannot establish the displayed color or exposure. Scene captures verify the working asset set and its current visual limitations; they do not establish equivalence to Unreal or acceptance against the landscape references.
