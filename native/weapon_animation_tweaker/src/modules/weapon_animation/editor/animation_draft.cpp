// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "animation_draft.hpp"

#ifdef DEBUG_ENABLED

#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

namespace crimson::weapon_animation {
using namespace godot;

namespace {

constexpr double MIN_DURATION = 0.001;
constexpr const char *TRACK_METADATA = "weapon_tweaker_tracks";
constexpr const char *SOCKET_FIELDS[] = { "right_socket_key_times", "left_socket_key_times" };

/// A position or rotation writer already present on the draft.
struct Channels {
    int position = -1; ///< Position track index, or absent.
    int rotation = -1; ///< Rotation track index, or absent.
    int transform = -1; ///< Combined local transform value track, or absent.
};

/// Match typed position and legacy indexed position channels.
bool target_position(const Ref<Animation> &animation, int track, const Array &paths) {
    const NodePath path = animation->track_get_path(track);
    const Animation::TrackType type = animation->track_get_type(track);
    if (type == Animation::TYPE_POSITION_3D) {
        return paths.has(path);
    }
    return type == Animation::TYPE_VALUE && path.get_subname_count() == 1 && path.get_subname(0) == StringName("position") &&
            paths.has(NodePath(String(path).trim_suffix(":position")));
}

/// Move a position path relative to the original midpoint of its authored bounds.
bool reshape_positions(const Ref<Animation> &animation, int track, const Vector3 &factor, const Vector3 &offset) {
    std::vector<std::pair<int, Vector3>> positions;
    const int count = animation->track_get_key_count(track);
    positions.reserve(count);
    AABB bounds;
    for (int index = 0; index < count; ++index) {
        const Variant value = animation->track_get_key_value(track, index);
        if (value.get_type() != Variant::VECTOR3 && value.get_type() != Variant::VECTOR3I) {
            continue;
        }
        const Vector3 position = value;
        if (!position.is_finite()) {
            return false;
        }
        bounds = positions.empty() ? AABB(position, Vector3()) : bounds.expand(position);
        positions.emplace_back(index, position);
    }
    const Vector3 center = bounds.get_center();
    for (const auto &entry : positions) {
        const Vector3 adjusted = center + (entry.second - center) * factor + offset;
        if (!adjusted.is_finite()) {
            return false;
        }
        animation->track_set_key_value(track, entry.first, adjusted);
    }
    return true;
}

/// Move keys in a safe order so later operations keep their original indices.
bool scale_key_times(const Ref<Animation> &animation, int track, double ratio) {
    const int count = animation->track_get_key_count(track);
    std::vector<double> times;
    std::vector<int> moves;
    times.reserve(count);
    moves.reserve(count);
    for (int index = 0; index < count; ++index) {
        const double original = animation->track_get_key_time(track, index);
        const double scaled = original * ratio;
        if (!std::isfinite(scaled)) {
            return false;
        }
        times.push_back(original);
        if (scaled != original) {
            moves.push_back(index);
        }
    }
    std::stable_sort(moves.begin(), moves.end(), [&](int a, int b) {
        return ratio > 1 ? std::abs(times[a]) > std::abs(times[b]) : std::abs(times[a]) < std::abs(times[b]);
    });
    for (int index : moves) {
        animation->track_set_key_time(track, index, times[index] * ratio);
        if (animation->track_get_key_count(track) != count) {
            return false;
        }
    }
    if (animation->track_get_type(track) != Animation::TYPE_BEZIER) {
        return true;
    }
    for (int index = 0; index < count; ++index) {
        Array key = animation->track_get_key_value(track, index);
        const double incoming = double(key[1]) * ratio;
        const double outgoing = double(key[3]) * ratio;
        if (!std::isfinite(incoming) || !std::isfinite(outgoing)) {
            return false;
        }
        key[1] = incoming;
        key[3] = outgoing;
        animation->track_set_key_value(track, index, key);
    }
    return true;
}

/// Keep native Godot markers distinct from Tweaker metadata, retaining their colors.
bool scale_native_markers(const Ref<Animation> &animation, double ratio) {
    const PackedStringArray names = animation->get_marker_names();
    std::vector<double> times;
    std::vector<Color> colors;
    times.reserve(names.size());
    colors.reserve(names.size());
    for (int64_t index = 0; index < names.size(); ++index) {
        const double scaled = animation->get_marker_time(names[index]) * ratio;
        if (!std::isfinite(scaled)) {
            return false;
        }
        times.push_back(scaled);
        colors.push_back(animation->get_marker_color(names[index]));
        animation->remove_marker(names[index]);
    }
    for (int64_t index = 0; index < names.size(); ++index) {
        animation->add_marker(names[index], times[index]);
        animation->set_marker_color(names[index], colors[index]);
    }
    return animation->get_marker_names().size() == names.size();
}

/// Preserve the packed representation of original authored socket samples.
template <class Packed, class Number>
bool scale_socket_samples(const Ref<Animation> &clip, const StringName &field, Packed samples, double ratio) {
    for (int64_t index = 0; index < samples.size(); ++index) {
        const Number scaled = Number(samples[index] * ratio);
        if (!std::isfinite(scaled)) {
            return false;
        }
        samples.set(index, scaled);
    }
    clip->set_meta(field, samples);
    return true;
}

/// Scale one validated marker or notify time while retaining the one-shot sentinel.
bool scale_row_time(Dictionary &row, const StringName &field, double ratio, bool has_sentinel = false) {
    const Variant value = row.get(field, Variant());
    if (value.get_type() != Variant::INT && value.get_type() != Variant::FLOAT) {
        return false;
    }
    const double seconds = value;
    if (has_sentinel && seconds == CrimsonWeaponAnimationTracks::ONE_SHOT) {
        return true;
    }
    const double scaled = seconds * ratio;
    if (seconds < 0 || !std::isfinite(scaled)) {
        return false;
    }
    row[field] = scaled;
    return true;
}

/// Find the nearest existing key within the same tolerance Godot uses for insertion.
int existing_key(const Ref<Animation> &animation, int track, double seconds) {
    const int count = animation->track_get_key_count(track);
    int first = 0;
    int last = count;
    while (first < last) {
        const int middle = first + (last - first) / 2;
        if (animation->track_get_key_time(track, middle) < seconds) {
            first = middle + 1;
        } else {
            last = middle;
        }
    }
    const double before = first > 0 ? animation->track_get_key_time(track, first - 1) : -INFINITY;
    const double after = first < count ? animation->track_get_key_time(track, first) : INFINITY;
    const bool has_before = first > 0 && Math::is_equal_approx(before, seconds);
    const bool has_after = first < count && Math::is_equal_approx(after, seconds);
    if (has_after && (!has_before || after - seconds <= seconds - before)) {
        return first;
    }
    return has_before ? first - 1 : -1;
}

/// Only continuous and writable channels can be edited as pose keys.
bool editable(const Ref<Animation> &animation, int track) {
    return !animation->track_is_compressed(track) &&
            (animation->track_get_type(track) != Animation::TYPE_VALUE ||
                    animation->value_track_get_update_mode(track) == Animation::UPDATE_CONTINUOUS);
}

/// Resolve a single writer per channel and reject ambiguous/global transform edits.
bool resolve_channels(const Ref<Animation> &clip, const NodePath &path, Channels &out) {
    for (int track = 0; track < clip->get_track_count(); ++track) {
        const NodePath candidate = clip->track_get_path(track);
        if (!clip->track_is_enabled(track) || candidate.is_absolute() != path.is_absolute() ||
                candidate.get_concatenated_names() != path.get_concatenated_names()) {
            continue;
        }
        const Animation::TrackType type = clip->track_get_type(track);
        int *writer = nullptr;
        if (candidate == path) {
            if (type == Animation::TYPE_POSITION_3D) {
                writer = &out.position;
            } else if (type == Animation::TYPE_ROTATION_3D) {
                writer = &out.rotation;
            }
        } else if (candidate.get_subname_count() > 0 && (type == Animation::TYPE_VALUE || type == Animation::TYPE_BEZIER)) {
            const String property = candidate.get_subname(0);
            if (property == "position") {
                writer = &out.position;
            } else if (property == "quaternion" || property == "rotation" || property == "rotation_degrees") {
                writer = &out.rotation;
            } else if (property == "transform") {
                writer = &out.transform;
            } else if (property == "basis" || property == "rotation_order" || property.begins_with("global_")) {
                return false;
            }
            if (writer && (candidate.get_subname_count() != 1 || type != Animation::TYPE_VALUE)) {
                return false;
            }
        }
        if (writer) {
            if (*writer >= 0 || !editable(clip, track)) {
                return false;
            }
            *writer = track;
        }
    }
    return out.transform < 0 || (out.position < 0 && out.rotation < 0);
}

/// Write in place when replacing an authored key so its timing and easing survive.
double set_key(const Ref<Animation> &clip, int track, double seconds, const Variant &value) {
    const int index = existing_key(clip, track, seconds);
    if (index >= 0) {
        clip->track_set_key_value(track, index, value);
        return clip->track_get_key_time(track, index);
    }
    clip->track_insert_key(track, seconds, value);
    return seconds;
}

/// Wrap an authored Euler angle to its nearest equivalent around the existing reference.
double nearest_angle(double angle, double reference, double revolution) {
    return angle + std::round((reference - angle) / revolution) * revolution;
}

/// Express a key using the track's original Euler or quaternion representation.
Variant rotation_value(const Ref<Animation> &clip, int track, Quaternion desired, double seconds) {
    if (track < 0) {
        return desired;
    }
    const Animation::TrackType type = clip->track_get_type(track);
    const int exact = existing_key(clip, track, seconds);
    Variant reference;
    if (exact >= 0) {
        reference = clip->track_get_key_value(track, exact);
    } else if (clip->track_get_key_count(track) > 0) {
        reference = type == Animation::TYPE_ROTATION_3D ?
                Variant(clip->rotation_track_interpolate(track, seconds)) : clip->value_track_interpolate(track, seconds);
    }
    if (type == Animation::TYPE_VALUE) {
        const StringName property = clip->track_get_path(track).get_subname(0);
        if (property != StringName("quaternion")) {
            const bool degrees = property == StringName("rotation_degrees");
            const double revolution = degrees ? 360.0 : Math::TAU;
            Vector3 angles = desired.get_euler() * (degrees ? 180.0 / Math::PI : 1.0);
            if (reference.get_type() == Variant::VECTOR3 && Vector3(reference).is_finite()) {
                const Vector3 previous = reference;
                for (int component = 0; component < 3; ++component) {
                    angles[component] = nearest_angle(angles[component], previous[component], revolution);
                }
            }
            return angles;
        }
    }
    if (reference.get_type() == Variant::QUATERNION && desired.dot(Quaternion(reference)) < 0) {
        desired = -desired;
    }
    return desired;
}

/// Keep imported socket timeline dots synchronized when inserting a new authored time.
template <class Packed, class Number>
void append_socket_sample(const Ref<Animation> &clip, const StringName &field, Packed samples, double seconds) {
    for (int64_t index = 0; index < samples.size(); ++index) {
        if (Math::is_equal_approx(double(samples[index]), seconds)) {
            return;
        }
    }
    samples.append(Number(seconds));
    samples.sort();
    clip->set_meta(field, samples);
}

/// Record a sample only when the clip's socket metadata is already present.
void add_socket_sample(const Ref<Animation> &clip, const NodePath &path, double seconds) {
    const StringName node_name = path.get_name(path.get_name_count() - 1);
    StringName field;
    if (node_name == StringName("WeaponControl")) {
        field = SOCKET_FIELDS[0];
    } else if (node_name == StringName("LeftWeaponControl")) {
        field = SOCKET_FIELDS[1];
    } else {
        return;
    }
    if (!clip->has_meta(field)) {
        return;
    }
    const Variant value = clip->get_meta(field);
    if (value.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
        append_socket_sample<PackedFloat32Array, float>(clip, field, value, seconds);
    } else if (value.get_type() == Variant::PACKED_FLOAT64_ARRAY) {
        append_socket_sample<PackedFloat64Array, double>(clip, field, value, seconds);
    }
}

} // namespace

Ref<CrimsonWeaponAnimationTracks> retime_tracks(const Ref<CrimsonWeaponAnimationTracks> &source, double ratio) {
    if (source.is_null() || !std::isfinite(ratio) || ratio <= 0) {
        return {};
    }
    Ref<CrimsonWeaponAnimationTracks> result;
    result.instantiate();
    TypedArray<Dictionary> markers = source->get_markers();
    for (int64_t index = 0; index < markers.size(); ++index) {
        Dictionary row = markers[index];
        if (!scale_row_time(row, "time", ratio)) {
            return {};
        }
    }
    TypedArray<Dictionary> lanes = source->get_notify_tracks();
    for (int64_t index = 0; index < lanes.size(); ++index) {
        const Array entries = Dictionary(lanes[index]).get("notifies", Array());
        for (int64_t entry = 0; entry < entries.size(); ++entry) {
            Dictionary row = entries[entry];
            if (!scale_row_time(row, "time", ratio) || !scale_row_time(row, "end_time", ratio, true)) {
                return {};
            }
        }
    }
    result->set_version(source->get_version());
    result->set_markers(markers);
    result->set_notify_tracks(lanes);
    result->set_curve_tracks(source->get_curve_tracks());
    return result;
}

Ref<Animation> tweak_motion(const Ref<Animation> &source, const Array &target_paths,
        double vertical_offset, double width, double height, double depth, double camera_offset, double duration) {
    if (source.is_null() || !std::isfinite(source->get_length()) || source->get_length() < MIN_DURATION ||
            !std::isfinite(duration) || duration < MIN_DURATION) {
        return {};
    }
    const Vector3 scale(width, height, depth);
    const Vector3 offset(0, vertical_offset, camera_offset);
    const double ratio = duration / source->get_length();
    if (!scale.is_finite() || !offset.is_finite() || std::min({width, height, depth}) < 0 ||
            !std::isfinite(ratio) || ratio <= 0) {
        return {};
    }
    const bool retime = duration != source->get_length();
    const bool reshape = scale != Vector3(1, 1, 1) || offset != Vector3();
    Ref<Animation> draft = source->duplicate(true);
    for (int track = 0; track < draft->get_track_count(); ++track) {
        const bool targeted = reshape && target_position(draft, track, target_paths);
        if (((retime || targeted) && draft->track_is_compressed(track)) ||
                (targeted && !reshape_positions(draft, track, scale, offset)) ||
                (retime && !scale_key_times(draft, track, ratio))) {
            return {};
        }
    }
    if (!retime) {
        return draft;
    }
    const float new_step = source->get_step() * ratio;
    if (!std::isfinite(new_step) || !scale_native_markers(draft, ratio)) {
        return {};
    }
    for (const StringName field : SOCKET_FIELDS) {
        if (!draft->has_meta(field)) {
            continue;
        }
        const Variant samples = draft->get_meta(field);
        if ((samples.get_type() == Variant::PACKED_FLOAT32_ARRAY &&
                    !scale_socket_samples<PackedFloat32Array, float>(draft, field, samples, ratio)) ||
                (samples.get_type() == Variant::PACKED_FLOAT64_ARRAY &&
                    !scale_socket_samples<PackedFloat64Array, double>(draft, field, samples, ratio))) {
            return {};
        }
    }
    draft->set_length(duration);
    draft->set_step(new_step);
    if (source->has_meta(TRACK_METADATA)) {
        const Ref<CrimsonWeaponAnimationTracks> scaled = retime_tracks(CrimsonWeaponAnimationTracks::from_animation(source), ratio);
        if (scaled.is_null() || !scaled->write_to(draft)) {
            return {};
        }
    }
    return draft;
}

bool write_pose_key(const Ref<Animation> &draft, const NodePath &path, double seconds, const Transform3D &pose) {
    if (draft.is_null() || path.get_name_count() == 0 || !std::isfinite(draft->get_length()) ||
            !std::isfinite(seconds) || seconds < 0 || seconds > draft->get_length() || !pose.is_finite() ||
            Math::is_zero_approx(pose.basis.determinant())) {
        return false;
    }
    if (path.get_subname_count() > 0) {
        const int track = draft->find_track(path, Animation::TYPE_VALUE);
        if (path.get_subname_count() != 1 || track < 0 || !draft->track_is_enabled(track) || !editable(draft, track) ||
                draft->track_get_key_count(track) == 0 || draft->track_get_key_value(track, 0).get_type() != Variant::TRANSFORM3D) {
            return false;
        }
        set_key(draft, track, seconds, pose);
        return true;
    }
    Channels channels;
    if (!resolve_channels(draft, path, channels)) {
        return false;
    }
    if (channels.transform >= 0) {
        const double time = set_key(draft, channels.transform, seconds, pose);
        add_socket_sample(draft, path, time);
        return true;
    }
    const Quaternion rotation = pose.basis.get_rotation_quaternion();
    if (!rotation.is_finite() || !rotation.is_normalized()) {
        return false;
    }
    const Variant stored_rotation = rotation_value(draft, channels.rotation, rotation, seconds);
    if (channels.position < 0) {
        channels.position = draft->add_track(Animation::TYPE_POSITION_3D);
        draft->track_set_path(channels.position, path);
    }
    if (channels.rotation < 0) {
        channels.rotation = draft->add_track(Animation::TYPE_ROTATION_3D);
        draft->track_set_path(channels.rotation, path);
    }
    const double position_time = set_key(draft, channels.position, seconds, pose.origin);
    const double rotation_time = set_key(draft, channels.rotation, seconds, stored_rotation);
    add_socket_sample(draft, path, position_time);
    if (rotation_time != position_time) {
        add_socket_sample(draft, path, rotation_time);
    }
    return true;
}

} // namespace crimson::weapon_animation

#endif
