// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#ifdef DEBUG_ENABLED

#include "modules/weapon_animation/animation_tracks.hpp"

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace crimson::weapon_animation {

/// Duplicate a clip and reshape selected position channels around their bounds center.
/// Retime all keys, markers and track metadata to the requested duration in seconds.
/// Return empty if any channel or stored timestamp cannot be retained.
godot::Ref<godot::Animation> tweak_motion(const godot::Ref<godot::Animation> &source,
        const godot::Array &target_paths, double vertical_offset, double width, double height,
        double depth, double camera_offset, double duration);

/// Produce independent track data with marker and notify times scaled by a positive ratio.
/// Curve keys are stored in normalized time and retain their positions and tangents.
godot::Ref<CrimsonWeaponAnimationTracks> retime_tracks(const godot::Ref<CrimsonWeaponAnimationTracks> &source,
        double ratio);

/// Set local position and rotation on the draft, retaining existing channel representations.
/// Missing channels may be created for node targets, such as a previously unkeyed mount.
/// A property path can target an existing continuous Transform3D value track.
bool write_pose_key(const godot::Ref<godot::Animation> &draft, const godot::NodePath &path,
        double seconds, const godot::Transform3D &pose);

} // namespace crimson::weapon_animation

#endif
