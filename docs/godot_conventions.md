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

- Group files by a clear feature or responsibility, keeping closely related scenes, scripts, and resources together.
- Create a shared location only when something is actually shared. Prefer specific folder names over catch-all folders such as `misc`.
- Add folders as needed for requested work; keep the structure shallow enough to navigate comfortably.
- Keep documentation in `docs/`, with system details linked from the architecture document. Place scoped `AGENTS.md` files beside the systems they govern when specialized rules are needed.

## Engine references

Use the official Godot documentation and, when behavior is unclear or an underlying implementation needs checking, inspect the local official Godot source checkout:

```text
C:\Users\Drako\Desktop\_QUADER_DEV\resources\_SOURCE_CODE\godot
```

Use the checkout for read-only investigation. The project targets **Godot 4.7**. Match version-sensitive findings to the editor build used to run the project. [Project settings](../project.godot)
