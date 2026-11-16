// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "register_weapon_animation.hpp"

#include "animation_clip.hpp"
#include "animation_combo.hpp"
#include "animation_tracks.hpp"

#include <godot_cpp/core/class_db.hpp>

namespace crimson::weapon_animation {

void register_types(godot::ModuleInitializationLevel level) {
    if (level == godot::MODULE_INITIALIZATION_LEVEL_SCENE) {
        GDREGISTER_CLASS(CrimsonWeaponAnimationClip);
        GDREGISTER_CLASS(CrimsonWeaponAnimationCombo);
        GDREGISTER_CLASS(CrimsonWeaponAnimationTracks);
    }
}

void unregister_types(godot::ModuleInitializationLevel) {
    // Godot releases the runtime bindings at extension shutdown.
}

} // namespace crimson::weapon_animation
