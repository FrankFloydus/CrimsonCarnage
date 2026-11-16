// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#include <godot_cpp/godot.hpp>

namespace crimson::weapon_animation {

/// Register runtime weapon animation classes during scene initialization.
void register_types(godot::ModuleInitializationLevel level);
/// Complete runtime weapon animation shutdown.
void unregister_types(godot::ModuleInitializationLevel level);

} // namespace crimson::weapon_animation
