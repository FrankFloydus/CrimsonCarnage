# Ability Editor

A standalone Qt desktop app using the Fusion widget style with the Atom One palette. [qt-themes](https://github.com/beatreichenbach/qt-themes)

The **Abilities** and **Effects** tabs show **ID**, **Icon**, **Name**, and **Tags** from the linked Godot project. Both tables start with the highest ID first. Click a column header to sort by that column and click again to reverse the order. Sorting by Icon groups rows by whether an icon is assigned.

IDs are positive integers that are unique across both tabs. The catalog reports missing and duplicate IDs. Each tab has its own search by ID, name, and tag.

## Create and edit abilities

In **Abilities**, choose **New Ability**, or select a saved ability and choose **Edit**. Double-click also opens a saved ability. **Activation** sets the cast mode, cost and cooldown. **Delivery & Targets** sets how the cast reaches its targets and who is eligible. Projectile aiming and target allegiance are separate controls.

In **What happens**, select a timing and add a block from **Block Library**. Select a block to edit its values or move it to another compatible timing. **Delivered Hit** groups the impact effects that share one hit check. **After confirmed hit** can run on a fully absorbed hit. **After damage dealt** requires actual Health loss. The **Example outcome** control illustrates these timing rules with a sample outcome.

Use **Apply saved effect** to link an existing effect. A linked effect keeps its own settings and identity. Other supported blocks become native actions, reactions or ability-owned effects. Complex saved logic the composer cannot represent remains visible as read-only. Summon and Teleport are shown as unavailable until their game adapters exist.

**Check** validates a draft through headless Godot. **Save Ability** validates and publishes a native Resource in the linked checkout. For a new ability, choose its `.tres` path and Godot assigns its ID. To test it on an actor, grant that file through the actor's AbilitySystem. Edits keep the ability ID and its file UID. Headless Godot reserializes text resources, so Git can show regenerated reference IDs and path-based external references alongside the edit. Save or close any pending Godot Inspector edit for the ability before using Qt, and reload the resource or run the game again after a Qt save. If the file changes on disk while the composer is open, reopen it before saving.

## Register and use tags

Open **Tags** to browse the linked project's gameplay tags. **New Tag** takes a full dotted name such as `Ability.Spell.Projectile`. Right-click a branch and choose **Add Child Tag** to fill in its prefix. The app saves the registration immediately to `combat/tags/gameplay_tags.json` in the linked checkout. Keep that file in version control with the resources that use its names.

The Tags tree shows **Tag**, **Description**, and **Source**. Source is **Code-owned** for a tag marked as used by game code, **Project** for an ordinary registered tag, and **Branch** for a parent implied by registered descendants. **Filter by Tag** in Abilities and Effects can select a tag or an entire branch. The Godot Inspector's **Gameplay Tag Picker** reads the same registry when opening its choices. Assigning or emitting a tag requires an explicitly registered name. Matching and requirement fields can also pick implied branches.

The headless catalog and combat resource validator report unknown tags with the resource field that uses them. Press **F5** to rerun catalog validation after saving an asset in Godot.

## Manage attributes

Open **Attributes** to browse the linked project's attribute catalog. **New Attribute** registers a generic stat with a permanent numeric ID. Select a row and choose **Edit** to open its details. The ID and internal key are fixed after registration. Use **Save Details** to update the catalog in `combat/attributes/attributes.json`. Godot reads the same entries for generic attribute selectors and modifiers. Reopen the relevant Inspector selection or start a new game session to see saved definitions.

**Accuracy Rating** also opens the **Hit Chance Curve** editor. Choose **Base chance** or **Hit chance ceiling**, then drag a point vertically or enter its percentage. The eleven points correspond to target level gaps +0 through +10. The example uses the current Godot calculation with a level 50 attacker and 69 Accuracy Rating. **Save Curve** writes the two existing Accuracy arrays in `combat/combat_rules.json`. The game reads the saved curve on its next run. Details and curve have separate save actions because they belong to different project files.

Use the attribute row's **Delete** action for unused custom entries. Godot checks saved scenes and resources for attribute references first. The game requires its built-in entries, and deleted custom IDs stay reserved.

## Link the Godot project

1. Import the game project once in its compatible Godot editor. The catalog uses Godot's imported texture and script cache.
2. The Ability Editor detects the project when launched from inside its checkout. To link another checkout, use **File → Link Godot Project** and select its `project.godot`.
3. If Godot is unavailable on `PATH`, use **File → Choose Godot Executable** and select the executable for the project. The app remembers both paths.
4. After saving an ability or effect in Godot, use **File → Refresh Catalog** or **F5** to reload both tables.

The app uses the linked checkout's catalog script to load standalone `AbilityDefinition` and `GameplayEffectDefinition` resources using Godot in headless mode. It reads saved `.tres` and `.res` files and skips test fixtures, addons, and build output. Thumbnails come from the authored **Icon** fields. The Effects tab shows **Asset Tags**.

## Delete definitions

Select one or more rows, right-click the selection and choose **Delete**. After confirmation, Godot checks saved project references. If any file outside the selection still refers to a selected definition, the app lists the references and blocks the deletion. Otherwise it moves the selected definition files to the Windows Recycle Bin and reloads the catalog.

## Run on Windows

Double-click `builds/ability_editor/Ability Editor.exe` when the standalone build is available. To run from source with Python 3.10 or newer, run these commands from the project root in PowerShell.

```powershell
$abilityEditorEnv = Join-Path $env:LOCALAPPDATA 'ability-editor-venv'
python -m venv $abilityEditorEnv
$abilityEditorPython = Join-Path $abilityEditorEnv 'Scripts\python.exe'
& $abilityEditorPython -m pip install -r .\tools\ability_editor\requirements.txt
& $abilityEditorPython .\tools\ability_editor\app.py
```
