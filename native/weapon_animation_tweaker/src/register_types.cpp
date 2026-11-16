// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "modules/weapon_animation/editor/register_weapon_animation_editor.hpp"
#include "modules/weapon_animation/register_weapon_animation.hpp"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

namespace {

/// Register standalone runtime resources before the editor tool.
void initialize_tweaker(godot::ModuleInitializationLevel level) {
    crimson::weapon_animation::register_types(level);
    crimson::weapon_animation::register_weapon_animation_editor(level);
}

/// Release the editor tool before its resource bindings.
void uninitialize_tweaker(godot::ModuleInitializationLevel level) {
    crimson::weapon_animation::unregister_weapon_animation_editor(level);
    crimson::weapon_animation::unregister_types(level);
}

} // namespace

/// Initialize the independently installed Weapon Animation Tweaker.
extern "C" GDExtensionBool GDE_EXPORT crimson_weapon_animation_init(
        GDExtensionInterfaceGetProcAddress get_proc_address,
        GDExtensionClassLibraryPtr library,
        GDExtensionInitialization *initialization) {
    godot::GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_tweaker);
    init.register_terminator(uninitialize_tweaker);
    init.set_minimum_library_initialization_level(godot::MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
