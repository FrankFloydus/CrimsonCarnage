// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/typed_array.hpp>

namespace crimson::weapon_animation {

/// Stores editable marker, notify and curve rows on a Godot Animation.
class CrimsonWeaponAnimationTracks final : public godot::Resource {
    GDCLASS(CrimsonWeaponAnimationTracks, godot::Resource)

public:
    /// Storage version of the existing Tweaker clip metadata.
    static constexpr int64_t SCHEMA_VERSION = 1;
    /// End-time sentinel for an instantaneous notify.
    static constexpr double ONE_SHOT = -1.0;

    /// Return an independent draft from a native or compatible legacy clip.
    static godot::Ref<CrimsonWeaponAnimationTracks> from_animation(const godot::Ref<godot::Animation> &animation);
    /// Save validated tracks on an animation without touching its native markers or motion keys.
    bool write_to(const godot::Ref<godot::Animation> &animation) const;
    /// Verify all rows against a clip duration in seconds.
    bool is_valid(double duration) const;
    /// Return the serialized storage version.
    int64_t get_version() const;
    /// Restore the storage version for validation on read.
    void set_version(int64_t version);
    /// Return detached named-marker rows.
    godot::TypedArray<godot::Dictionary> get_markers() const;
    /// Replace all named-marker rows in authored order.
    void set_markers(const godot::TypedArray<godot::Dictionary> &rows);
    /// Return detached notify lanes, with each lane owning an array of notifies.
    godot::TypedArray<godot::Dictionary> get_notify_tracks() const;
    /// Replace all notify lanes in authored order.
    void set_notify_tracks(const godot::TypedArray<godot::Dictionary> &rows);
    /// Return detached float curve lanes, including their normalized key records.
    godot::TypedArray<godot::Dictionary> get_curve_tracks() const;
    /// Replace all float curve lanes in authored order.
    void set_curve_tracks(const godot::TypedArray<godot::Dictionary> &rows);

protected:
    /// Register storage properties and track operations with Godot.
    static void _bind_methods();

private:
    /// Saved version. Invalid or newer versions are rejected by validation.
    int64_t version = SCHEMA_VERSION;
    /// Ordered marker records with name, time and optional color.
    godot::TypedArray<godot::Dictionary> markers;
    /// Ordered notify lanes with one-shot or state records.
    godot::TypedArray<godot::Dictionary> notify_tracks;
    /// Ordered float curve lanes in normalized clip time.
    godot::TypedArray<godot::Dictionary> curve_tracks;
};

} // namespace crimson::weapon_animation
