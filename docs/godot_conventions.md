# Godot conventions

Use these conventions when authoring the Player, the Playground course, and their settings. [Project instructions](../AGENTS.md) · [Movement architecture](architecture.md)

## Coding style

Follow the official [GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html), with the project's mandatory export documentation rule below.

| Element | Convention |
| --- | --- |
| Project folders and authored file names | `snake_case` |
| GDScript classes and scene node names | `PascalCase` |
| Functions, variables, and signals | `snake_case` |
| Constants and enum members | `CONSTANT_CASE` |
| Enum type names | `PascalCase` |

Preserve filenames required by their tools, such as `AGENTS.md` and `project.godot`. Use UTF-8, tabs for GDScript indentation, and the official guide's member ordering and formatting. Keep naming and style consistent within each system.

## Export documentation

Every exported property exposed in the Inspector must have a meaningful `##` documentation comment, including properties using specialized annotations such as `@export_range`, `@export_enum`, or `@export_file`.

Place the comment immediately above the property's annotation block. Explain its purpose and include units, constraints, or special behavior when relevant. A group heading does not document the individual properties beneath it.

The stair height setting documents the unit and the meaning of zero.

```gdscript
## Maximum stair riser height, in meters. Zero disables automatic stair ascent.
@export_range(0.0, 1.0, 0.01, "or_greater") var max_step_height: float = 0.3
```

Use `#` for ordinary comments and `##` for documentation, including Inspector tooltips. Never use Python-style triple-quoted strings as comments or documentation. [GDScript documentation comments](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_documentation_comments.html)

Put a `##` description immediately above every enum type and each enum member. Give each choice its own line. Describe the behavior it selects and preserve serialized values when adding or rearranging comments.

When a mode makes another property irrelevant, refresh the property list on mode changes and remove only `PROPERTY_USAGE_EDITOR` from the dependent property. Keep storage enabled so an authored value returns when the designer switches back. Read and validate the dependent value only in modes where it applies.

## Scene components and internal helpers

Expose a component as a scene node only when it gives the user useful editor authoring or tuning.
If it adds no such value, keep it internal to its owning entity or component. Composition does
not require a scene node for every responsibility.

- Keep logic-only state, mode selection, and algorithms internal. Use an owned `RefCounted` helper
  when separating that code is useful; simple logic can stay directly on its owner.
- Give each tuning concern one clear Inspector owner. Do not expose the same configuration
  resource on unrelated components merely to reflect code separation.
- Have internal helpers receive needed configuration from their owner. Do not duplicate tuning
  or invent editable options to justify a scene node.

The controller owns its `FirstPersonGait` helper for runtime gait selection. The saved Movement, Crouch, and Look components each expose their own **Settings** resource.

Keep requested scenes, UI, and resources as saved, editable project assets. Extracting internal
logic into helpers must preserve that authored content and its meaningful editor controls.

## Editable assets and data

- Save requested scenes and UI as `.tscn` files, with the authored node hierarchy and relevant configuration available in the editor.
- Save authored data and reusable configuration as editable resources, such as `.tres`, or another suitable data format. Keep data separate from the logic that consumes it.
- Existing saved scenes can be instantiated at runtime. Algorithmic, randomized, and runtime-only content may be constructed in code when the requested behavior requires it.
- For dynamic UI content, save the reusable layout or item scene so it remains editable; code can populate and instantiate it at runtime.
- Scripts and editor tools may help create assets, but the final requested authored assets must be saved in the project.

## Folder organization

- Put data-driven definitions, catalogs, and reusable gameplay tuning in `data/`, with a subfolder for each category that has content.
- Group standalone assets by type. Use `scenes/`, `scripts/`, `shaders/`, `materials/`, `textures/`, `meshes/`, and `particles/` as needed. Use shallow domain subfolders such as `scripts/player/` and `scenes/weapons/`.
- Keep scene-specific subresources in their scenes and keep Godot editor plugins under `addons/`. Move `.uid` and `.import` sidecars with their assets.
- Keep documentation in `docs/`, with system details linked from the architecture document. Place scoped `AGENTS.md` files beside the scripts they govern when specialized rules are needed.

## Engine references

The project targets **Godot 4.8 beta** based on upstream revision `c51ff06e8` in the sibling Godot checkout. It uses Jolt Physics, physics interpolation, and Forward Plus with D3D12 on Windows. Melee and effect scripts use the upstream `*_into` physics query APIs available in this revision. The local build also includes the Forward+ directional projector used by Dynamic Sky, rendering-device particle sub-emission queues that retain births across fixed simulation steps, and an audio shutdown fix for active playback. Match version-sensitive findings to the installed build. The editor launched by the user is `C:\Users\Drako\Desktop\_CRIMSON_CARNAGE_DEV\Godot_RPG.exe`. Every verified engine rebuild must replace that root executable, and the installed copy must be checked. [Godot source](../../godot) · [Installed editor](../../Godot_RPG.exe) · [Project settings](../project.godot)

Forward+ cameras can enable **Auto Exposure → Use EV Adaptation** on either Practical or Physical camera attributes. **Bright Scene Speed** and **Dark Scene Speed** cap exposure changes separately, in stops per second. The mode defaults to off. The installed editor passed a native brightness step with separate viewport histories, history reset on resize and re-enable, and saved camera resource checks. [CameraAttributes API](../../godot/doc/classes/CameraAttributes.xml) · [Forward+ exposure shader](../../godot/servers/rendering/renderer_rd/shaders/effects/luminance_reduce.glsl)

For shader-driven changes to static GI geometry, the custom Forward+ build exposes `RenderingServer.instance_invalidate_sdfgi(instance)`. It queues the instance's world culling bounds and refreshes the overlapping SDFGI cascades as each viewport renders. The refresh keeps the Environment and probe history active. Use `extra_cull_margin` or a custom AABB to include the displacement in culling bounds, and batch infrequent requests. Dynamic Sky's Snow Track Receiver uses this hook for accumulated layer depth changes. [RenderingServer API](../../godot/doc/classes/RenderingServer.xml) · [Snow Track Receiver](dynamic_sky_snow_tracks.md)

The sibling source implements the native **Node → Inspector → Exposed In Scene** child checkbox (`Node.inspector_exposed_in_scene`). It edits the nearest owning scene root's `inspector_exposed_nodes: Array[NodePath]` list, which remains available under **Inspector → Advanced**. Exposed child Inspectors appear before the instance root's ordinary properties. Changes target the real child properties, use the containing scene's undo history, and save as ordinary PackedScene instance overrides; disabling exposure retains existing overrides. [Authoring workflow](dynamic_sky.md#expose-internal-nodes-in-the-instance-inspector) · [Node source](../../godot/scene/main/node.cpp) · [Scene serialization](../../godot/scene/resources/packed_scene.cpp)

Foreign resources embedded in a source scene remain guarded until the author explicitly presses **Make Editable Copy** in the exposed child's resource editor. This creates an instance-local copy of the resource and its internal subresources through native assignment and undo. External resources keep normal sharing behavior, imported resources stay read-only, and a read-only parent cannot bypass its protection through the copy action. Ordinary external resources still use **Make Unique** or `Resource.resource_local_to_scene` as appropriate. Embedded child animation keying remains disabled. [Resource editor source](../../godot/editor/inspector/editor_properties.cpp)

This feature is installed in the root `Godot_RPG.exe` from the `tests=yes extra_suffix=exposed_nodes` [editor build](../../godot/bin/godot.windows.editor.x86_64.exposed_nodes.exe). The same build also produces a [console executable](../../godot/bin/godot.windows.editor.x86_64.exposed_nodes.console.exe). Native PackedScene checks passed 66 assertions, including a rerun from the installed root executable. Actual native widget checks passed 35 positive/read-only checks and 27 independent negative checks. The 35-check path also passed in an offscreen D3D12 editor, and its rendered button and controls were visually inspected without interacting with the user's open editor. Record the executable used when reporting results.

For an already imported checkout, run this PowerShell command from the Godot project root to verify scene startup and the item catalog report. For a fresh test copy, run the same executable with `--headless --path . --import` first.

```powershell
& ..\godot\bin\godot.windows.editor.x86_64.console.exe --headless --path . --quit-after 60
```

Use the Playground's rendered view for checks of GPU particles, decals, shadows, and first-person presentation. [Manual checks](../README.md)

### HDR viewport captures

The project enables **HDR 2D**. Forward+ viewport readback can therefore return linear half-float RGB or RGBA even after scene tonemapping. Before saving a display PNG, call `Image.linear_to_srgb()` on `FORMAT_RGBH` or `FORMAT_RGBAH`, then `save_png()`. The local engine supports that conversion directly on half-float data, preserving dark precision. Do not apply it again to an already encoded RGB8/RGBA8 readback. Record the image format and conversion with visual QA evidence. A D3D12 calibration with unshaded linear 0.18 returned 0.1799 in the raw image and 0.4612 after conversion, matching the display transfer. [Image conversion](../../godot/core/io/image.cpp) · [Scene tonemapping](../../godot/servers/rendering/renderer_rd/renderer_scene_render_rd.cpp)

Earlier Dynamic Sky scratch PNG/JPEG galleries saved raw half-float images without this conversion. Their color, brightness, and cross-engine luminance comparisons are invalid; geometry and functional checks are separate evidence. The corrected `cc_weather_acceptance_srgb` matrix records the conversion per frame. Continue visual comparisons from corrected captures rather than compensating for the old images through scene lighting or material gains.
