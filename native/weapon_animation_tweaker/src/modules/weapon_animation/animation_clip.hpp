// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/classes/animation_player.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <vector>

namespace crimson::weapon_animation {

/// Owns a detached runtime snapshot of one Animation's Tweaker tracks.
class CrimsonWeaponAnimationClip final : public godot::RefCounted {
    GDCLASS(CrimsonWeaponAnimationClip, godot::RefCounted)

public:
    /// Processing order for coincident events.
    enum EventType {
        STATE_ENDED, ///< A notify state ends.
        STATE_STARTED, ///< A notify state starts.
        NOTIFY, ///< A one-shot notify fires.
        MARKER, ///< A named Tweaker marker is crossed.
    };

    /// Snapshot one animation, accepting saved native and legacy track resources.
    static godot::Ref<CrimsonWeaponAnimationClip> from_animation(const godot::Ref<godot::Animation> &animation);
    /// Snapshot an animation by the qualified key used by AnimationPlayer.play.
    static godot::Ref<CrimsonWeaponAnimationClip> from_player(godot::AnimationPlayer *player, const godot::StringName &key);
    /// Report the source duration in seconds.
    double get_duration() const;
    /// List the curve names in their saved order.
    godot::PackedStringArray get_curve_names() const;
    /// Return detached curve attributes, or an empty dictionary for an unknown curve.
    godot::Dictionary get_curve_info(const godot::StringName &name) const;
    /// Return detached keys with normalized phase, seconds, and effective slopes.
    godot::TypedArray<godot::Dictionary> get_curve_keys(const godot::StringName &name) const;
    /// Evaluate a curve at clip seconds, or return the fallback for an unavailable curve.
    double sample_curve(const godot::StringName &name, double seconds, double fallback = 0.0) const;
    /// Evaluate a curve at normalized clip phase clamped to the clip.
    double sample_curve_normalized(const godot::StringName &name, double phase, double fallback = 0.0) const;
    /// Return detached Tweaker markers in their saved order.
    godot::TypedArray<godot::Dictionary> get_markers() const;
    /// Find a detached Tweaker marker by name, independent of Godot's native clip markers.
    godot::Dictionary get_marker(const godot::StringName &name) const;
    /// Find a Tweaker marker time in seconds or return the supplied fallback.
    double get_marker_time(const godot::StringName &name, double fallback = -1.0) const;
    /// List notify lane names in their saved order.
    godot::PackedStringArray get_notify_track_names() const;
    /// Return detached one-shot records, optionally filtered by exact name.
    godot::TypedArray<godot::Dictionary> get_notifies(const godot::StringName &name = {}) const;
    /// Return detached state records, optionally filtered by exact name.
    godot::TypedArray<godot::Dictionary> get_notify_states(const godot::StringName &name = {}) const;
    /// Return states active at seconds, including their start and excluding their end.
    godot::TypedArray<godot::Dictionary> get_active_notify_states(double seconds, const godot::StringName &kind = {}) const;
    /// Read events over a forward playback span, including the end and optionally the start.
    godot::TypedArray<godot::Dictionary> get_events_crossed(double from_seconds, double to_seconds, bool include_start = false) const;
    /// Read the tail and head events crossed by one wrap in a loop region.
    godot::TypedArray<godot::Dictionary> get_loop_events_crossed(double from_seconds, double to_seconds,
            double loop_start = 0.0, double loop_end = -1.0) const;

protected:
    /// Register snapshot constructors and read methods with Godot.
    static void _bind_methods();

private:
    friend class CrimsonWeaponAnimationTracks;
    /// Parse and validate all stored track rows before publishing the snapshot.
    bool read_tracks(const godot::Variant &stored, double clip_length);
    /// Return a detached range of previously sorted events.
    godot::TypedArray<godot::Dictionary> events_in_range(double start, double end, bool include_start) const;

    /// Duration in seconds. A newly instantiated empty object has zero duration.
    double duration = 0.0;
    /// Ordered snapshots of named curves, storing detached rich-key records.
    godot::TypedArray<godot::Dictionary> curves;
    /// Lookup from unique curve name to its ordered snapshot index.
    godot::Dictionary curve_indexes;
    /// Ordered marker table. Keys are also indexed for lookups.
    godot::TypedArray<godot::Dictionary> markers;
    /// Lookup from unique marker name to its detached row.
    godot::Dictionary markers_by_name;
    /// Lane names in authoring order.
    godot::PackedStringArray notify_track_names;
    /// Detached one-shot rows with lane and entry identity.
    godot::TypedArray<godot::Dictionary> notifies;
    /// Detached state rows with lane and entry identity.
    godot::TypedArray<godot::Dictionary> states;
    /// Preindexed events ordered by time, type, then source order.
    std::vector<godot::Dictionary> events;
    /// Numeric search keys parallel to events.
    std::vector<double> event_times;
};

} // namespace crimson::weapon_animation

VARIANT_ENUM_CAST(crimson::weapon_animation::CrimsonWeaponAnimationClip::EventType)
