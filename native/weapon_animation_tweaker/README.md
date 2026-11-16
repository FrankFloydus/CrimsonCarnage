<!-- Copyright Francesco Di Blasi 2026 - All Rights Reserved -->

# Native Weapon Animation Tweaker

Open a player scene with an `AnimationPlayer`, then choose **Project → Tools → Weapon Animation (Native)**. The addon registers the clip, track, and combo resource classes used by the window. Its editor and runtime libraries load independently of Crimson Framework.

[Authoring guide](src/modules/weapon_animation/editor/README.md) · [Clip and combo resources](src/modules/weapon_animation/README.md)

## Build and install on Windows

Use a Windows x86-64 MSVC and CMake toolchain with Python. Point `GODOT_CPP_DIR` at a godot-cpp source checkout that supplies the pinned Godot 4.7 API. This checkout was verified at `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`.

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

Restart Godot after replacing the installed DLLs. When upgrading from the initial Framework build that bundled the native Tweaker, install the Framework DLLs with the standalone addon so each resource class has one registration.

## Test the standalone addon

Copy the installed addon and `tests/runtime.gd` into an isolated Godot project, import the project, then run the script with Godot's headless console. The fixture covers native and legacy track data, weighted curve sampling, notify order, and combo saves.

For a fresh headless project, start the editor with `--headless --editor --path <project> --quit-after 250` to populate the extension cache. The tested Godot builds can crash when a cold `--import` discovers a new native extension and immediately exits.
