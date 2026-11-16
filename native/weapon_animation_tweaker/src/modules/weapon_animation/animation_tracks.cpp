// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "animation_tracks.hpp"

#include "animation_clip.hpp"

namespace crimson::weapon_animation {
namespace {

using namespace godot;

/// Metadata field shared with the original clip editor.
constexpr char clip_metadata[] = "weapon_tweaker_tracks";

/// Copy curve lanes including their embedded Resource payloads.
TypedArray<Dictionary> copy_curve_lanes(const TypedArray<Dictionary> &rows) {
    TypedArray<Dictionary> copied = rows.duplicate(true);
    for (int64_t index = 0; index < copied.size(); ++index) {
        Dictionary row = copied[index];
        const Variant value = row.get("curve", Variant());
        if (value.get_type() == Variant::OBJECT) {
            const Ref<Resource> resource = value;
            if (resource.is_valid()) {
                row["curve"] = resource->duplicate_deep(Resource::DEEP_DUPLICATE_ALL);
            }
        }
    }
    return copied;
}

/// Copy validated fields from either native or scripted storage.
Variant stored_field(const Variant &source, const StringName &name) {
    if (source.get_type() == Variant::OBJECT) {
        const Ref<Resource> resource = source;
        return resource->get(name);
    }
    return Dictionary(source)[name];
}

} // namespace

void CrimsonWeaponAnimationTracks::_bind_methods() {
    ClassDB::bind_static_method(get_class_static(), D_METHOD("from_animation", "animation"),
            &CrimsonWeaponAnimationTracks::from_animation);
    ClassDB::bind_method(D_METHOD("write_to", "animation"), &CrimsonWeaponAnimationTracks::write_to);
    ClassDB::bind_method(D_METHOD("is_valid", "duration"), &CrimsonWeaponAnimationTracks::is_valid);
    ClassDB::bind_method(D_METHOD("get_version"), &CrimsonWeaponAnimationTracks::get_version);
    ClassDB::bind_method(D_METHOD("set_version", "version"), &CrimsonWeaponAnimationTracks::set_version);
    ClassDB::bind_method(D_METHOD("get_markers"), &CrimsonWeaponAnimationTracks::get_markers);
    ClassDB::bind_method(D_METHOD("set_markers", "markers"), &CrimsonWeaponAnimationTracks::set_markers);
    ClassDB::bind_method(D_METHOD("get_notify_tracks"), &CrimsonWeaponAnimationTracks::get_notify_tracks);
    ClassDB::bind_method(D_METHOD("set_notify_tracks", "notify_tracks"), &CrimsonWeaponAnimationTracks::set_notify_tracks);
    ClassDB::bind_method(D_METHOD("get_curve_tracks"), &CrimsonWeaponAnimationTracks::get_curve_tracks);
    ClassDB::bind_method(D_METHOD("set_curve_tracks", "curve_tracks"), &CrimsonWeaponAnimationTracks::set_curve_tracks);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "version", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE),
            "set_version", "get_version");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "markers", PROPERTY_HINT_ARRAY_TYPE, "Dictionary"), "set_markers", "get_markers");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "notify_tracks", PROPERTY_HINT_ARRAY_TYPE, "Dictionary"),
            "set_notify_tracks", "get_notify_tracks");
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "curve_tracks", PROPERTY_HINT_ARRAY_TYPE, "Dictionary"),
            "set_curve_tracks", "get_curve_tracks");
}

Ref<CrimsonWeaponAnimationTracks> CrimsonWeaponAnimationTracks::from_animation(const Ref<Animation> &animation) {
    const Ref<CrimsonWeaponAnimationClip> snapshot = CrimsonWeaponAnimationClip::from_animation(animation);
    if (snapshot.is_null()) {
        return {};
    }
    Ref<CrimsonWeaponAnimationTracks> result;
    result.instantiate();
    if (!animation->has_meta(clip_metadata)) {
        return result;
    }
    const Variant source = animation->get_meta(clip_metadata);
    result->version = stored_field(source, "version");
    result->set_markers(Array(stored_field(source, "markers")));
    result->set_notify_tracks(Array(stored_field(source, "notify_tracks")));
    for (const Variant &entry : snapshot->curves) {
        Dictionary row = Dictionary(entry).duplicate(true);
        row["curve"] = row["keys"];
        row.erase("keys");
        result->curve_tracks.push_back(row);
    }
    return result;
}

bool CrimsonWeaponAnimationTracks::write_to(const Ref<Animation> &animation) const {
    if (animation.is_null() || !is_valid(animation->get_length())) {
        return false;
    }
    if (markers.is_empty() && notify_tracks.is_empty() && curve_tracks.is_empty()) {
        animation->remove_meta(clip_metadata);
    } else {
        Ref<CrimsonWeaponAnimationTracks> stored;
        stored.instantiate();
        stored->version = version;
        stored->markers = markers.duplicate(true);
        stored->notify_tracks = notify_tracks.duplicate(true);
        stored->curve_tracks = copy_curve_lanes(curve_tracks);
        animation->set_meta(clip_metadata, stored);
    }
    animation->emit_changed();
    return true;
}

bool CrimsonWeaponAnimationTracks::is_valid(double duration) const {
    Dictionary source;
    source["version"] = version;
    source["markers"] = markers;
    source["notify_tracks"] = notify_tracks;
    source["curve_tracks"] = curve_tracks;
    Ref<CrimsonWeaponAnimationClip> snapshot;
    snapshot.instantiate();
    return snapshot->read_tracks(source, duration);
}

int64_t CrimsonWeaponAnimationTracks::get_version() const {
    return version;
}

void CrimsonWeaponAnimationTracks::set_version(int64_t new_version) {
    version = new_version;
    emit_changed();
}

TypedArray<Dictionary> CrimsonWeaponAnimationTracks::get_markers() const {
    return markers.duplicate(true);
}

void CrimsonWeaponAnimationTracks::set_markers(const TypedArray<Dictionary> &rows) {
    markers = rows.duplicate(true);
    emit_changed();
}

TypedArray<Dictionary> CrimsonWeaponAnimationTracks::get_notify_tracks() const {
    return notify_tracks.duplicate(true);
}

void CrimsonWeaponAnimationTracks::set_notify_tracks(const TypedArray<Dictionary> &rows) {
    notify_tracks = rows.duplicate(true);
    emit_changed();
}

TypedArray<Dictionary> CrimsonWeaponAnimationTracks::get_curve_tracks() const {
    return copy_curve_lanes(curve_tracks);
}

void CrimsonWeaponAnimationTracks::set_curve_tracks(const TypedArray<Dictionary> &rows) {
    curve_tracks = copy_curve_lanes(rows);
    emit_changed();
}

} // namespace crimson::weapon_animation
