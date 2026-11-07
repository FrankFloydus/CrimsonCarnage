# Project instructions

These instructions apply throughout this Godot project. Follow the user's current instructions and keep all work within the requested scope.

The game is a first-person RPG inspired by the spirit of *The Elder Scrolls V: Skyrim*, with action RPG elements inspired by *Diablo*. This direction provides context; it does not authorize implementing particular features.

## Explicit permission to use the user's PC

- **NEVER EVER USE THE USER'S PC UNLESS THE USER EXPLICITLY PERMITS IT.**
- Do not launch, focus, inspect, control, or capture desktop applications, browser windows, or screens, and do not operate the keyboard or mouse, without the user's explicit permission.
- A request to implement, port, fix, or test project code does not grant permission to interact with the user's desktop. Do not infer that permission from available tools, skills, or prior agent behavior.

## Scope and collaboration

- Implement only what the user explicitly requests. Never add unsolicited features, content, systems, unrelated refactors, or speculative infrastructure.
- Think critically before implementing a proposed solution. If a materially better approach exists, explain the reasoning and tradeoffs openly so the user can discuss it. A suggestion does not authorize changing the requested design or expanding the scope.
- Resolve routine implementation choices with the simplest approach that satisfies the request and these instructions.
- Treat chats described as "brainstorming," "let's think together," or similar as design discussions. Do not implement changes unless the user explicitly switches to implementation. Write design documents only when requested.
- Use subagents only when work can be efficiently parallelized and there is a clear reason to expect a time saving. If the user explicitly requests subagents, using them is mandatory.

## Architecture and authoring

- Balance sound architecture with simplicity. Introduce a pattern or abstraction only when its benefits fit the current task. Avoid overengineering and speculative generalization.
- **Prefer composition over inheritance.** Assemble entities from focused components; keep coordinating entities simple and avoid deep gameplay inheritance hierarchies or oversized base classes.
- **Scene components must provide meaningful editor authoring or tuning value.** Keep components without that value internal to their owning entity or component, using a focused helper such as `RefCounted` when separate code is useful. Composition does not require extra scene nodes. Follow the [component authoring conventions](docs/godot_conventions.md#scene-components-and-internal-helpers), including a single clear Inspector owner for each tuning concern.
- Prefer event-driven communication where appropriate, using Godot signals for meaningful events. Keep continuous simulation in the callbacks that suit it.
- **Use a data-driven approach for all data-related concerns.** Keep authored content, configuration, and tuning values in editable data rather than embedding them in behavior code. Choose the simplest suitable Godot resource or data format.
- **Deliver physical, editable Godot assets.** Requested scenes, UI, and resources must exist as saved project files that the user can inspect, change, delete, and improve in the editor. Do not replace them with code that constructs everything at startup.
- Runtime construction is appropriate for genuinely algorithmic, randomized, or runtime-only needs. Instantiating an existing saved scene at runtime is also appropriate.
- Keep the folder structure orderly and easy to navigate. Use clear names, keep related files together, and create folders as actual work requires them.
- For computationally heavy logic, propose moving the relevant work into a C++ plugin and exposing only what GDScript needs. **Always ask the user before implementing that native code or integration.**

## Godot coding requirements

- Follow the official [GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html) for naming, formatting, and code organization.
- **Every Inspector-exposed exported property must have a meaningful `##` documentation comment** so the editor can display its hover tooltip. This applies to `@export` and specialized export annotations.
- Use `#` for ordinary GDScript comments and `##` for documentation. Never use Python-style triple-quoted strings for documentation or comments.
- Apply the detailed [Godot conventions](docs/godot_conventions.md) when writing scripts, scenes, resources, or organizing project files. That document also records the local Godot source reference.

## Verification and handoff

- Use judgment when testing. Keep automated tests focused on meaningful gameplay behavior and math-heavy logic. Avoid low-value tests that slow development without useful confidence.
- **Behavior tests own their tuning.** Set costs, cooldowns, timing, speeds, resources, and other editable values on in-memory fixtures. Separate saved-asset checks from behavior checks. Verify saved assets have valid references, wiring, tags, and supported ranges. Keep fixture edits in the test process and exercise the same runtime entry points used by the game.
- **Never write tests that require UI elements to have a particular color or font size.** Use visual inspection when presentation needs checking.
- Choose checks appropriate to the change. Documentation-only work does not require gameplay tests; a small editor check or relevant gameplay check may be enough for a small implementation change.
- At completion, give a brief summary of what changed and what was checked. If the change can be tested manually, provide brief steps and the expected result. State clearly when a relevant check could not be performed.

## Documentation and instruction scope

- [Architecture](docs/architecture.md) is the master reference for the project's code architecture. Consult it when creating or changing systems, responsibilities, dependencies, data ownership, or the project structure.
- Read [Ability framework ownership](combat/AGENTS.md#ability-framework-ownership) before changing an ability, effect, or status rule, including when its caller lives outside `combat/`.
- Keep this root file focused on project-wide rules. As substantial systems are introduced, place a scoped `AGENTS.md` in the relevant directory when it needs specific instructions, and link it from the relevant documentation.
- Put detailed system explanations in focused Markdown files and reference them from the architecture document or the nearest `AGENTS.md`. Read supporting documents when they apply to the task; do not require every document for every small edit.
- Before editing a directory, check for applicable nested `AGENTS.md` files. Codex's startup discovery follows the working-directory path; do not assume it has loaded every nested instruction file automatically.
- Scoped instructions specialize the root guidance for their directory. Do not use them to silently weaken project-wide requirements; discuss a conflicting rule with the user.
- **Before every final handoff, check whether the task made any AI-facing documentation inaccurate or obsolete. Update affected instructions, architecture, system documents, and links before finishing.** Keep implemented facts distinct from proposals.

The instruction layout follows OpenAI's [AGENTS.md guidance](https://learn.chatgpt.com/docs/agent-configuration/agents-md) and its advice to [keep instructions focused and read documentation according to the task](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra).
