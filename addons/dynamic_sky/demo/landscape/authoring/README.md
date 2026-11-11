# West Ridge landscape authoring

The demo uses saved, editable meshes, materials, MultiMesh resources, collision shapes, and scene instances. These offline Python scripts preserve the original geometry and placement source. They are not used at runtime. They require Python with NumPy and SciPy; the small plant builders also read the original groundcover artwork through Pillow. No script downloads content or generates raster artwork.

The local coordinate system belongs to the demo's **Lookout** node, which rotates the site 73 degrees around Y. The terrain spans X/Z −1800 to 1800 m. Its vertex colors store meadow suitability in **R**, worn trail in **G**, drainage in **B**, and forest suitability in **A**. Surface materials and plant placement use this same field. `terrain_sampling.py` samples the actual terrain triangles, rather than a different bilinear surface, to keep roots on the mesh.

| Source | Saved output |
| --- | --- |
| `site_spec.json`, `lake_basin_source.npz`, `build_alpine_valley.py` | `lookout_terrain.obj` and the sampled `terrain_field.npz` |
| `build_forest.py` | `vegetation/forest.tscn`, using the separately authored compact and mature-open spruce meshes |
| `build_meadow.py` | Three short-grass meshes and `vegetation/meadow_carpet.tscn` |
| `build_grass_accents.py` | Three taller grass meshes and `vegetation/ground_cover.tscn` |
| `build_low_shrub.py` | `vegetation/low_shrub.obj` |
| `build_botanical_details.py` | Fern, seedhead, and fallen-branch meshes |
| `build_jointed_outcrop.py` | `details/ridge_outcrop.obj`, including face UVs and normals |
| `build_trail_staging.py` | `details/ridge_trail.tscn`, with rocks, talus, plants, and fallen branches |
| `rebuild_collisions.gd` | Terrain and outcrop collision shapes, after Godot imports the OBJ files |

The terrain source combines an asymmetric basin, regional ridges, authored fault paths, connected drainage incision, and talus relaxation. `lake_basin_source.npz` retains the earlier original lake-bed geometry so mountain edits can preserve the authored basin. The saved lake is 190 × 395 m, centered at local `(0, -29, -237.5)`. Its waterline is −29 m. Re-bake `../lake_bake_bathymetry.py` whenever terrain triangles beneath X ±95 m and Z −435 to −40 m change.

The forest currently saves **17,185 trees in 209 patches**, with 169 mature-open and 40 compact patches. Patches use the 8,780-triangle model nearby, 876 triangles in the middle distance, and 428 triangles far away. The 67,188-triangle model is limited to the four manual foreground trees in the main scene. Patch boundaries use 120 and 650 m after subtracting a 70 m patch radius. This can select detailed geometry across a whole stand before individual trees enter the near range; those numbers are authoring choices, not per-tree distance tests.

The saved short meadow has **634,484 clumps in 171 patches**. Its meshes contain 192, 56, and 12 triangles, with boundary distances 18 and 65 m after subtracting the 12 m patch radius. The current builder recomputes from the current field and produces 634,521 placements, so a rebuild changes 37 placements relative to this saved bake. The medium grass adds **82,180 clumps in 724 patches**, with 348, 96, and 16 triangles, boundary distances 22 and 100 m, and a 12 m patch radius. Grass instance color carries subtle color variation and dry-straw weight. The fern, low-shrub, and seedhead groups use actual leaf or blade geometry.

The jointed outcrop has 13,248 triangles. Its face UVs provide a valid imported tangent basis for the weather material's normal mapping, while the material textures project in world space. The five manual boulders and six trail outcrops use the original [ridge gneiss material](../../materials/ridge_gneiss.md). Place the long basal edge below the terrain; it represents a partly exposed bedrock mass. Small talus retains the separate alpine boulder material.

To rebuild, run the terrain builder first, then the forest, meadow, grass, and trail placement builders from any working directory. Plant and outcrop mesh builders are independent of the terrain. All asset writes use temporary files followed by replacement. Reimport the changed assets in Godot, then run `rebuild_collisions.gd` with the project path selected. Re-bake lake bathymetry when required, and inspect the actual scene in the six saved views before keeping the outputs. Never overwrite scene edits from a running editor with an older generated main scene; the generators do not write `dynamic_sky_demo.tscn`.

The source gallery at the end of this pass rendered the actual saved scene at 1280 × 720 in D3D12 Forward+, with four-sample MSAA, the saved cloud quality of 1, and the saved bounded camera exposure. It covered Clear, Rain, Snow, and 23:30, all six views, and eight world yaw directions. The scene and asset checksums stayed unchanged during capture. Those checks establish a working asset set, not visual equivalence to Unreal or acceptance against the user's landscape references. Broad rounded mountain faces, repetitive distant relief, very deep shade, and the richness of nearby herb layers remain visual limitations.
