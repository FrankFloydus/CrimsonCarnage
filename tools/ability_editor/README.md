# Ability Editor

A standalone Qt desktop app using the Fusion widget style with the Catppuccin Latte palette. [qt-themes](https://github.com/beatreichenbach/qt-themes)

The top-level workspaces are **Abilities**, **Effects**, **Tags**, **Attributes**, and **Player Actions**. The first two show **ID**, **Icon**, **Name**, and **Tags** in their respective catalogs. Both tables start with the highest ID first. Click a column header to sort by that column and click again to reverse the order. Sorting by Icon groups rows by whether an icon is assigned.

IDs are positive integers that are unique across both tabs. The catalog reports missing and duplicate IDs. Each tab has its own search by ID, name, and tag.

## Create and edit definitions

Use **New** on the toolbar to create an ability or effect. Hover over a row in the **Catalog** to show its definition in the editor. If your current definition has unsaved edits, click another row or press Enter to switch with a save or discard prompt.

Each definition has one scrollable editing page. The ability page groups activation, targeting, delivery, costs, and actions into separate foldable sections. After **Basics**, the effect page shows **What it does**, followed by timing, target requirements, and other settings. Embedded amounts sit next to their owning cost, action, or modifier. **Add amount** creates the amount and focuses the fixed value.

**Targeting** sets the ability's initial target or aim point. In **What happens**, each step uses the targets from its triggering event by default. Use **Override targets** to run a separate query for that step, or **Use event targets** to go back to the default.

**Add effect** and **Choose effect** open the project effect picker. Search by name or ID. The picker and assigned effect rows show each effect's icon, ID, and name. Use **Open effect** to edit a linked effect or **Unlink effect** to remove its reference from the current action.

The forms show gameplay configuration. The editor preserves Godot Resource metadata already stored in a definition when saving it.

Under **Costs and cooldown**, choose a **Payment pool** and **Payment mode**. **Exact cost** pays the calculated amount. **Variable spending** requires at least the calculated amount and pays available points up to the **Spending cap**. **Amount clamp minimum** and **Amount clamp maximum** bound the calculation before it is used as the payment or minimum. The form uses Points automatically and shows only Fixed, Stat Percent, Resource Percent and Level Curve. Saving an older cost with a different stored unit updates that cost to Points.

For a cost based on the resource being spent, select **Resource Percent** and set **Calculate from** to **Payment pool**. Set the percentage and choose **Current**, **Maximum**, or **Missing** under **Pool value**. The shortcut reads the caster's live pool and follows changes to **Payment pool**. Choose **Custom resource** to select a different basis pool, actor, or read timing. Existing Resource Percent costs keep their saved custom basis until you switch them.

**Save** writes the definition directly as `.ability.json` or `.effect.json` in the linked project. The first save assigns a positive ID in the shared ability/effect namespace. The editor compares the loaded disk revision before replacing a file and keeps a draft open on a conflict. **Validate** checks the current draft with Godot and reports the results in **Issues**.

To edit Fireball's relationship filter, open **Targeting → Who it can affect** and change **Allegiance**. With an **Animation** cast, choose **Release event** from the project tag picker and use the same key on the animation marker in Godot. Use **Show inactive settings** at the top of the page to inspect fields used by other modes. Switching modes keeps their saved values.

In Godot, assign paths through **AbilitySystem → Granted Ability Files** or **Startup Effect Files**. Start a new game run to use the saved JSON. Godot creates native execution and effect objects from the authored JSON for the run.

## Assign player actions

Open **Player Actions** to see the default controls and starting combat slots. Use **Choose** on a slot and search the player's granted abilities by name or ID. The picker and the assigned row show the icon, ID and name. **Choose** and **Clear** save the slot to `player/starting_loadout.json` immediately. Start a new game run to load the saved assignments.

Set default keys in **Godot → Project Settings → Input Map**. Add an action named `ability_slot_4`, or another available slot number, and bind its keys there. Use **Reload** in Player Actions to pick up saved Input Map changes. To make a new ability available in the picker, add its JSON file to the Player's **AbilitySystem → Granted Ability Files** and reload.

Set how the ability responds under **Activation → Input gesture**. **Press** starts on button-down. **Hold** starts a sustained or channeled action that ends on button-up. **Release** starts on button-up. **Hold + release** starts the cast on button-down and starts its configured delivery timing on button-up. For example, **Hold + release** with **Animation** plays the release animation after button-up and waits for its release marker. **Presentation → Casting visual cue** selects the optional visual played by the actor during casting.

## Register and use tags

Open **Tags** to browse the linked project's gameplay tags. **New Tag** takes a full dotted name such as `Ability.Spell.Projectile`. Right-click a branch and choose **Add Child Tag** to fill in its prefix. The app saves the registration immediately to `combat/tags/gameplay_tags.json` in the linked checkout. Keep that file in version control with the resources that use its names.

The Tags tree shows **Tag**, **Description**, and **Source**. Source is **Code-owned** for a tag marked as used by game code, **Project** for an ordinary registered tag, and **Branch** for a parent implied by registered descendants. **Filter by Tag** in Abilities and Effects can select a tag or an entire branch. The Godot Inspector's **Gameplay Tag Picker** reads the same registry when opening its choices. Assigning or emitting a tag requires an explicitly registered name. Matching and requirement fields can also pick implied branches.

Use **Validate** to report unknown tags and their configuration locations.

## Manage attributes

Open **Attributes** to browse the linked project's attribute catalog. **New Attribute** registers a generic stat with a permanent numeric ID. Select a row and choose **Edit** to open its details. The ID and internal key are fixed after registration. Use **Save Details** to update the catalog in `combat/attributes/attributes.json`. Godot reads the same entries for generic attribute selectors and modifiers. Reopen the relevant Inspector selection or start a new game session to see saved definitions.

**Accuracy Rating** also opens the **Hit Chance Curve** editor. Choose **Base chance** or **Hit chance ceiling**, then drag a point vertically or enter its percentage. The eleven points correspond to target level gaps +0 through +10. The example uses the current Godot calculation with a level 50 attacker and 69 Accuracy Rating. **Save Curve** writes the two existing Accuracy arrays in `combat/combat_rules.json`. The game reads the saved curve on its next run. Details and curve have separate save actions because they belong to different project files.

Use the attribute row's **Delete** action for unused custom entries. Godot checks saved scenes and resources for attribute references first. The game requires its built-in entries, and deleted custom IDs stay reserved.

## Link the Godot project

1. Import the game project once in its compatible Godot editor. Field metadata and validation use Godot's imported script cache.
2. The Ability Editor detects the project when launched from inside its checkout. To link another checkout, use **File → Link Godot Project** and select its `project.godot`.
3. If Godot is unavailable on `PATH`, use **File → Choose Godot Executable** and select the executable for the project. The app remembers both paths.
4. Use **Reload** after an external edit to the JSON.

## Delete definitions

Select an entry and choose **Delete**. The app checks saved path and UID references before moving the JSON file to the Windows Recycle Bin.

## Run on Windows

Double-click `builds/ability_editor/Ability Editor.exe` when the standalone build is available. To run from source with Python 3.10 or newer, run these commands from the project root in PowerShell.

```powershell
$abilityEditorEnv = Join-Path $env:LOCALAPPDATA 'ability-editor-venv'
python -m venv $abilityEditorEnv
$abilityEditorPython = Join-Path $abilityEditorEnv 'Scripts\python.exe'
& $abilityEditorPython -m pip install -r .\tools\ability_editor\requirements.txt
& $abilityEditorPython .\tools\ability_editor\app.py
```
