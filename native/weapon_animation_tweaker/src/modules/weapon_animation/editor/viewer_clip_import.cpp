// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "modules/weapon_animation/editor/viewer_clip_import.hpp"

#ifdef DEBUG_ENABLED

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/classes/animation_library.hpp>
#include <godot_cpp/classes/animation_player.hpp>
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/editor_undo_redo_manager.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <iterator>
#include <vector>

namespace crimson::weapon_animation {
namespace {
using namespace godot;

constexpr char format_name[] = "vermintide_tweaker_clips"; ///< Viewer clip bundle format.
constexpr int format_version = 1; ///< Current compatible bundle schema.
constexpr double minimum_duration = 0.001; ///< Smallest playable clip length in seconds.
constexpr double time_tolerance = 0.000001; ///< Tolerance used only for the first and last sample.
constexpr const char *socket_sides[] = {"right", "left"}; ///< Supported Viewer socket identifiers.
constexpr const char *socket_nodes[] = {"WeaponControl", "LeftWeaponControl"}; ///< Authored rig sockets.
constexpr char source_id_key[] = "native_animation_id"; ///< Stable deduplication key for the imported clip.
constexpr char camera_motion_property[] = "attack_camera_motion"; ///< Optional local motion property on the look pivot.
constexpr char native_pose_index[] = "native_pose_index"; ///< Identifies authorable nodes in the native pose hierarchy.

/// Resolved scene-owned paths. The pack can only write tracks to these targets.
struct ImportTargets {
    Dictionary sockets; ///< Paths keyed by right or left.
    NodePath camera; ///< Optional Transform3D property for local camera motion.
    Dictionary joints; ///< Named pose joints keyed by their node names.
};

/// Pack construction does not retain mutable state on the source player.
struct PreparedClip {
    Ref<Animation> resource; ///< Imported animation with pose, socket and camera data as available.
    String error; ///< Failure to convert a structural field or sampled transform.
    bool pose_bound = false; ///< The target's native pose hierarchy matched the Viewer rig.
};

/// Return the common failure shape used by the pack and commit APIs.
Dictionary failure(const String &error) {
    Dictionary output;
    output["error"] = error;
    return output;
}

/// Test a JSON numeric field without coercing strings or booleans.
bool finite_number(const Variant &value) {
    return (value.get_type() == Variant::FLOAT || value.get_type() == Variant::INT) &&
            std::isfinite(double(value));
}

/// A label or source identifier must have visible text.
bool nonempty_text(const Variant &value) {
    return value.get_type() == Variant::STRING && !String(value).strip_edges().is_empty();
}

/// Compare nested sample dimensions before decoding transforms.
bool array_size_matches(const Variant &value, int64_t expected) {
    return value.get_type() == Variant::ARRAY && Array(value).size() == expected;
}

/// Validate unique joint identities and a bounded, acyclic parent hierarchy.
String validate_rig(const Array &rows) {
    std::vector<int64_t> parents;
    parents.reserve(rows.size());
    Dictionary names;
    for (int64_t index = 0; index < rows.size(); ++index) {
        if (rows[index].get_type() != Variant::DICTIONARY) {
            return "Rig joint " + String::num_int64(index + 1) + " must be an object.";
        }
        const Dictionary row = rows[index];
        const Variant name = row.get("name", Variant());
        const Variant parent_field = row.get("parent", Variant());
        if (!nonempty_text(name) || !finite_number(parent_field)) {
            return "Rig joint " + String::num_int64(index + 1) + " has an invalid name or parent.";
        }
        const double parent = double(parent_field);
        if (std::trunc(parent) != parent || parent < -1.0 || parent >= rows.size() || parent == index) {
            return "Rig joint " + String(name) + " has an invalid parent index.";
        }
        if (names.has(name)) {
            return "The clip pack has more than one rig joint named " + String(name) + ".";
        }
        names[name] = true;
        parents.push_back(int64_t(parent));
    }
    enum Visit : uint8_t { NEW, VISITING, COMPLETE };
    std::vector<Visit> visits(parents.size(), NEW);
    for (int64_t index = 0; index < rows.size(); ++index) {
        int64_t current = index;
        for (; current >= 0 && visits[current] == NEW; current = parents[current]) {
            visits[current] = VISITING;
        }
        if (current >= 0 && visits[current] == VISITING) {
            return "The clip pack contains a cycle in the rig hierarchy.";
        }
        for (current = index; current >= 0 && visits[current] == VISITING; current = parents[current]) {
            visits[current] = COMPLETE;
        }
    }
    return {};
}

/// Validate clip shape and keep the exact input times, apart from tolerated end rounding.
String validate_clip(const Dictionary &clip, int64_t joint_count, PackedFloat64Array &times) {
    if (!nonempty_text(clip.get("id", Variant())) || !nonempty_text(clip.get("name", Variant())) ||
            clip.get("weapon_set", Variant()).get_type() != Variant::STRING) {
        return "The source clip ID, name, or weapon set is missing.";
    }
    const Variant duration_field = clip.get("duration", Variant());
    const Variant step_field = clip.get("step", Variant());
    if (!finite_number(duration_field) || double(duration_field) < minimum_duration ||
            !finite_number(step_field) || double(step_field) < 0.0) {
        return "The clip duration or sample step is invalid.";
    }
    const double duration = double(duration_field);
    const Variant sample_field = clip.get("times", Variant());
    if (sample_field.get_type() != Variant::ARRAY || Array(sample_field).is_empty()) {
        return "The clip has no sample times.";
    }
    const Array samples = sample_field;
    times.resize(samples.size());
    double previous = -1.0;
    for (int64_t index = 0; index < samples.size(); ++index) {
        if (!finite_number(samples[index])) {
            return "The clip contains an invalid sample time.";
        }
        double seconds = double(samples[index]);
        if (index == 0 && std::abs(seconds) <= time_tolerance) {
            seconds = 0.0;
        } else if (index + 1 == samples.size() && std::abs(seconds - duration) <= time_tolerance) {
            seconds = duration;
        }
        if (seconds <= previous || seconds < 0.0 || seconds > duration) {
            return "Sample times must increase from zero to the clip duration.";
        }
        times.set(index, seconds);
        previous = seconds;
    }
    if (times[0] != 0.0 || times[times.size() - 1] != duration) {
        return "The clip is missing its first or last sample.";
    }

    const Variant socket_field = clip.get("sockets", Variant());
    if (socket_field.get_type() != Variant::DICTIONARY || Dictionary(socket_field).is_empty()) {
        return "The clip has no weapon socket samples.";
    }
    const Dictionary sockets = socket_field;
    const Array sides = sockets.keys();
    for (const Variant &side : sides) {
        if ((side != Variant("right") && side != Variant("left")) ||
                !array_size_matches(sockets[side], times.size())) {
            return "The " + String(side) + " socket sample count does not match the clip.";
        }
    }
    const Variant camera = clip.get("camera", Array());
    if (camera.get_type() != Variant::ARRAY || (!Array(camera).is_empty() && Array(camera).size() != times.size())) {
        return "The camera sample count does not match the clip.";
    }
    const Variant pose_field = clip.get("poses", Array());
    if (pose_field.get_type() != Variant::ARRAY || (!Array(pose_field).is_empty() &&
            (Array(pose_field).size() != times.size() || joint_count == 0))) {
        return "The rig pose sample count does not match the clip.";
    }
    for (const Variant &frame : Array(pose_field)) {
        if (!array_size_matches(frame, joint_count)) {
            return "A rig pose has the wrong number of joints.";
        }
    }

    const Variant marker_field = clip.get("markers", Array());
    if (marker_field.get_type() != Variant::ARRAY) {
        return "The clip markers must be an array.";
    }
    Dictionary marker_names;
    for (const Variant &entry : Array(marker_field)) {
        if (entry.get_type() != Variant::DICTIONARY) {
            return "A clip marker must be an object.";
        }
        const Dictionary marker = entry;
        const Variant name = marker.get("name", Variant());
        const Variant at = marker.get("time", Variant());
        if (!nonempty_text(name) || !finite_number(at) || double(at) < 0.0 || double(at) > duration) {
            return "A clip marker has an invalid name or time.";
        }
        if (marker_names.has(name)) {
            return "More than one clip marker is named " + String(name) + ".";
        }
        marker_names[name] = true;
    }
    return {};
}

/// Check that a camera belongs to the target and has at least one supported socket.
bool camera_has_sockets(Node *rig, Camera3D *camera) {
    if (!camera || (rig != camera && !rig->is_ancestor_of(camera))) {
        return false;
    }
    for (const char *name : socket_nodes) {
        if (Object::cast_to<Node3D>(camera->get_node_or_null(NodePath(name)))) {
            return true;
        }
    }
    return false;
}

/// Prefer the active clip's camera, then the authored convention or a unique compatible camera.
Camera3D *find_import_camera(Node *rig, Camera3D *preferred) {
    if (camera_has_sockets(rig, preferred)) {
        return preferred;
    }
    auto *authored = Object::cast_to<Camera3D>(rig->get_node_or_null(NodePath("Look/Camera3D")));
    if (camera_has_sockets(rig, authored)) {
        return authored;
    }
    Camera3D *match = Object::cast_to<Camera3D>(rig);
    if (!camera_has_sockets(rig, match)) {
        match = nullptr;
    }
    const TypedArray<Node> cameras = rig->find_children("*", "Camera3D", true, false);
    for (int64_t index = 0; index < cameras.size(); ++index) {
        auto *candidate = Object::cast_to<Camera3D>(cameras[index]);
        if (camera_has_sockets(rig, candidate)) {
            if (match) {
                return nullptr;
            }
            match = candidate;
        }
    }
    return match;
}

/// Resolve paths independently of any game script or external rig-definition file.
ImportTargets resolve_targets(Node *edited_scene, AnimationPlayer *player, Camera3D *preferred) {
    ImportTargets result;
    if (!edited_scene || !player || (edited_scene != player && player->get_owner() != edited_scene)) {
        return result;
    }
    Node *rig = player->get_node_or_null(player->get_root_node());
    if (!rig) {
        return result;
    }
    Camera3D *camera = find_import_camera(rig, preferred);
    if (!camera) {
        return result;
    }
    for (size_t side = 0; side < std::size(socket_nodes); ++side) {
        auto *target = Object::cast_to<Node3D>(camera->get_node_or_null(NodePath(socket_nodes[side])));
        if (target) {
            result.sockets[socket_sides[side]] = rig->get_path_to(target);
        }
    }
    Node *look = camera->get_parent();
    if (look && (look == rig || rig->is_ancestor_of(look)) &&
            look->get(camera_motion_property).get_type() == Variant::TRANSFORM3D) {
        result.camera = NodePath(String(rig->get_path_to(look)) + ":" + camera_motion_property);
    }
    Node *pose = camera->get_node_or_null(NodePath("NativePoseRig"));
    if (pose) {
        const TypedArray<Node> nodes = pose->find_children("*", "Node3D", true, false);
        for (int64_t index = 0; index < nodes.size(); ++index) {
            Node *joint = Object::cast_to<Node3D>(nodes[index]);
            if (!joint || !joint->has_meta(native_pose_index)) {
                continue;
            }
            const String name = joint->get_name();
            if (result.joints.has(name)) {
                result.joints.clear();
                break;
            }
            result.joints[name] = rig->get_path_to(joint);
        }
    }
    return result;
}

/// Match all target joints and their immediate parent paths. Additional source joints can be skipped.
TypedArray<NodePath> match_pose(const Array &rows, const Dictionary &targets) {
    if (targets.is_empty()) {
        return {};
    }
    Dictionary source_indexes;
    for (int64_t index = 0; index < rows.size(); ++index) {
        const Dictionary row = rows[index];
        source_indexes[row["name"]] = index;
    }
    TypedArray<NodePath> output;
    output.resize(rows.size());
    const Array names = targets.keys();
    const Array paths = targets.values();
    for (const Variant &name : names) {
        const int64_t index = source_indexes.get(name, -1);
        if (index < 0) {
            return {};
        }
        const Dictionary row = rows[index];
        const NodePath target = targets[name];
        const NodePath target_parent(String(target).get_base_dir());
        const int64_t parent = row["parent"];
        if (parent < 0) {
            if (paths.has(target_parent)) {
                return {};
            }
        } else {
            const Dictionary parent_row = rows[parent];
            const NodePath expected = targets.get(parent_row["name"], NodePath());
            if (expected.is_empty() || expected != target_parent) {
                return {};
            }
        }
        output[index] = target;
    }
    return output;
}

/// Decode one column-major Godot transform. Animated bases may scale, but must have positive orientation.
bool decode_transform(const Variant &sample, Transform3D &pose) {
    if (!array_size_matches(sample, 12)) {
        return false;
    }
    const Array values = sample;
    real_t components[12];
    for (int index = 0; index < 12; ++index) {
        if (!finite_number(values[index])) {
            return false;
        }
        components[index] = real_t(double(values[index]));
    }
    pose = Transform3D(Vector3(components[0], components[1], components[2]),
            Vector3(components[3], components[4], components[5]),
            Vector3(components[6], components[7], components[8]),
            Vector3(components[9], components[10], components[11]));
    const double determinant = pose.basis.determinant();
    return pose.is_finite() && std::isfinite(determinant) && determinant > 0.0;
}

/// Write a socket or a joint as editable native position, rotation, and scale tracks.
bool write_tracks(const Ref<Animation> &animation, const NodePath &path, const PackedFloat64Array &times,
        const Array &frames, int64_t joint = -1) {
    const int position_track = animation->add_track(Animation::TYPE_POSITION_3D);
    const int rotation_track = animation->add_track(Animation::TYPE_ROTATION_3D);
    const int scale_track = animation->add_track(Animation::TYPE_SCALE_3D);
    animation->track_set_path(position_track, path);
    animation->track_set_path(rotation_track, path);
    animation->track_set_path(scale_track, path);

    Quaternion previous_rotation;
    for (int64_t index = 0; index < times.size(); ++index) {
        const Variant sample = joint < 0 ? frames[index] : Array(frames[index])[joint];
        Transform3D pose;
        if (!decode_transform(sample, pose)) {
            return false;
        }
        Quaternion rotation = pose.basis.get_rotation_quaternion();
        const Vector3 scale = pose.basis.get_scale();
        if (!scale.is_finite() || !rotation.is_finite() || !rotation.is_normalized()) {
            return false;
        }
        if (index > 0 && previous_rotation.dot(rotation) < 0.0) {
            rotation = -rotation;
        }
        previous_rotation = rotation;
        animation->position_track_insert_key(position_track, times[index], pose.origin);
        animation->rotation_track_insert_key(rotation_track, times[index], rotation);
        animation->scale_track_insert_key(scale_track, times[index], scale);
    }
    return true;
}

/// Build an editable animation without changing the target player or its existing resources.
PreparedClip prepare_clip(const Dictionary &clip, const Array &joints, const ImportTargets &targets) {
    PreparedClip result;
    PackedFloat64Array times;
    result.error = validate_clip(clip, joints.size(), times);
    if (!result.error.is_empty()) {
        return result;
    }
    Ref<Animation> animation;
    animation.instantiate();
    animation->set_name(clip["name"]);
    animation->set_length(clip["duration"]);
    animation->set_step(clip["step"]);
    animation->set_meta(source_id_key, clip["id"]);
    animation->set_meta("source_animation_name", clip["name"]);
    animation->set_meta("weapon_set", clip["weapon_set"]);

    const Dictionary sockets = clip["sockets"];
    for (const char *side : socket_sides) {
        if (!sockets.has(side)) {
            continue;
        }
        const NodePath path = targets.sockets.get(side, NodePath());
        if (path.is_empty()) {
            result.error = String("The preview rig has no ") + side + " weapon socket.";
            return result;
        }
        if (!write_tracks(animation, path, times, sockets[side])) {
            result.error = String("The ") + side + " weapon socket contains an invalid transform.";
            return result;
        }
        animation->set_meta(StringName(String(side) + "_socket_key_times"), times);
    }

    const Array camera = clip.get("camera", Array());
    if (!camera.is_empty() && !targets.camera.is_empty()) {
        const int track = animation->add_track(Animation::TYPE_VALUE);
        animation->track_set_path(track, targets.camera);
        animation->value_track_set_update_mode(track, Animation::UPDATE_CONTINUOUS);
        for (int64_t index = 0; index < times.size(); ++index) {
            Transform3D pose;
            if (!decode_transform(camera[index], pose)) {
                result.error = "The camera contains an invalid transform at " + String::num(times[index], 6) + " s.";
                return result;
            }
            animation->track_insert_key(track, times[index], pose);
        }
    }

    const Array poses = clip.get("poses", Array());
    const TypedArray<NodePath> paths = poses.is_empty() ? TypedArray<NodePath>() : match_pose(joints, targets.joints);
    if (!paths.is_empty()) {
        for (int64_t index = 0; index < paths.size(); ++index) {
            const NodePath path = paths[index];
            if (!path.is_empty() && !write_tracks(animation, path, times, poses, index)) {
                const Dictionary row = joints[index];
                result.error = "Joint " + String(row["name"]) + " contains an invalid transform.";
                return result;
            }
        }
        animation->set_meta("viewer_pose_track", true);
        result.pose_bound = true;
    }
    const Array markers = clip.get("markers", Array());
    for (const Variant &entry : markers) {
        const Dictionary marker = entry;
        animation->add_marker(StringName(marker["name"]), double(marker["time"]));
    }
    result.resource = animation;
    return result;
}

/// Replace characters Godot disallows in animation and animation library keys.
String clean_key(const String &name) {
    return name.replace("/", "_").replace(":", "_").replace(",", "_").replace("[", "_");
}

/// Generate a readable name without changing an unrelated animation with the same leaf.
StringName unique_clip_name(const Ref<AnimationLibrary> &library, const String &stem) {
    String candidate = stem;
    for (int suffix = 2; library->has_animation(candidate); ++suffix) {
        candidate = stem + String("_") + String::num_int64(suffix);
    }
    return StringName(candidate);
}

} // namespace

Dictionary ViewerClipImport::inspect(const String &path) {
    const Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
    if (file.is_null()) {
        return failure("Could not open the clip pack. " + UtilityFunctions::error_string(FileAccess::get_open_error()));
    }
    Ref<JSON> parser;
    parser.instantiate();
    if (parser->parse(file->get_as_text()) != OK) {
        return failure("Invalid clip pack JSON at line " + String::num_int64(parser->get_error_line()) +
                ". " + parser->get_error_message());
    }
    const Variant data = parser->get_data();
    if (data.get_type() != Variant::DICTIONARY) {
        return failure("The clip pack must contain a JSON object.");
    }
    Dictionary pack = data;
    const Variant version = pack.get("version", Variant());
    if (pack.get("format", Variant()) != Variant(format_name) || !finite_number(version) ||
            double(version) != format_version || pack.get("axes", Variant()) != Variant("godot")) {
        return failure("Choose a version 1 Viewer clip pack in Godot coordinates.");
    }
    const Variant rig_field = pack.get("rig", Variant());
    if (rig_field.get_type() != Variant::DICTIONARY) {
        return failure("The clip pack has an invalid rig header.");
    }
    const Dictionary rig = rig_field;
    const Variant rows_field = rig.get("nodes", Variant());
    if (rig.get("name", Variant()).get_type() != Variant::STRING || rows_field.get_type() != Variant::ARRAY) {
        return failure("The clip pack has an invalid rig header.");
    }
    const Array rows = rows_field;
    const String rig_error = validate_rig(rows);
    if (!rig_error.is_empty()) {
        return failure(rig_error);
    }
    const Variant clips_field = pack.get("clips", Variant());
    if (clips_field.get_type() != Variant::ARRAY || Array(clips_field).is_empty()) {
        return failure("The clip pack contains no animations.");
    }
    const Array clips = clips_field;
    for (int64_t index = 0; index < clips.size(); ++index) {
        const String fallback = "Clip " + String::num_int64(index + 1);
        if (clips[index].get_type() != Variant::DICTIONARY) {
            return failure(fallback + String(" must contain an animation object."));
        }
        const Dictionary clip = clips[index];
        PackedFloat64Array times;
        const String clip_error = validate_clip(clip, rows.size(), times);
        if (!clip_error.is_empty()) {
            const Variant name = clip.get("name", Variant());
            return failure((nonempty_text(name) ? String(name) : fallback) + ": " + clip_error);
        }
    }
    pack["error"] = "";
    return pack;
}

String ViewerClipImport::clip_label(const String &source_name) {
    const String label = source_name.replace("\\", "/").get_file().trim_suffix(".animation").strip_edges();
    return label.is_empty() ? String("Animation") : label;
}

String ViewerClipImport::suggested_library_name(AnimationPlayer *player, const Dictionary &pack) {
    const Array clips = pack.get("clips", Array());
    Dictionary sets;
    for (const Variant &entry : clips) {
        const Dictionary clip = entry;
        const String weapon_set = clip.get("weapon_set", "Unclassified");
        sets[weapon_set.is_empty() ? String("Unclassified") : weapon_set] = true;
    }
    String stem = "vermintide";
    if (sets.size() == 1 && !sets.has("Unclassified")) {
        const String weapon_set = sets.keys()[0];
        const String cleaned = clean_key(weapon_set.to_snake_case()).strip_edges();
        if (!cleaned.is_empty()) {
            stem = cleaned;
        }
    }
    String candidate = stem;
    for (int suffix = 2; player && player->has_animation_library(candidate); ++suffix) {
        candidate = stem + "_" + String::num_int64(suffix);
    }
    return candidate;
}

bool ViewerClipImport::can_import(Node *edited_scene, AnimationPlayer *player, Camera3D *preferred_camera) {
    if (!edited_scene || !player || (edited_scene != player && player->get_owner() != edited_scene)) {
        return false;
    }
    Node *rig = player->get_node_or_null(player->get_root_node());
    return rig && find_import_camera(rig, preferred_camera);
}

String ViewerClipImport::destination_error(AnimationPlayer *player, const StringName &library_name, bool create_library) {
    if (!player) {
        return "Select the original preview player before importing.";
    }
    if (create_library) {
        const String key = library_name;
        if (key.strip_edges().is_empty()) {
            return "Enter a library name.";
        }
        if (key != clean_key(key)) {
            return "Library names cannot contain slash, colon, comma, or opening bracket.";
        }
        if (player->has_animation_library(library_name)) {
            return "That library already exists. Choose it under Existing library.";
        }
    } else if (!player->has_animation_library(library_name)) {
        return "Choose an existing animation library.";
    }
    return {};
}

Dictionary ViewerClipImport::commit(Node *edited_scene, AnimationPlayer *player, Camera3D *preferred_camera,
        EditorUndoRedoManager *undo, const Dictionary &pack, const StringName &library_name, bool create_library,
        const PackedInt32Array &indices) {
    const String destination_problem = destination_error(player, library_name, create_library);
    if (!destination_problem.is_empty()) {
        return failure(destination_problem);
    }
    if (!undo) {
        return failure("Editor undo history is not available.");
    }
    const ImportTargets targets = resolve_targets(edited_scene, player, preferred_camera);
    if (targets.sockets.is_empty()) {
        return failure("Open the original preview player scene with compatible weapon sockets.");
    }
    const String pack_error = pack.get("error", "");
    if (!pack_error.is_empty()) {
        return failure(pack_error);
    }
    const Array clips = pack.get("clips", Array());
    const Dictionary rig = pack.get("rig", Dictionary());
    const Array joints = rig.get("nodes", Array());
    if (clips.is_empty()) {
        return failure("Choose a Viewer clip pack before importing.");
    }
    const String rig_error = validate_rig(joints);
    if (!rig_error.is_empty()) {
        return failure(rig_error);
    }
    for (int64_t index = 0; index < indices.size(); ++index) {
        if (indices[index] < 0 || indices[index] >= clips.size()) {
            return failure("A selected clip is no longer in the clip pack.");
        }
    }

    const Ref<AnimationLibrary> previous = create_library ? Ref<AnimationLibrary>() :
            player->get_animation_library(library_name);
    Ref<AnimationLibrary> updated;
    if (previous.is_valid()) {
        updated = previous->duplicate(false);
    } else {
        updated.instantiate();
    }
    Dictionary seen;
    const TypedArray<StringName> names = updated->get_animation_list();
    for (int64_t index = 0; index < names.size(); ++index) {
        const Ref<Animation> saved = updated->get_animation(names[index]);
        const String id = saved->get_meta(source_id_key, "");
        if (!id.is_empty()) {
            seen[id] = true;
        }
    }

    int added = 0;
    int skipped = 0;
    int sockets_only = 0;
    const int64_t selected = indices.is_empty() ? clips.size() : indices.size();
    for (int64_t index = 0; index < selected; ++index) {
        const Variant row = clips[indices.is_empty() ? index : indices[index]];
        if (row.get_type() != Variant::DICTIONARY) {
            return failure("A selected clip must be an animation object.");
        }
        const Dictionary clip = row;
        const String id = clip.get("id", "");
        if (seen.has(id)) {
            ++skipped;
            continue;
        }
        const PreparedClip prepared = prepare_clip(clip, joints, targets);
        const String label = clip_label(clip.get("name", ""));
        if (prepared.resource.is_null()) {
            return failure(label + String(": ") + prepared.error);
        }
        const StringName name = unique_clip_name(updated, clean_key(label));
        if (updated->add_animation(name, prepared.resource) != OK) {
            return failure("Could not add " + String(name) + " to the animation library.");
        }
        seen[id] = true;
        ++added;
        if (!prepared.pose_bound) {
            ++sockets_only;
        }
    }
    if (added == 0) {
        return failure("All selected clips are already in this library.");
    }

    undo->create_action("Import Viewer Animation Clips", UndoRedo::MERGE_DISABLE, player);
    if (previous.is_null()) {
        undo->add_do_method(player, "add_animation_library", library_name, updated);
        undo->add_undo_method(player, "remove_animation_library", library_name);
    } else {
        const StringName property(String("libraries/") + String(library_name));
        undo->add_do_property(player, property, updated);
        undo->add_undo_property(player, property, previous);
    }
    undo->commit_action();

    const String destination = library_name.is_empty() ? String("Global") : String(library_name);
    String message = "Imported " + String::num_int64(added) + " clips into " + destination + ".";
    if (skipped > 0) {
        message += " Skipped " + String::num_int64(skipped) + " existing clips.";
    }
    if (sockets_only > 0) {
        message += " " + String::num_int64(sockets_only) + " clips use socket preview.";
    }
    Dictionary output;
    output["error"] = "";
    output["message"] = message;
    output["imported"] = added;
    output["skipped"] = skipped;
    output["sockets_only"] = sockets_only;
    return output;
}

} // namespace crimson::weapon_animation

#endif
