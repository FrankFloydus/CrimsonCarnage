# Godot conventions

Use these conventions when authoring scripts, scenes, resources, and project folders. The project-wide requirements are in [AGENTS.md](../AGENTS.md); implemented system structure belongs in [Architecture](architecture.md).

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

Example of a documented export:

```gdscript
## Delay, in seconds, before the action can be used again.
@export_range(0.0, 60.0, 0.1) var action_delay: float = 1.0
```

Godot uses documented exports for Inspector tooltips; see [GDScript documentation comments](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_documentation_comments.html). Use `#` for ordinary comments and `##` for documentation. Never use Python-style triple-quoted strings as comments or documentation.

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

For example, the controller owns its `FirstPersonGait` helper for runtime gait selection, while
the saved `Movement` component exposes movement tuning through **Movement > Settings**.

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

This is an external investigation reference. It is not a project dependency or permission to modify the engine.

Check version compatibility before applying findings: this project's configuration declares Godot `4.7` features, while the checkout's `version.py` identified it as `4.8.0 beta` when these documents were created. Verify the editor build and relevant source revision when investigating version-sensitive behavior. The `stable` documentation URL may also change its target over time.
