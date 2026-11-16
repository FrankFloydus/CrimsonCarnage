// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "animation_combo.hpp"

#include "animation_clip.hpp"

#include <godot_cpp/core/math.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

namespace crimson::weapon_animation {
namespace {

using namespace godot;

/// Sentinel for the natural start or end of a clip.
constexpr double clip_boundary = -1.0;
/// Initial blend duration in seconds for a new join.
constexpr double default_blend = 0.08;

/// Determine whether a saved field is text.
bool is_text(const Variant &value) {
    return value.get_type() == Variant::STRING || value.get_type() == Variant::STRING_NAME;
}

/// Return validated seconds, or NaN for an invalid encoded value.
double seconds(const Variant &value) {
    if (value.get_type() == Variant::FLOAT || value.get_type() == Variant::INT) {
        return value;
    }
    return NAN;
}

/// Report why a transition cannot be previewed.
Dictionary join_error(const String &message) {
    Dictionary result;
    result["error"] = message;
    return result;
}

/// Create the complete serialized shape for an authored join.
Dictionary make_join(const StringName &exit_marker, const StringName &entry_marker, double blend,
        double exit_time, double entry_time) {
    Dictionary result;
    result["exit_marker"] = exit_marker;
    result["entry_marker"] = entry_marker;
    result["blend_duration"] = blend;
    result["exit_time"] = exit_time;
    result["entry_time"] = entry_time;
    return result;
}

/// New transitions join the natural end and start unless the author supplies other points.
Dictionary default_join() {
    return make_join({}, {}, default_blend, clip_boundary, clip_boundary);
}

/// Look up a playable animation without surfacing an engine error for an absent key.
Ref<Animation> find_animation(AnimationPlayer *player, const StringName &key) {
    if (!player || !player->has_animation(key)) {
        return {};
    }
    const Ref<Animation> animation = player->get_animation(key);
    if (animation.is_null() || !std::isfinite(animation->get_length()) || animation->get_length() <= 0.0) {
        return {};
    }
    return animation;
}

/// Prefer an explicit Tweaker marker, then a custom time, then the natural boundary.
double resolve_time(const Ref<Animation> &animation, const StringName &marker, double custom_time, double boundary) {
    if (!marker.is_empty()) {
        const Ref<CrimsonWeaponAnimationClip> clip = CrimsonWeaponAnimationClip::from_animation(animation);
        return clip.is_valid() ? clip->get_marker_time(marker) : -1.0;
    }
    return custom_time == clip_boundary ? boundary : custom_time;
}

/// Accept the textual round trip of an endpoint at clip length.
bool is_clip_time(double value, double length) {
    return std::isfinite(value) && value >= 0.0 && (value <= length || Math::is_equal_approx(value, length));
}

/// Explain which clip or marker needs a corrected endpoint.
String time_error(const StringName &key, const StringName &marker, const String &endpoint) {
    if (!marker.is_empty()) {
        return vformat("Clip \"%s\" is missing the Tweaker %s marker \"%s\".", key, endpoint, marker);
    }
    return vformat("The %s time for clip \"%s\" is outside its duration.", endpoint, key);
}

} // namespace

void CrimsonWeaponAnimationCombo::_bind_methods() {
    ClassDB::bind_static_method(get_class_static(), D_METHOD("from_resource", "resource"), &CrimsonWeaponAnimationCombo::from_resource);
    ClassDB::bind_method(D_METHOD("copy"), &CrimsonWeaponAnimationCombo::copy);
    ClassDB::bind_method(D_METHOD("get_display_name"), &CrimsonWeaponAnimationCombo::get_display_name);
    ClassDB::bind_method(D_METHOD("set_display_name", "name"), &CrimsonWeaponAnimationCombo::set_display_name);
    ClassDB::bind_method(D_METHOD("get_clip_keys"), &CrimsonWeaponAnimationCombo::get_clip_keys);
    ClassDB::bind_method(D_METHOD("set_clip_keys", "keys"), &CrimsonWeaponAnimationCombo::set_clip_keys);
    ClassDB::bind_method(D_METHOD("get_joins"), &CrimsonWeaponAnimationCombo::get_joins);
    ClassDB::bind_method(D_METHOD("set_joins", "joins"), &CrimsonWeaponAnimationCombo::set_joins);
    ClassDB::bind_method(D_METHOD("get_loop"), &CrimsonWeaponAnimationCombo::get_loop);
    ClassDB::bind_method(D_METHOD("set_loop", "enabled"), &CrimsonWeaponAnimationCombo::set_loop);
    ClassDB::bind_method(D_METHOD("set_clips", "keys"), &CrimsonWeaponAnimationCombo::set_clips);
    ClassDB::bind_method(D_METHOD("get_join_count"), &CrimsonWeaponAnimationCombo::get_join_count);
    ClassDB::bind_method(D_METHOD("get_join", "index"), &CrimsonWeaponAnimationCombo::get_join);
    ClassDB::bind_method(D_METHOD("set_join", "index", "exit_marker", "entry_marker", "blend_duration", "exit_time", "entry_time"),
            &CrimsonWeaponAnimationCombo::set_join, DEFVAL(clip_boundary), DEFVAL(clip_boundary));
    ClassDB::bind_method(D_METHOD("resolve_join", "player", "index"), &CrimsonWeaponAnimationCombo::resolve_join);
    ClassDB::bind_method(D_METHOD("validate", "player"), &CrimsonWeaponAnimationCombo::validate);

    ADD_PROPERTY(PropertyInfo(Variant::STRING, "display_name"), "set_display_name", "get_display_name");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "clip_keys", PROPERTY_HINT_ARRAY_TYPE, "StringName"), "set_clip_keys", "get_clip_keys");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "joins", PROPERTY_HINT_ARRAY_TYPE, "Dictionary"), "set_joins", "get_joins");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "loop"), "set_loop", "get_loop");
}

Ref<CrimsonWeaponAnimationCombo> CrimsonWeaponAnimationCombo::from_resource(const Ref<Resource> &resource) {
    if (resource.is_null()) {
        return {};
    }
    if (const CrimsonWeaponAnimationCombo *native = Object::cast_to<CrimsonWeaponAnimationCombo>(resource.ptr())) {
        return native->copy();
    }
    const Variant saved_name = resource->get("display_name");
    const Variant saved_keys = resource->get("clip_keys");
    const Variant saved_joins = resource->get("joins");
    const Variant saved_loop = resource->get("loop");
    if (!is_text(saved_name) || saved_keys.get_type() != Variant::ARRAY || saved_joins.get_type() != Variant::ARRAY ||
            saved_loop.get_type() != Variant::BOOL) {
        return {};
    }
    Ref<CrimsonWeaponAnimationCombo> result;
    result.instantiate();
    result->display_name = saved_name;
    result->loop = saved_loop;
    for (const Variant &key : Array(saved_keys)) {
        if (!is_text(key)) {
            return {};
        }
        result->clip_keys.push_back(StringName(key));
    }
    for (const Variant &join : Array(saved_joins)) {
        if (join.get_type() != Variant::DICTIONARY) {
            return {};
        }
        result->joins.push_back(Dictionary(join).duplicate(true));
    }
    return result;
}

Ref<CrimsonWeaponAnimationCombo> CrimsonWeaponAnimationCombo::copy() const {
    Ref<CrimsonWeaponAnimationCombo> result;
    result.instantiate();
    result->display_name = display_name;
    result->clip_keys = clip_keys.duplicate();
    result->joins = joins.duplicate(true);
    result->loop = loop;
    return result;
}

String CrimsonWeaponAnimationCombo::get_display_name() const {
    return display_name;
}

void CrimsonWeaponAnimationCombo::set_display_name(const String &name) {
    display_name = name;
    emit_changed();
}

TypedArray<StringName> CrimsonWeaponAnimationCombo::get_clip_keys() const {
    return clip_keys.duplicate();
}

void CrimsonWeaponAnimationCombo::set_clip_keys(const TypedArray<StringName> &keys) {
    clip_keys = keys.duplicate();
    emit_changed();
}

TypedArray<Dictionary> CrimsonWeaponAnimationCombo::get_joins() const {
    return joins.duplicate(true);
}

void CrimsonWeaponAnimationCombo::set_joins(const TypedArray<Dictionary> &new_joins) {
    joins = new_joins.duplicate(true);
    emit_changed();
}

bool CrimsonWeaponAnimationCombo::get_loop() const {
    return loop;
}

void CrimsonWeaponAnimationCombo::set_loop(bool enabled) {
    loop = enabled;
    emit_changed();
}

void CrimsonWeaponAnimationCombo::set_clips(const TypedArray<StringName> &keys) {
    TypedArray<Dictionary> updated;
    const int64_t previous_count = clip_keys.size();
    std::vector<bool> retained(previous_count, false);
    for (int64_t index = 0; index < keys.size(); ++index) {
        const int64_t next = (index + 1) % keys.size();
        Dictionary row = default_join();
        for (int64_t old = 0; old < previous_count; ++old) {
            if (!retained[old] && clip_keys[old] == keys[index] && clip_keys[(old + 1) % previous_count] == keys[next]) {
                row = get_join(old);
                retained[old] = true;
                break;
            }
        }
        updated.push_back(row);
    }
    clip_keys = keys.duplicate();
    joins = updated;
    emit_changed();
}

int64_t CrimsonWeaponAnimationCombo::get_join_count() const {
    const int64_t count = clip_keys.size();
    return count < 2 ? 0 : count - (loop ? 0 : 1);
}

Dictionary CrimsonWeaponAnimationCombo::get_join(int64_t index) const {
    Dictionary row = default_join();
    if (index >= 0 && index < joins.size()) {
        row.merge(Dictionary(joins[index]).duplicate(true), true);
    }
    return row;
}

void CrimsonWeaponAnimationCombo::set_join(int64_t index, const StringName &exit_marker, const StringName &entry_marker,
        double blend_duration, double exit_time, double entry_time) {
    if (index < 0 || index >= clip_keys.size()) {
        return;
    }
    while (joins.size() <= index) {
        joins.push_back(default_join());
    }
    joins[index] = make_join(exit_marker, entry_marker, blend_duration, exit_time, entry_time);
    emit_changed();
}

Dictionary CrimsonWeaponAnimationCombo::resolve_join(AnimationPlayer *player, int64_t index) const {
    if (index < 0 || index >= get_join_count()) {
        return join_error("Choose a transition in the combo.");
    }
    const StringName outgoing = clip_keys[index];
    const StringName incoming = clip_keys[(index + 1) % clip_keys.size()];
    const Ref<Animation> from_animation = find_animation(player, outgoing);
    if (from_animation.is_null()) {
        return join_error(vformat("Clip \"%s\" is unavailable or has no playable duration.", outgoing));
    }
    const Ref<Animation> to_animation = find_animation(player, incoming);
    if (to_animation.is_null()) {
        return join_error(vformat("Clip \"%s\" is unavailable or has no playable duration.", incoming));
    }
    const Dictionary row = get_join(index);
    if (!is_text(row["exit_marker"]) || !is_text(row["entry_marker"])) {
        return join_error("Transition markers must be names.");
    }
    const StringName exit_marker = row["exit_marker"];
    const StringName entry_marker = row["entry_marker"];
    const double outgoing_length = from_animation->get_length();
    const double incoming_length = to_animation->get_length();
    const double exit_time = resolve_time(from_animation, exit_marker, seconds(row["exit_time"]), outgoing_length);
    const double entry_time = resolve_time(to_animation, entry_marker, seconds(row["entry_time"]), 0.0);
    if (!is_clip_time(exit_time, outgoing_length)) {
        return join_error(time_error(outgoing, exit_marker, "exit"));
    }
    if (!is_clip_time(entry_time, incoming_length)) {
        return join_error(time_error(incoming, entry_marker, "entry"));
    }
    const double blend = seconds(row["blend_duration"]);
    if (!std::isfinite(blend) || blend < 0.0) {
        return join_error("Blend duration must be a finite, non-negative number of seconds.");
    }
    Dictionary result = make_join(exit_marker, entry_marker, blend,
            std::min(exit_time, outgoing_length), std::min(entry_time, incoming_length));
    result["outgoing_key"] = outgoing;
    result["incoming_key"] = incoming;
    result["outgoing_length"] = outgoing_length;
    result["incoming_length"] = incoming_length;
    return result;
}

String CrimsonWeaponAnimationCombo::validate(AnimationPlayer *player) const {
    if (clip_keys.size() < 2) {
        return "Add at least two clips to preview a combo.";
    }
    const int64_t count = get_join_count();
    std::vector<Dictionary> resolved;
    resolved.reserve(count);
    for (int64_t index = 0; index < count; ++index) {
        const Dictionary join = resolve_join(player, index);
        if (join.has("error")) {
            return join["error"];
        }
        resolved.push_back(join);
    }
    for (int64_t index = loop ? 0 : 1; index < count; ++index) {
        const double entry = resolved[(index + count - 1) % count]["entry_time"];
        const double exit = resolved[index]["exit_time"];
        if (entry > exit && !Math::is_equal_approx(entry, exit)) {
            return vformat("The entry point for clip %d \"%s\" follows its exit point.", index + 1, clip_keys[index]);
        }
    }
    return {};
}

} // namespace crimson::weapon_animation
