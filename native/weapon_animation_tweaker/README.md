<!-- Copyright Francesco Di Blasi 2026 - All Rights Reserved -->

# Native Weapon Animation Tweaker

Open Carnage's [player scene](../../scenes/player/player.tscn), select its `AnimationPlayer`, and choose **Project → Tools → Weapon Animation (Native)**. The saved scene has a trackless `sword/idle` placeholder. Use **Import Clips** to add Viewer clips with first-person pose tracks. **Play Scene** runs the configured Playground.

Carnage installs the native [GDExtension addon](../../addons/weapon_animation_native/weapon_animation_tweaker.gdextension). It registers the editor menu and the runtime clip, track, and combo classes independently of Crimson Framework. The original GDScript [Weapon Animation Tweaker](../../addons/weapon_animation_tweaker/plugin.cfg) is also enabled and has its own editor dock. Its resource scripts keep previously authored files loadable.

[Authoring guide](src/modules/weapon_animation/editor/README.md) · [Runtime clip API](../../docs/weapon_animation_clip_api.md) · [Clip and combo resources](src/modules/weapon_animation/README.md)

## Build and install on Windows

Use a Windows x86-64 MSVC and CMake toolchain with Python. Run the commands from this directory. Point `GODOT_CPP_DIR` at a godot-cpp source checkout that supplies the pinned Godot 4.7 API. This checkout was verified at `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`.

Build each target in its own build directory. Install both into the same addon directory. The debug target supplies the editor window. The release target keeps native animation resources readable in exported games.

```powershell
$sdk = 'C:/path/to/godot-cpp'
$addon = '../../addons/weapon_animation_native'
foreach ($target in @('template_debug', 'template_release')) {
    $buildDir = Join-Path $env:TEMP "CrimsonTweaker-$target"
    cmake -S . -B $buildDir -A x64 -DGODOT_CPP_DIR="$sdk" -DGODOTCPP_TARGET="$target"
    cmake --build $buildDir --config Release
    cmake --install $buildDir --config Release --prefix "$addon"
}
```

Restart Godot after replacing the installed DLLs. The initial Framework build bundled the native Tweaker. Upgrading a checkout from that historical build also calls for the current Framework DLLs, which no longer register the Tweaker classes.

## Test the standalone addon

Copy the installed addon and the [runtime fixture](tests/runtime.gd) into an isolated Godot project, import the project, then run the script with Godot's headless console. The fixture covers native and legacy track data, weighted curve sampling, notify order, and combo saves.

For a fresh headless project, start the editor with `--headless --editor --path <project> --quit-after 250` to populate the extension cache. The tested Godot builds can crash when a cold `--import` discovers a new native extension and immediately exits.
