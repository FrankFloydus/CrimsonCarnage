// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#include <godot_cpp/classes/animation_player.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace crimson::weapon_animation {

/// Stores a clip sequence and its marker-based transitions as a reusable resource.
class CrimsonWeaponAnimationCombo final : public godot::Resource {
    GDCLASS(CrimsonWeaponAnimationCombo, godot::Resource)

public:
    /// Read a detached draft from a native or legacy combo resource.
    static godot::Ref<CrimsonWeaponAnimationCombo> from_resource(const godot::Ref<godot::Resource> &resource);
    /// Duplicate the authored clip sequence and all per-join fields.
    godot::Ref<CrimsonWeaponAnimationCombo> copy() const;
    /// Return the user-facing combo name.
    godot::String get_display_name() const;
    /// Set the user-facing combo name.
    void set_display_name(const godot::String &name);
    /// Return a detached ordered array of qualified clip keys.
    godot::TypedArray<godot::StringName> get_clip_keys() const;
    /// Restore the saved key sequence. This is the serialized property setter.
    void set_clip_keys(const godot::TypedArray<godot::StringName> &keys);
    /// Return detached serialized per-step transition dictionaries.
    godot::TypedArray<godot::Dictionary> get_joins() const;
    /// Restore serialized transitions, including any disabled closing join.
    void set_joins(const godot::TypedArray<godot::Dictionary> &new_joins);
    /// Return whether to join the final clip back to the opener.
    bool get_loop() const;
    /// Enable the final transition without discarding its stored settings when disabled.
    void set_loop(bool enabled);
    /// Edit the clip order, preserving matching pairs of adjacent clips.
    void set_clips(const godot::TypedArray<godot::StringName> &keys);
    /// Count the active authored join slots.
    int64_t get_join_count() const;
    /// Return a detached transition row with defaults filled in.
    godot::Dictionary get_join(int64_t index) const;
    /// Set one transition. Named markers take precedence over explicit seconds.
    void set_join(int64_t index, const godot::StringName &exit_marker, const godot::StringName &entry_marker,
            double blend_duration, double exit_time = -1.0, double entry_time = -1.0);
    /// Resolve two clips and their authored endpoints or return an error dictionary.
    godot::Dictionary resolve_join(godot::AnimationPlayer *player, int64_t index) const;
    /// Return an empty string for a valid sequence or describe its first playback problem.
    godot::String validate(godot::AnimationPlayer *player) const;

protected:
    /// Register the resource properties and native workflow methods with Godot.
    static void _bind_methods();

private:
    /// Name shown in the native editor.
    godot::String display_name;
    /// Clip keys accepted by the target AnimationPlayer.
    godot::TypedArray<godot::StringName> clip_keys;
    /// Transitions stored by outgoing step, including the optional closing join.
    godot::TypedArray<godot::Dictionary> joins;
    /// Whether to include the closing join when playing or validating the sequence.
    bool loop = true;
};

} // namespace crimson::weapon_animation
