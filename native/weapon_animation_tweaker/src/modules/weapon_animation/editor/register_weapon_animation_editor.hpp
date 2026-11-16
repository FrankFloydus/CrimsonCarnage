// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#include <godot_cpp/godot.hpp>

namespace crimson::weapon_animation {

/// Register the native animation authoring workspace when running in the editor.
void register_weapon_animation_editor(godot::ModuleInitializationLevel level);
/// Remove the workspace's editor plugin before tearing down native bindings.
void unregister_weapon_animation_editor(godot::ModuleInitializationLevel level);

}
