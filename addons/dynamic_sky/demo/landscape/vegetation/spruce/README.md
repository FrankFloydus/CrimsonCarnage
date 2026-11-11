# Alpine spruce assets

`alpine_spruce.tscn` is the compact, 7.2 m tree. `alpine_spruce_open.tscn` is a taller, 10.2 m tree with a clear lower trunk. Both are saved, editable Godot scenes with the same four distance levels and shared `spruce_material.tres`. They are demonstration assets, independent of the sky plugin runtime.

Each architecture has a curved, tapered trunk, radial primary branches, drooping secondary shoots, and crossed, curved needle sprays. The near mesh also carries individual 14–26 mm terminal needles. The sprites use the existing original ImageGen `spruce_bough.png`; their transparent pixels are actually clipped in the shader, including the shadow pass. No opaque diamond tuft geometry is used.

| Mesh suffix | Base triangles | Standalone scene range |
| --- | ---: | --- |
| `near` | 67,188 | 0–35 m |
| `mid` | 8,780 | 35–150 m |
| `far` | 876 | 150–650 m |
| `distant` | 428 | 650 m and beyond |

These counts are the authored OBJ bases, before Godot's imported mesh LODs. The compact files are named `spruce_*.obj`; the open-trunk files are named `spruce_open_*.obj`. Forest patches can select these saved meshes directly, with their own distances, instead of instantiating one scene per tree. Surface-weather helpers are included on all levels of the standalone scenes, with wind helpers on the first three levels. Patch owners can supply the same shader parameters on a MultiMesh.

The shared shader has a neutral PBR response for bark, clipped needle alpha, alpha-to-coverage for MSAA, a curved canopy lighting normal for sprays, individual normals for geometric needles, roughness variation, and shadowed backlighting. `needle_backlight` is a transmitted fraction: Godot multiplies the final diffuse lighting by albedo, so this value must not be tinted by albedo a second time. It uses no emission or screen-space subsurface scattering.

The texture inputs reuse the project's original bough and bark albedo/normal/ORM maps. `needle_tint`, `needle_normal_bend`, `needle_backlight`, and `alpha_cutoff` are editable material parameters. The existing shared foliage wind and wet/snow/dust instance parameter contracts are preserved.

The saved meshes and scenes can be inspected and replaced independently. Changing the shared material affects both architectures and all four levels. Forest placement, scale distributions, and patch switching distances are authored by the demo's forest scene, rather than by these asset scenes.
