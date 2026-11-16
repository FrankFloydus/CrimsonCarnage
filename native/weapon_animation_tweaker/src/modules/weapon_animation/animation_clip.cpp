// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "animation_clip.hpp"

#include "animation_tracks.hpp"

#include <godot_cpp/classes/curve.hpp>
#include <godot_cpp/core/math.hpp>

#include <algorithm>
#include <cmath>
#include <iterator>

namespace crimson::weapon_animation {
namespace {

using namespace godot;

/// Serialized interpolation flags shared with legacy rich curves.
enum CurveMode { CONSTANT, LINEAR, AUTO, BREAK, LEGACY };

/// Read a named property from versioned storage without depending on its script class.
Variant read_field(const Variant &value, const StringName &name) {
    if (value.get_type() == Variant::DICTIONARY) {
        return Dictionary(value).get(name, Variant());
    }
    if (value.get_type() == Variant::OBJECT) {
        Object *object = value;
        if (Object::cast_to<Resource>(object)) {
            return object->get(name);
        }
    }
    return {};
}

/// Check whether a saved value can represent plain text or an interned name.
bool is_text(const Variant &value) {
    return value.get_type() == Variant::STRING || value.get_type() == Variant::STRING_NAME;
}

/// Return whether text contains a non-space character.
bool is_named(const Variant &value) {
    return is_text(value) && !String(value).strip_edges().is_empty();
}

/// Check an encoded numeric field without coercing text to zero.
bool is_number(const Variant &value) {
    return (value.get_type() == Variant::INT || value.get_type() == Variant::FLOAT) &&
           std::isfinite(double(value));
}

/// Validate finite seconds and tolerate the text resource representation of a clip endpoint.
bool is_clip_time(const Variant &value, double length) {
    if (!is_number(value)) {
        return false;
    }
    const double time = value;
    return time >= 0.0 && (time <= length || Math::is_equal_approx(time, length));
}

/// Validate an optional authored RGBA color before returning records to a reader.
bool validate_color(const Dictionary &row) {
    if (!row.has("color")) {
        return true;
    }
    const Variant value = row["color"];
    if (value.get_type() != Variant::COLOR) {
        return false;
    }
    const Color color = value;
    return std::isfinite(color.r) && std::isfinite(color.g) && std::isfinite(color.b) && std::isfinite(color.a);
}

/// Copy optional color metadata to a detached result record.
void copy_color(const Dictionary &source, Dictionary &target) {
    if (source.has("color")) {
        target["color"] = source["color"];
    }
}

/// Normalize a Godot Curve point to the legacy rich-curve shape.
Dictionary encode_curve_point(const Ref<Curve> &curve, int64_t index) {
    const Vector2 point = curve->get_point_position(index);
    Dictionary row;
    row["phase"] = point.x;
    row["value"] = point.y;
    row["mode"] = LEGACY;
    row["in_slope"] = curve->get_point_left_tangent(index);
    row["out_slope"] = curve->get_point_right_tangent(index);
    row["in_weight"] = 0.0;
    row["out_weight"] = 0.0;
    row["weighted_in"] = false;
    row["weighted_out"] = false;
    row["in_linear"] = curve->get_point_left_mode(index) == Curve::TANGENT_LINEAR;
    row["out_linear"] = curve->get_point_right_mode(index) == Curve::TANGENT_LINEAR;
    return row;
}

/// Check a complete key record and its ordering relative to the preceding key.
bool validate_curve_key(const Dictionary &row, double previous_phase) {
    if (!is_number(row.get("phase", Variant())) || !is_number(row.get("value", Variant())) ||
            row.get("mode", Variant()).get_type() != Variant::INT) {
        return false;
    }
    const double phase = row["phase"];
    const double value = row["value"];
    const int64_t mode = row["mode"];
    if (phase <= previous_phase || phase < 0.0 || phase > 1.0 ||
            !std::isfinite(static_cast<real_t>(value)) || mode < CONSTANT || mode > LEGACY) {
        return false;
    }
    return is_number(row.get("in_slope", Variant())) && is_number(row.get("out_slope", Variant())) &&
           is_number(row.get("in_weight", Variant())) && double(row["in_weight"]) >= 0.0 &&
           is_number(row.get("out_weight", Variant())) && double(row["out_weight"]) >= 0.0 &&
           row.get("weighted_in", Variant()).get_type() == Variant::BOOL &&
           row.get("weighted_out", Variant()).get_type() == Variant::BOOL &&
           (mode != LEGACY || (row.get("in_linear", Variant()).get_type() == Variant::BOOL &&
                                      row.get("out_linear", Variant()).get_type() == Variant::BOOL));
}

/// Copy compatible normalized keys from saved native Curve or legacy rich records.
bool read_curve_keys(const Variant &stored, TypedArray<Dictionary> &keys) {
    Object *object = stored.get_type() == Variant::OBJECT ? static_cast<Object *>(stored) : nullptr;
    if (Curve *native = Object::cast_to<Curve>(object)) {
        const Ref<Curve> curve(native);
        if (curve->get_min_domain() != 0.0 || curve->get_max_domain() != 1.0) {
            return false;
        }
        bool all_linear = true;
        for (int64_t index = 0; index < curve->get_point_count(); ++index) {
            const Dictionary row = encode_curve_point(curve, index);
            all_linear = all_linear && (index == 0 || bool(row["in_linear"])) &&
                         (index + 1 == curve->get_point_count() || bool(row["out_linear"]));
            keys.push_back(row);
        }
        if (all_linear) {
            for (int64_t index = 0; index < keys.size(); ++index) {
                Dictionary row = keys[index];
                row["mode"] = LINEAR;
                row["in_slope"] = 0.0;
                row["out_slope"] = 0.0;
                row.erase("in_linear");
                row.erase("out_linear");
            }
        }
    } else {
        const Variant encoded = stored.get_type() == Variant::ARRAY ? stored : read_field(stored, "keys");
        if (encoded.get_type() != Variant::ARRAY) {
            return false;
        }
        for (const Variant &key : Array(encoded)) {
            if (key.get_type() != Variant::DICTIONARY) {
                return false;
            }
            keys.push_back(Dictionary(key).duplicate(true));
        }
    }
    double previous = -1.0;
    for (const Variant &key : keys) {
        const Dictionary row = key;
        if (!validate_curve_key(row, previous)) {
            return false;
        }
        previous = row["phase"];
    }
    return true;
}

/// Compute a tangent slope over two keys with distinct times.
double secant(const Dictionary &left, const Dictionary &right) {
    return (double(right["value"]) - double(left["value"])) / (double(right["phase"]) - double(left["phase"]));
}

/// Derive the actual slope when the mode links a tangent to neighboring keys.
double key_slope(const Array &keys, int64_t index, bool incoming) {
    const Dictionary key = keys[index];
    const int64_t neighbor = index + (incoming ? -1 : 1);
    const int64_t mode = key["mode"];
    if (mode == AUTO) {
        return index > 0 && index + 1 < keys.size() ? secant(keys[index - 1], keys[index + 1]) : 0.0;
    }
    const bool has_neighbor = neighbor >= 0 && neighbor < keys.size();
    if (mode == LINEAR) {
        return has_neighbor ? secant(key, keys[neighbor]) : 0.0;
    }
    if (mode == LEGACY && has_neighbor && bool(key[incoming ? "in_linear" : "out_linear"])) {
        return secant(key, keys[neighbor]);
    }
    return key[incoming ? "in_slope" : "out_slope"];
}

/// Convert an unweighted or length-weighted tangent to a signed offset along time.
double handle_time(const Dictionary &key, const Dictionary &neighbor, bool incoming, double slope) {
    if (bool(key[incoming ? "weighted_in" : "weighted_out"])) {
        const double weight = key[incoming ? "in_weight" : "out_weight"];
        return (incoming ? -weight : weight) / std::hypot(1.0, slope);
    }
    return (double(neighbor["phase"]) - double(key["phase"])) / 3.0;
}

/// Evaluate a cubic Bezier component.
double cubic(double a, double b, double c, double d, double parameter) {
    const double rest = 1.0 - parameter;
    return a * rest * rest * rest + 3.0 * b * rest * rest * parameter +
           3.0 * c * rest * parameter * parameter + d * parameter * parameter * parameter;
}

/// Invert time within one monotonic span of a weighted tangent segment.
double solve_time(double target, double x1, double x2, double lower, double upper, bool increasing) {
    for (int iteration = 0; iteration < 48 && upper - lower > 1e-12; ++iteration) {
        const double middle = (lower + upper) * 0.5;
        const double error = cubic(0.0, x1, x2, 1.0, middle) - target;
        if (error == 0.0) {
            return middle;
        }
        if ((error < 0.0) == increasing) {
            lower = middle;
        } else {
            upper = middle;
        }
    }
    return (lower + upper) * 0.5;
}

/// Series of stationary-time splits for long handles, using the largest solution on a folded segment.
double weighted_parameter(double target, double x1, double x2) {
    if (x1 >= 0.0 && x1 <= 1.0 && x2 >= 0.0 && x2 <= 1.0) {
        return solve_time(target, x1, x2, 0.0, 1.0, true);
    }
    std::vector<double> cuts{0.0, 1.0};
    const auto add_cut = [&](double value) {
        if (value > 0.0 && value < 1.0) {
            cuts.push_back(value);
        }
    };
    const double a = 1.0 + 3.0 * (x1 - x2);
    const double b = 2.0 * (x2 - 2.0 * x1);
    if (std::abs(a) <= 1e-12) {
        if (std::abs(b) > 1e-12) {
            add_cut(-x1 / b);
        }
    } else {
        const double discriminant = b * b - 4.0 * a * x1;
        if (discriminant >= 0.0) {
            const double numerator = -0.5 * (b + std::copysign(std::sqrt(discriminant), b));
            add_cut(numerator / a);
            if (numerator != 0.0) {
                add_cut(x1 / numerator);
            }
        }
    }
    std::sort(cuts.begin(), cuts.end());
    for (size_t i = cuts.size() - 1; i > 0; --i) {
        const double start = cubic(0.0, x1, x2, 1.0, cuts[i - 1]);
        const double end = cubic(0.0, x1, x2, 1.0, cuts[i]);
        if (target >= std::min(start, end) && target <= std::max(start, end)) {
            return solve_time(target, x1, x2, cuts[i - 1], cuts[i], start <= end);
        }
    }
    return target;
}

/// Evaluate a validated normalized key array using the owning key's interpolation mode.
double sample_keys(const Array &keys, double phase) {
    int64_t lower = 0;
    int64_t upper = keys.size();
    while (lower < upper) {
        const int64_t middle = lower + (upper - lower) / 2;
        if (double(Dictionary(keys[middle])["phase"]) < phase) {
            lower = middle + 1;
        } else {
            upper = middle;
        }
    }
    const int64_t right_index = lower;
    if (right_index == keys.size()) {
        return Dictionary(keys[keys.size() - 1])["value"];
    }
    const Dictionary right = keys[right_index];
    const double right_value = right["value"];
    const double right_phase = right["phase"];
    if (right_index == 0 || phase == right_phase) {
        return right_value;
    }
    const int64_t left_index = right_index - 1;
    const Dictionary left = keys[left_index];
    const double left_value = left["value"];
    const double left_phase = left["phase"];
    const double span = right_phase - left_phase;
    const int64_t mode = left["mode"];
    if (mode == CONSTANT) {
        return left_value;
    }
    double parameter = (phase - left_phase) / span;
    if (mode == LINEAR) {
        return left_value + (right_value - left_value) * parameter;
    }
    if (mode == LEGACY && Math::is_zero_approx(span)) {
        return right_value;
    }
    const double outgoing = key_slope(keys, left_index, false);
    const double incoming = key_slope(keys, right_index, true);
    const double outgoing_time = handle_time(left, right, false, outgoing);
    const double incoming_time = handle_time(right, left, true, incoming);
    if (bool(left["weighted_out"]) || bool(right["weighted_in"])) {
        parameter = weighted_parameter(parameter, outgoing_time / span, 1.0 + incoming_time / span);
    }
    return cubic(left_value, left_value + outgoing_time * outgoing, right_value + incoming_time * incoming,
            right_value, parameter);
}

/// Return detached notify or state rows with an optional name filter.
TypedArray<Dictionary> select_records(const TypedArray<Dictionary> &records, const StringName &name) {
    if (name.is_empty()) {
        return records.duplicate(true);
    }
    TypedArray<Dictionary> selected;
    for (const Variant &value : records) {
        const Dictionary row = value;
        if (StringName(row["name"]) == name) {
            selected.push_back(row.duplicate(true));
        }
    }
    return selected;
}

/// Return a copy of an event row, setting its dispatch type and playback time.
Dictionary make_event(const Dictionary &row, CrimsonWeaponAnimationClip::EventType type, double time) {
    Dictionary event = row.duplicate(true);
    event["type"] = type;
    event["time"] = time;
    return event;
}

} // namespace

void CrimsonWeaponAnimationClip::_bind_methods() {
    ClassDB::bind_static_method(get_class_static(), D_METHOD("from_animation", "animation"), &CrimsonWeaponAnimationClip::from_animation);
    ClassDB::bind_static_method(get_class_static(), D_METHOD("from_player", "player", "key"), &CrimsonWeaponAnimationClip::from_player);
    ClassDB::bind_method(D_METHOD("get_duration"), &CrimsonWeaponAnimationClip::get_duration);
    ClassDB::bind_method(D_METHOD("get_curve_names"), &CrimsonWeaponAnimationClip::get_curve_names);
    ClassDB::bind_method(D_METHOD("get_curve_info", "name"), &CrimsonWeaponAnimationClip::get_curve_info);
    ClassDB::bind_method(D_METHOD("get_curve_keys", "name"), &CrimsonWeaponAnimationClip::get_curve_keys);
    ClassDB::bind_method(D_METHOD("sample_curve", "name", "seconds", "fallback"), &CrimsonWeaponAnimationClip::sample_curve, DEFVAL(0.0));
    ClassDB::bind_method(D_METHOD("sample_curve_normalized", "name", "phase", "fallback"),
            &CrimsonWeaponAnimationClip::sample_curve_normalized, DEFVAL(0.0));
    ClassDB::bind_method(D_METHOD("get_markers"), &CrimsonWeaponAnimationClip::get_markers);
    ClassDB::bind_method(D_METHOD("get_marker", "name"), &CrimsonWeaponAnimationClip::get_marker);
    ClassDB::bind_method(D_METHOD("get_marker_time", "name", "fallback"), &CrimsonWeaponAnimationClip::get_marker_time, DEFVAL(-1.0));
    ClassDB::bind_method(D_METHOD("get_notify_track_names"), &CrimsonWeaponAnimationClip::get_notify_track_names);
    ClassDB::bind_method(D_METHOD("get_notifies", "name"), &CrimsonWeaponAnimationClip::get_notifies, DEFVAL(StringName()));
    ClassDB::bind_method(D_METHOD("get_notify_states", "name"), &CrimsonWeaponAnimationClip::get_notify_states, DEFVAL(StringName()));
    ClassDB::bind_method(D_METHOD("get_active_notify_states", "seconds", "kind"),
            &CrimsonWeaponAnimationClip::get_active_notify_states, DEFVAL(StringName()));
    ClassDB::bind_method(D_METHOD("get_events_crossed", "from_seconds", "to_seconds", "include_start"),
            &CrimsonWeaponAnimationClip::get_events_crossed, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("get_loop_events_crossed", "from_seconds", "to_seconds", "loop_start", "loop_end"),
            &CrimsonWeaponAnimationClip::get_loop_events_crossed, DEFVAL(0.0), DEFVAL(-1.0));

    BIND_ENUM_CONSTANT(STATE_ENDED);
    BIND_ENUM_CONSTANT(STATE_STARTED);
    BIND_ENUM_CONSTANT(NOTIFY);
    BIND_ENUM_CONSTANT(MARKER);
}

Ref<CrimsonWeaponAnimationClip> CrimsonWeaponAnimationClip::from_animation(const Ref<Animation> &animation) {
    if (animation.is_null()) {
        return {};
    }
    Ref<CrimsonWeaponAnimationClip> result;
    result.instantiate();
    const Variant stored = animation->has_meta("weapon_tweaker_tracks") ?
            animation->get_meta("weapon_tweaker_tracks") : Variant();
    if (!result->read_tracks(stored, animation->get_length())) {
        return {};
    }
    return result;
}

Ref<CrimsonWeaponAnimationClip> CrimsonWeaponAnimationClip::from_player(AnimationPlayer *player, const StringName &key) {
    return player && player->has_animation(key) ? from_animation(player->get_animation(key)) : Ref<CrimsonWeaponAnimationClip>();
}

bool CrimsonWeaponAnimationClip::read_tracks(const Variant &stored, double clip_length) {
    if (!std::isfinite(clip_length) || clip_length <= 0.0) {
        return false;
    }
    duration = clip_length;
    if (stored.get_type() == Variant::NIL) {
        return true;
    }
    const Variant version = read_field(stored, "version");
    const Variant marker_data = read_field(stored, "markers");
    const Variant notify_data = read_field(stored, "notify_tracks");
    const Variant curve_data = read_field(stored, "curve_tracks");
    if (version.get_type() != Variant::INT || int64_t(version) != CrimsonWeaponAnimationTracks::SCHEMA_VERSION ||
            marker_data.get_type() != Variant::ARRAY || notify_data.get_type() != Variant::ARRAY ||
            curve_data.get_type() != Variant::ARRAY) {
        return false;
    }
    for (const Variant &marker : Array(marker_data)) {
        if (marker.get_type() != Variant::DICTIONARY) {
            return false;
        }
        const Dictionary source = marker;
        const Variant name_value = source.get("name", Variant());
        const Variant time_value = source.get("time", Variant());
        if (!is_named(name_value) || String(name_value).strip_edges() != String(name_value) ||
                !is_clip_time(time_value, duration) || !validate_color(source)) {
            return false;
        }
        const StringName name = name_value;
        if (markers_by_name.has(name)) {
            return false;
        }
        const double time = std::min(double(time_value), duration);
        Dictionary row;
        row["name"] = name;
        row["time"] = time;
        copy_color(source, row);
        markers.push_back(row);
        markers_by_name[name] = row;
        events.push_back(make_event(row, MARKER, time));
    }

    const Array lanes = notify_data;
    for (int64_t track_index = 0; track_index < lanes.size(); ++track_index) {
        if (lanes[track_index].get_type() != Variant::DICTIONARY) {
            return false;
        }
        const Dictionary lane = lanes[track_index];
        const Variant lane_name_value = lane.get("name", Variant());
        const Variant entries_value = lane.get("notifies", Variant());
        if (!is_named(lane_name_value) || entries_value.get_type() != Variant::ARRAY) {
            return false;
        }
        const StringName lane_name = lane_name_value;
        notify_track_names.push_back(String(lane_name));
        const Array entries = entries_value;
        for (int64_t entry_index = 0; entry_index < entries.size(); ++entry_index) {
            if (entries[entry_index].get_type() != Variant::DICTIONARY) {
                return false;
            }
            const Dictionary source = entries[entry_index];
            const Variant name_value = source.get("name", Variant());
            const Variant time_value = source.get("time", Variant());
            const Variant end_value = source.get("end_time", Variant());
            const Variant kind_value = source.get("kind", StringName());
            if (!is_named(name_value) || !is_clip_time(time_value, duration) || !is_number(end_value) ||
                    !is_text(kind_value) || !validate_color(source)) {
                return false;
            }
            const double time = std::min(double(time_value), duration);
            const double end = end_value;
            const bool one_shot = end == CrimsonWeaponAnimationTracks::ONE_SHOT;
            const StringName kind = kind_value;
            if ((!kind.is_empty() && (kind != StringName("MeleeTrace") || one_shot)) ||
                    (!one_shot && (!is_clip_time(end_value, duration) || end <= double(time_value)))) {
                return false;
            }
            Dictionary row;
            row["name"] = StringName(name_value);
            row["time"] = time;
            row["kind"] = kind;
            row["track_name"] = lane_name;
            row["track_index"] = track_index;
            row["entry_index"] = entry_index;
            copy_color(source, row);
            if (one_shot) {
                notifies.push_back(row);
                events.push_back(make_event(row, NOTIFY, time));
            } else {
                const double end_time = std::min(end, duration);
                row["end_time"] = end_time;
                states.push_back(row);
                Dictionary event_row = row.duplicate();
                event_row["start_time"] = time;
                events.push_back(make_event(event_row, STATE_STARTED, time));
                events.push_back(make_event(event_row, STATE_ENDED, end_time));
            }
        }
    }

    for (const Variant &curve : Array(curve_data)) {
        if (curve.get_type() != Variant::DICTIONARY) {
            return false;
        }
        const Dictionary source = curve;
        const Variant name_value = source.get("name", Variant());
        if (!is_named(name_value) || !validate_color(source)) {
            return false;
        }
        const StringName name = name_value;
        TypedArray<Dictionary> keys;
        if (curve_indexes.has(name) || !read_curve_keys(source.get("curve", Variant()), keys)) {
            return false;
        }
        Dictionary row;
        row["name"] = name;
        row["keys"] = keys;
        copy_color(source, row);
        curve_indexes[name] = curves.size();
        curves.push_back(row);
    }

    std::stable_sort(events.begin(), events.end(), [](const Dictionary &left, const Dictionary &right) {
        const double first = left["time"];
        const double second = right["time"];
        return first == second ? int64_t(left["type"]) < int64_t(right["type"]) : first < second;
    });
    event_times.reserve(events.size());
    for (const Dictionary &event : events) {
        event_times.push_back(double(event["time"]));
    }
    return true;
}

double CrimsonWeaponAnimationClip::get_duration() const {
    return duration;
}

PackedStringArray CrimsonWeaponAnimationClip::get_curve_names() const {
    PackedStringArray names;
    for (const Variant &value : curves) {
        names.push_back(String(Dictionary(value)["name"]));
    }
    return names;
}

Dictionary CrimsonWeaponAnimationClip::get_curve_info(const StringName &name) const {
    if (!curve_indexes.has(name)) {
        return {};
    }
    const Dictionary curve = curves[int64_t(curve_indexes[name])];
    Dictionary result;
    result["name"] = name;
    result["key_count"] = Array(curve["keys"]).size();
    copy_color(curve, result);
    return result;
}

TypedArray<Dictionary> CrimsonWeaponAnimationClip::get_curve_keys(const StringName &name) const {
    TypedArray<Dictionary> result;
    if (!curve_indexes.has(name)) {
        return result;
    }
    const Dictionary curve = curves[int64_t(curve_indexes[name])];
    const Array keys = curve["keys"];
    for (int64_t index = 0; index < keys.size(); ++index) {
        Dictionary key = Dictionary(keys[index]).duplicate(true);
        key["time"] = double(key["phase"]) * duration;
        key["in_slope"] = key_slope(keys, index, true);
        key["out_slope"] = key_slope(keys, index, false);
        result.push_back(key);
    }
    return result;
}

double CrimsonWeaponAnimationClip::sample_curve(const StringName &name, double seconds, double fallback) const {
    return duration > 0.0 ? sample_curve_normalized(name, seconds / duration, fallback) : fallback;
}

double CrimsonWeaponAnimationClip::sample_curve_normalized(const StringName &name, double phase, double fallback) const {
    if (!std::isfinite(phase) || !curve_indexes.has(name)) {
        return fallback;
    }
    const Dictionary curve = curves[int64_t(curve_indexes[name])];
    const Array keys = curve["keys"];
    return keys.is_empty() ? fallback : sample_keys(keys, std::clamp(phase, 0.0, 1.0));
}

TypedArray<Dictionary> CrimsonWeaponAnimationClip::get_markers() const {
    return markers.duplicate(true);
}

Dictionary CrimsonWeaponAnimationClip::get_marker(const StringName &name) const {
    return Dictionary(markers_by_name.get(name, Dictionary())).duplicate(true);
}

double CrimsonWeaponAnimationClip::get_marker_time(const StringName &name, double fallback) const {
    if (!markers_by_name.has(name)) {
        return fallback;
    }
    return Dictionary(markers_by_name[name])["time"];
}

PackedStringArray CrimsonWeaponAnimationClip::get_notify_track_names() const {
    return notify_track_names.duplicate();
}

TypedArray<Dictionary> CrimsonWeaponAnimationClip::get_notifies(const StringName &name) const {
    return select_records(notifies, name);
}

TypedArray<Dictionary> CrimsonWeaponAnimationClip::get_notify_states(const StringName &name) const {
    return select_records(states, name);
}

TypedArray<Dictionary> CrimsonWeaponAnimationClip::get_active_notify_states(double seconds, const StringName &kind) const {
    TypedArray<Dictionary> result;
    for (const Variant &value : states) {
        const Dictionary row = value;
        if (seconds >= double(row["time"]) && seconds < double(row["end_time"]) &&
                (kind.is_empty() || StringName(row["kind"]) == kind)) {
            result.push_back(row.duplicate(true));
        }
    }
    return result;
}

TypedArray<Dictionary> CrimsonWeaponAnimationClip::get_events_crossed(double from_seconds, double to_seconds, bool include_start) const {
    if (!std::isfinite(from_seconds) || !std::isfinite(to_seconds) || from_seconds > to_seconds ||
            from_seconds > duration || to_seconds < 0.0) {
        return {};
    }
    return events_in_range(std::max(0.0, from_seconds), std::min(duration, to_seconds), include_start || from_seconds < 0.0);
}

TypedArray<Dictionary> CrimsonWeaponAnimationClip::get_loop_events_crossed(double from_seconds, double to_seconds,
        double loop_start, double loop_end) const {
    const double end = loop_end == -1.0 ? duration : loop_end;
    if (!(loop_start >= 0.0 && end <= duration && loop_start < end && from_seconds >= loop_start &&
                 from_seconds <= end && to_seconds >= loop_start && to_seconds <= end)) {
        return {};
    }
    TypedArray<Dictionary> result = events_in_range(from_seconds, end, false);
    result.append_array(events_in_range(loop_start, to_seconds, true));
    return result;
}

TypedArray<Dictionary> CrimsonWeaponAnimationClip::events_in_range(double start, double end, bool include_start) const {
    auto first = include_start ? std::lower_bound(event_times.begin(), event_times.end(), start) :
                              std::upper_bound(event_times.begin(), event_times.end(), start);
    const auto stop = std::upper_bound(event_times.begin(), event_times.end(), end);
    TypedArray<Dictionary> result;
    for (; first < stop; ++first) {
        result.push_back(events[std::distance(event_times.begin(), first)].duplicate(true));
    }
    return result;
}

} // namespace crimson::weapon_animation
