// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "animation_preview.hpp"

#ifdef DEBUG_ENABLED

#include "animation_preview_overlay.hpp"

#include <godot_cpp/classes/animation_library.hpp>
#include <godot_cpp/classes/animation_player.hpp>
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/classes/sub_viewport.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/core/object.hpp>

#include <algorithm>
#include <cmath>

namespace crimson::weapon_animation {
using namespace godot;

namespace {

constexpr double CONTEXT_SECONDS = 0.25;

// Resolve an editor-owned node safely even after the scene tree retires it.
template <class T>
T *resolve(ObjectID id) {
    return id.is_valid() ? Object::cast_to<T>(ObjectDB::get_instance(static_cast<uint64_t>(id))) : nullptr;
}

// Remove immediately so rebuilding the preview can reuse the same child names.
void retire(Node *node) {
    if (!node) {
        return;
    }
    node->queue_free();
    if (Node *parent = node->get_parent()) {
        parent->remove_child(node);
    }
}

// Accept a real clip span before any sampling or trim arithmetic.
bool playable(const Ref<Animation> &clip) {
    return clip.is_valid() && std::isfinite(clip->get_length()) && clip->get_length() > 0;
}

// Accept pose channels only, including transform properties authored as value tracks.
bool transform_track(const Ref<Animation> &clip, int index) {
    if (!clip->track_is_enabled(index) || clip->track_get_key_count(index) == 0) {
        return false;
    }
    const NodePath path = clip->track_get_path(index);
    const auto type = clip->track_get_type(index);
    if (path.get_subname_count() == 0) {
        return type == Animation::TYPE_POSITION_3D || type == Animation::TYPE_ROTATION_3D ||
                type == Animation::TYPE_SCALE_3D;
    }
    if (type != Animation::TYPE_VALUE || path.get_subname_count() != 1) {
        return false;
    }
    const StringName property = path.get_subname(0);
    return property == StringName("transform") || property == StringName("basis") ||
            property == StringName("position") || property == StringName("quaternion") ||
            property == StringName("rotation") || property == StringName("rotation_degrees") ||
            property == StringName("scale");
}

// Resolve the source track's node independently of its serialized property suffix.
Node *track_node(Node *root, const NodePath &path) {
    return root->get_node_or_null(NodePath(String(path.get_concatenated_names())));
}

// Reject out-of-range trims without allowing invalid data to reach Godot.
bool valid_join(double exit, double entry, double overlap, double outgoing_length, double incoming_length) {
    return std::isfinite(exit) && std::isfinite(entry) && std::isfinite(overlap) && overlap >= 0 &&
            exit >= 0 && exit <= outgoing_length && entry >= 0 && entry <= incoming_length;
}

// Fit adjacent crossfades inside each clip's actual trimmed playback interval.
void fit_overlaps(const std::vector<double> &starts, const std::vector<double> &ends,
        std::vector<double> &overlaps) {
    const size_t count = overlaps.size();
    std::vector<double> limits(count, 1.0);
    for (size_t i = 0; i < count; ++i) {
        const size_t next = (i + 1) % count;
        overlaps[i] = std::min({overlaps[i], ends[i] - starts[i], ends[next] - starts[next]});
    }
    for (size_t i = 0; i < count; ++i) {
        const double total = overlaps[(i + count - 1) % count] + overlaps[i];
        if (total > 0) {
            limits[i] = std::min(1.0, (ends[i] - starts[i]) / total);
        }
    }
    for (size_t i = 0; i < count; ++i) {
        overlaps[i] *= std::min(limits[i], limits[(i + 1) % count]);
    }
}

} // namespace

Camera3D *AnimationPreview::find_camera(AnimationPlayer *player, const Ref<Animation> &clip) {
    if (!player || !playable(clip)) {
        return nullptr;
    }
    Node *rig = player->get_node_or_null(player->get_root());
    if (!rig) {
        return nullptr;
    }
    Camera3D *result = nullptr;
    for (int i = 0; i < clip->get_track_count(); ++i) {
        if (!transform_track(clip, i)) {
            continue;
        }
        const NodePath path = clip->track_get_path(i);
        const auto type = clip->track_get_type(i);
        if (type != Animation::TYPE_POSITION_3D && (type != Animation::TYPE_VALUE ||
                path.get_concatenated_subnames() != StringName("position"))) {
            continue;
        }
        Node *target = track_node(rig, path);
        Camera3D *parent = target ? Object::cast_to<Camera3D>(target->get_parent()) : nullptr;
        if (parent && result && parent != result) {
            return nullptr;
        }
        if (parent) {
            result = parent;
        }
    }
    return result;
}

AnimationPreview::~AnimationPreview() {
    clear();
    if (AnimationPreviewOverlay *surface = resolve<AnimationPreviewOverlay>(overlay)) {
        surface->bind(nullptr);
        retire(surface);
    }
}

void AnimationPreview::attach(SubViewport *owner) {
    clear();
    viewport = owner ? ObjectID(owner->get_instance_id()) : ObjectID();
}

void AnimationPreview::attach_overlay(Control *holder) {
    if (!holder) {
        return;
    }
    if (AnimationPreviewOverlay *previous = resolve<AnimationPreviewOverlay>(overlay)) {
        previous->bind(nullptr);
        retire(previous);
    }
    auto *surface = memnew(AnimationPreviewOverlay);
    surface->set_name("AnimationPoseOverlay");
    holder->add_child(surface);
    surface->set_anchors_and_offsets_preset(Control::PRESET_FULL_RECT);
    surface->bind(this);
    overlay = ObjectID(surface->get_instance_id());
}

void AnimationPreview::clear() {
    if (AnimationPreviewOverlay *surface = resolve<AnimationPreviewOverlay>(overlay)) {
        surface->reset_interaction();
    }
    for (const Ghost &ghost : ghosts) {
        retire(resolve<Node3D>(ghost.root));
    }
    ghosts.clear();
    retire(resolve<Camera3D>(orbit_camera));
    orbit_camera = ObjectID();
    for (const Source &source : sources) {
        retire(resolve<AnimationPlayer>(source.sampler));
    }
    retire(resolve<Camera3D>(camera));
    camera = ObjectID();
    source_camera = ObjectID();
    primary_preview_clip.unref();
    comparison_preview_clip.unref();
    targets.clear();
    trails.clear();
    sources.clear();
    spans.clear();
    pose_nodes.clear();
    clip_bands.clear();
    blend_bands.clear();
    length = 0;
    time = 0;
    looping = false;
    redraw_overlay();
}

bool AnimationPreview::create_camera(Camera3D *original) {
    SubViewport *stage = resolve<SubViewport>(viewport);
    if (!original || !stage || !stage->is_inside_tree()) {
        return false;
    }
    Camera3D *copy = Object::cast_to<Camera3D>(original->duplicate(0));
    if (!copy) {
        return false;
    }
    copy->set_name("PreviewCamera");
    copy->set_transform(Transform3D());
    copy->set_environment(Ref<Environment>());
    stage->add_child(copy);
    copy->make_current();
    camera = ObjectID(copy->get_instance_id());
    source_camera = ObjectID(original->get_instance_id());
    const TypedArray<Node> markers = copy->find_children("*SocketMarker", "MeshInstance3D", true, false);
    for (int64_t i = 0; i < markers.size(); ++i) {
        if (Node3D *marker = Object::cast_to<Node3D>(markers[i])) {
            marker->hide();
        }
    }
    return true;
}

void AnimationPreview::collect_targets(AnimationPlayer *player, Camera3D *original) {
    Node *rig = player->get_node_or_null(player->get_root());
    Camera3D *copy = get_camera();
    if (!rig || !copy) {
        return;
    }
    targets.clear();
    const TypedArray<Node> nodes = original->find_children("*", "Node3D", true, false);
    for (int64_t i = 0; i < nodes.size(); ++i) {
        Node3D *node = Object::cast_to<Node3D>(nodes[i]);
        if (!node || node->get_name().is_empty()) {
            continue;
        }
        auto is_socket = [original](Node *test) {
            return test && test->get_parent() == original &&
                    (test->get_name() == StringName("WeaponControl") || test->get_name() == StringName("LeftWeaponControl"));
        };
        StringName kind;
        if (node->has_meta("native_pose_index")) {
            kind = "bone";
        } else if (is_socket(node)) {
            kind = "socket";
        } else if (is_socket(node->get_parent()) && node->has_node(NodePath("Visuals"))) {
            kind = "mount";
        }
        if (kind.is_empty()) {
            continue;
        }
        Node3D *private_node = Object::cast_to<Node3D>(copy->get_node_or_null(original->get_path_to(node)));
        if (private_node) {
            targets.push_back({rig->get_path_to(node), ObjectID(private_node->get_instance_id()), kind});
        }
    }
    if (Node *look = original->get_parent()) {
        const NodePath camera_motion(String(rig->get_path_to(look)) + ":attack_camera_motion");
        if (look->get("attack_camera_motion").get_type() == Variant::TRANSFORM3D) {
            targets.push_back({camera_motion, camera, "camera"});
        }
    }
}

Camera3D *AnimationPreview::get_camera() const {
    return resolve<Camera3D>(camera);
}

Node3D *AnimationPreview::get_preview_node(const NodePath &source_path) const {
    const auto found = std::find_if(targets.begin(), targets.end(),
            [&source_path](const Target &entry) { return entry.path == source_path; });
    return found == targets.end() ? nullptr : resolve<Node3D>(found->node);
}

Array AnimationPreview::get_pose_targets() const {
    Array rows;
    for (const Target &entry : targets) {
        Node3D *node = resolve<Node3D>(entry.node);
        if (!node) {
            continue;
        }
        Dictionary row;
        row["path"] = entry.path;
        row["name"] = entry.kind == StringName("camera") ? String("Camera Motion") : String(node->get_name());
        row["kind"] = entry.kind;
        rows.push_back(row);
    }
    return rows;
}

void AnimationPreview::set_target(const NodePath &path) {
    if (selected_target != path) {
        selected_target = path;
        redraw_overlay();
    }
}

Transform3D AnimationPreview::get_target_pose() const {
    Node3D *node = get_preview_node(selected_target);
    return node ? node->get_transform() : Transform3D();
}

void AnimationPreview::set_target_pose(const Transform3D &pose) {
    if (Node3D *node = get_preview_node(selected_target)) {
        if (pose.is_finite()) {
            node->set_transform(pose);
            redraw_overlay();
        }
    }
}

void AnimationPreview::set_edit_callbacks(std::function<void(const NodePath &)> selection,
        std::function<void(const Transform3D &)> commit) {
    target_selected = std::move(selection);
    pose_committed = std::move(commit);
}

void AnimationPreview::set_pose_mode(bool enabled) {
    if (pose_mode != enabled) {
        pose_mode = enabled;
        update_view();
    }
}

void AnimationPreview::set_gizmo_rotation(bool enabled) {
    rotate_gizmo = enabled;
    redraw_overlay();
}

void AnimationPreview::set_guides(bool sockets, bool paths) {
    show_sockets = sockets;
    show_trails = paths;
    redraw_overlay();
}

void AnimationPreview::update_view() {
    Camera3D *first_person = get_camera();
    SubViewport *stage = resolve<SubViewport>(viewport);
    if (!first_person || !stage) {
        return;
    }
    AnimationPreviewOverlay *surface = resolve<AnimationPreviewOverlay>(overlay);
    if (surface) {
        surface->reset_interaction();
    }
    if (pose_mode) {
        Camera3D *orbit = resolve<Camera3D>(orbit_camera);
        if (!orbit) {
            orbit = memnew(Camera3D);
            orbit->set_name("AnimationOrbitCamera");
            orbit->set_fov(55.0);
            orbit->set_near(0.025);
            orbit->set_far(first_person->get_far());
            stage->add_child(orbit);
            orbit_camera = ObjectID(orbit->get_instance_id());
            if (surface) {
                surface->frame_pose();
            }
        }
        orbit->make_current();
    } else {
        first_person->make_current();
    }
    redraw_overlay();
}

void AnimationPreview::redraw_overlay() {
    if (AnimationPreviewOverlay *surface = resolve<AnimationPreviewOverlay>(overlay)) {
        surface->queue_redraw();
    }
}

void AnimationPreview::set_onion(int past, int future, double step) {
    onion_past = std::clamp(past, 0, 3);
    onion_future = std::clamp(future, 0, 3);
    onion_step = std::isfinite(step) ? std::max(0.0, step) : 0.0;
    update_ghosts();
    redraw_overlay();
}

void AnimationPreview::set_playing(bool enabled) {
    if (playing != enabled) {
        playing = enabled;
        update_ghosts();
        redraw_overlay();
    }
}

void AnimationPreview::set_comparison(AnimationPlayer *player, const Ref<Animation> &clip, double seconds) {
    const ObjectID owner = player ? ObjectID(player->get_instance_id()) : ObjectID();
    if (comparison_player != owner || comparison_source != clip) {
        comparison_preview_clip.unref();
    }
    comparison_player = owner;
    comparison_source = clip;
    comparison_time = std::isfinite(seconds) ? seconds : 0.0;
    if (comparison_preview_clip.is_null() && player && playable(clip)) {
        Camera3D *original = resolve<Camera3D>(source_camera);
        if (original && original == find_camera(player, clip)) {
            comparison_preview_clip = remap(player, original, clip);
        }
    }
    update_ghosts();
    redraw_overlay();
}

void AnimationPreview::update_ghosts() {
    size_t count = 0;
    if (primary_preview_clip.is_valid()) {
        if (!playing) {
            const double step = std::max(0.001, onion_step > 0 ? onion_step : primary_preview_clip->get_step());
            for (int i = onion_past; i >= 1; --i) {
                const double at = time - step * i;
                if (at >= 0) {
                    show_ghost(count++, primary_preview_clip, at, Color(0.94, 0.45, 0.52, 0.22));
                }
            }
            for (int i = onion_future; i >= 1; --i) {
                const double at = time + step * i;
                if (at <= length) {
                    show_ghost(count++, primary_preview_clip, at, Color(0.44, 0.84, 0.57, 0.22));
                }
            }
        }
        if (comparison_preview_clip.is_valid() && comparison_preview_clip->get_track_count() > 0) {
            show_ghost(count++, comparison_preview_clip, comparison_time, Color(0.78, 0.62, 0.96, 0.46));
        }
    }
    for (size_t i = count; i < ghosts.size(); ++i) {
        if (Node3D *root = resolve<Node3D>(ghosts[i].root)) {
            root->hide();
        }
    }
}

void AnimationPreview::show_ghost(size_t index, const Ref<Animation> &clip, double seconds, const Color &tint) {
    SubViewport *stage = resolve<SubViewport>(viewport);
    Camera3D *first_person = get_camera();
    if (!stage || !first_person) {
        return;
    }
    if (index >= ghosts.size()) {
        ghosts.resize(index + 1);
    }
    Ghost &ghost = ghosts[index];
    Node3D *root = resolve<Node3D>(ghost.root);
    AnimationPlayer *sampler = resolve<AnimationPlayer>(ghost.player);
    if (!root) {
        Camera3D *rig = Object::cast_to<Camera3D>(first_person->duplicate(0));
        if (!rig) {
            return;
        }
        rig->set_current(false);
        rig->set_name("PreviewCamera");
        root = memnew(Node3D);
        root->add_child(rig);
        sampler = memnew(AnimationPlayer);
        sampler->set_callback_mode_process(AnimationMixer::ANIMATION_CALLBACK_MODE_PROCESS_MANUAL);
        sampler->set_auto_capture(false);
        root->add_child(sampler);
        stage->add_child(root);
        ghost.root = ObjectID(root->get_instance_id());
        ghost.player = ObjectID(sampler->get_instance_id());
        ghost.tint = Color();
        ghost.clip.unref();
    }
    root->show();
    if (ghost.tint != tint) {
        Ref<StandardMaterial3D> material;
        material.instantiate();
        material->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
        material->set_shading_mode(BaseMaterial3D::SHADING_MODE_UNSHADED);
        material->set_albedo(tint);
        const TypedArray<Node> meshes = root->find_children("*", "MeshInstance3D", true, false);
        for (int64_t i = 0; i < meshes.size(); ++i) {
            if (auto *mesh = Object::cast_to<MeshInstance3D>(meshes[i])) {
                mesh->set_material_override(material);
                mesh->set_cast_shadows_setting(GeometryInstance3D::SHADOW_CASTING_SETTING_OFF);
            }
        }
        ghost.tint = tint;
    }
    const double at = std::clamp(seconds, 0.0, double(clip->get_length()));
    if (ghost.clip == clip && ghost.sampled_time == at) {
        return;
    }
    Node *ghost_camera = root->get_node_or_null(NodePath("PreviewCamera"));
    for (const PoseNode &entry : pose_nodes) {
        if (Node3D *live = resolve<Node3D>(entry.node)) {
            const NodePath path = first_person->get_path_to(live);
            if (auto *node = Object::cast_to<Node3D>(ghost_camera->get_node_or_null(path))) {
                node->set_transform(entry.bind);
            }
        }
    }
    if (ghost.clip != clip) {
        const StringName library_name;
        sampler->stop(true);
        if (sampler->has_animation_library(library_name)) {
            sampler->remove_animation_library(library_name);
        }
        Ref<AnimationLibrary> library;
        library.instantiate();
        const StringName sample_key("pose");
        library->add_animation(sample_key, clip);
        sampler->add_animation_library(library_name, library);
        sampler->play(sample_key, 0.0);
        ghost.clip = clip;
    }
    sampler->seek(at, true, true);
    ghost.sampled_time = at;
}

void AnimationPreview::build_trails(const Ref<Animation> &clip) {
    trails.clear();
    for (const Target &target : targets) {
        Node3D *socket = resolve<Node3D>(target.node);
        if (target.kind != StringName("socket") || !socket) {
            continue;
        }
        Trail trail = {target.node, {}, socket->get_name() == StringName("LeftWeaponControl")};
        const String socket_path = String("PreviewCamera/") + String(socket->get_name());
        int track = clip->find_track(NodePath(socket_path), Animation::TYPE_POSITION_3D);
        const bool typed = track >= 0;
        if (!typed) {
            track = clip->find_track(NodePath(socket_path + String(":position")), Animation::TYPE_VALUE);
        }
        if (track >= 0) {
            const Variant authored = clip->get_meta(trail.left ? "left_socket_key_times" : "right_socket_key_times", Array());
            PackedFloat64Array sample_times;
            if (authored.get_type() == Variant::PACKED_FLOAT64_ARRAY || authored.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
                sample_times = authored;
            }
            if (sample_times.is_empty()) {
                for (int i = 0; i < clip->track_get_key_count(track); ++i) {
                    sample_times.push_back(clip->track_get_key_time(track, i));
                }
            }
            for (int64_t i = 0; i < sample_times.size(); ++i) {
                const double at = sample_times[i];
                const Variant point = typed ? Variant(clip->position_track_interpolate(track, at)) : clip->value_track_interpolate(track, at);
                if (point.get_type() == Variant::VECTOR3 && Vector3(point).is_finite()) {
                    trail.points.push_back(point);
                }
            }
        }
        trails.push_back(std::move(trail));
    }
}

Ref<Animation> AnimationPreview::remap(AnimationPlayer *player, Camera3D *original,
        const Ref<Animation> &clip) {
    SubViewport *stage = resolve<SubViewport>(viewport);
    Node *rig = player->get_node_or_null(player->get_root());
    Ref<Animation> copy = clip->duplicate();
    copy->set_loop_mode(Animation::LOOP_NONE);
    for (int i = copy->get_track_count() - 1; i >= 0; --i) {
        const NodePath path = copy->track_get_path(i);
        Node *target = track_node(rig, path);
        if (!target || !transform_track(copy, i)) {
            if (target == original->get_parent() && copy->track_is_enabled(i) &&
                    copy->track_get_key_count(i) > 0 && copy->track_get_type(i) == Animation::TYPE_VALUE &&
                    path.get_concatenated_subnames() == StringName("attack_camera_motion")) {
                copy->track_set_path(i, NodePath("PreviewCamera:transform"));
            } else {
                copy->remove_track(i);
            }
            continue;
        }
        if (!original->is_ancestor_of(target)) {
            copy->remove_track(i);
            continue;
        }
        String mapped = String("PreviewCamera/") + String(original->get_path_to(target));
        if (path.get_subname_count() > 0) {
            mapped += String(":") + String(path.get_concatenated_subnames());
        }
        const NodePath mapped_path(mapped);
        Node3D *node = Object::cast_to<Node3D>(track_node(stage, mapped_path));
        if (!node) {
            copy->remove_track(i);
            continue;
        }
        copy->track_set_path(i, mapped_path);
        const ObjectID id(node->get_instance_id());
        const auto existing = std::find_if(pose_nodes.begin(), pose_nodes.end(),
                [id](const PoseNode &entry) { return entry.node == id; });
        if (existing == pose_nodes.end()) {
            pose_nodes.push_back({id, node->get_transform(), Transform3D()});
        }
    }
    return copy;
}

bool AnimationPreview::add_source(const Ref<Animation> &clip, int index, int lane) {
    SubViewport *stage = resolve<SubViewport>(viewport);
    Camera3D *private_camera = resolve<Camera3D>(camera);
    if (!stage || !private_camera || clip.is_null() || clip->get_track_count() == 0) {
        return false;
    }
    if (pose_nodes.empty() || pose_nodes.front().node != camera) {
        pose_nodes.insert(pose_nodes.begin(), {camera, Transform3D(), Transform3D()});
    }
    AnimationPlayer *sampler = memnew(AnimationPlayer);
    sampler->set_callback_mode_process(AnimationMixer::ANIMATION_CALLBACK_MODE_PROCESS_MANUAL);
    sampler->set_auto_capture(false);
    Ref<AnimationLibrary> library;
    library.instantiate();
    const StringName sample_key("pose");
    library->add_animation(sample_key, clip);
    sampler->add_animation_library(StringName(), library);
    stage->add_child(sampler);
    sampler->play(sample_key, 0.0);
    sources.push_back({ObjectID(sampler->get_instance_id()), clip->get_length(), index, lane});
    return true;
}

bool AnimationPreview::load_clip(AnimationPlayer *player, const StringName &key, bool loop) {
    const Ref<Animation> clip = player && player->has_animation(key) ? player->get_animation(key) : Ref<Animation>();
    return load_clip_resource(player, clip, loop);
}

bool AnimationPreview::load_clip_resource(AnimationPlayer *player, const Ref<Animation> &clip, bool loop) {
    clear();
    Camera3D *original = find_camera(player, clip);
    if (!create_camera(original)) {
        return false;
    }
    primary_preview_clip = remap(player, original, clip);
    if (!add_source(primary_preview_clip, 0, 0)) {
        clear();
        return false;
    }
    collect_targets(player, original);
    build_trails(primary_preview_clip);
    looping = loop;
    append_span(0, 0, clip->get_length());
    update_view();
    if (AnimationPlayer *owner = resolve<AnimationPlayer>(comparison_player)) {
        set_comparison(owner, comparison_source, comparison_time);
    }
    seek(0);
    return true;
}

bool AnimationPreview::load_join(AnimationPlayer *player, const Dictionary &join, int outgoing, int incoming) {
    clear();
    const StringName outgoing_key = join.get("outgoing_key", StringName());
    const StringName incoming_key = join.get("incoming_key", StringName());
    if (!player || !player->has_animation(outgoing_key) || !player->has_animation(incoming_key)) {
        return false;
    }
    const Ref<Animation> first = player->get_animation(outgoing_key);
    const Ref<Animation> second = player->get_animation(incoming_key);
    Camera3D *original = find_camera(player, first);
    if (!original || find_camera(player, second) != original) {
        return false;
    }
    const double exit = join.get("exit_time", first->get_length());
    const double entry = join.get("entry_time", 0.0);
    const double blend = join.get("blend_duration", 0.0);
    if (!valid_join(exit, entry, blend, first->get_length(), second->get_length())) {
        return false;
    }
    const double incoming_available = second->get_length() - entry;
    const double overlap = std::min({exit, incoming_available, blend});
    const double before = std::min(CONTEXT_SECONDS, exit - overlap);
    const double after = std::min(CONTEXT_SECONDS, incoming_available - overlap);
    if (before + overlap + after <= 0 || !create_camera(original) ||
            !add_source(remap(player, original, first), outgoing, 0) ||
            !add_source(remap(player, original, second), incoming, 1)) {
        clear();
        return false;
    }
    looping = true;
    append_span(0, exit - overlap - before, before, overlap, 1, entry);
    append_span(1, entry + overlap, after);
    seek(0);
    return true;
}

bool AnimationPreview::load_combo(AnimationPlayer *player, const TypedArray<StringName> &keys,
        const Array &joins, bool loop) {
    clear();
    const int count = keys.size();
    const int join_count = loop ? count : count - 1;
    if (!player || count < 2 || joins.size() != join_count) {
        return false;
    }
    std::vector<Ref<Animation>> clips;
    std::vector<double> starts(count), ends(count), overlaps(count);
    Camera3D *original = nullptr;
    clips.reserve(count);
    for (int i = 0; i < count; ++i) {
        const StringName key = keys[i];
        const Ref<Animation> clip = player->has_animation(key) ? player->get_animation(key) : Ref<Animation>();
        Camera3D *target = find_camera(player, clip);
        if (!target || (original && original != target)) {
            return false;
        }
        original = target;
        ends[i] = clip->get_length();
        clips.push_back(clip);
    }
    for (int i = 0; i < join_count; ++i) {
        const Dictionary join = joins[i];
        const int next = (i + 1) % count;
        const double exit = join.get("exit_time", ends[i]);
        const double entry = join.get("entry_time", 0.0);
        const double blend = join.get("blend_duration", 0.0);
        if (!valid_join(exit, entry, blend, ends[i], clips[next]->get_length())) {
            return false;
        }
        ends[i] = exit;
        starts[next] = entry;
        overlaps[i] = blend;
    }
    double duration = 0;
    for (int i = 0; i < count; ++i) {
        const double window = ends[i] - starts[i];
        if (window < 0) {
            return false;
        }
        duration += window;
    }
    if (duration <= 0 || !create_camera(original)) {
        return false;
    }
    for (int i = 0; i < count; ++i) {
        if (!add_source(remap(player, original, clips[i]), i, i % 2)) {
            clear();
            return false;
        }
    }
    fit_overlaps(starts, ends, overlaps);
    looping = loop;
    for (int i = 0; i < count; ++i) {
        const int previous = (i + count - 1) % count;
        const int next = (i + 1) % count;
        const double start = starts[i] + overlaps[previous];
        const double solo = std::max(0.0, ends[i] - start - overlaps[i]);
        append_span(i, start, solo, overlaps[i], i < join_count ? next : -1, starts[next]);
    }
    seek(0);
    return true;
}

void AnimationPreview::append_span(int outgoing, double outgoing_start, double solo, double overlap,
        int incoming, double incoming_start) {
    const double overlap_start = length + solo;
    const double end = overlap_start + overlap;
    spans.push_back({outgoing, incoming, length, overlap_start, end, outgoing_start, incoming_start});
    const Source &source = sources[outgoing];
    append_clip_band(source.index, source.lane, length, end);
    if (incoming >= 0) {
        blend_bands.push_back({source.index, overlap_start, end});
        append_clip_band(sources[incoming].index, 1 - source.lane, overlap_start, end);
    }
    length = end;
}

void AnimationPreview::append_clip_band(int index, int lane, double start, double end) {
    if (end <= start) {
        return;
    }
    if (!clip_bands.empty()) {
        ClipBand &last = clip_bands.back();
        if (last.index == index && last.end == start && last.lane == lane) {
            last.end = end;
            return;
        }
    }
    clip_bands.push_back({index, lane, start, end});
}

void AnimationPreview::seek(double seconds) {
    if (length <= 0 || !std::isfinite(seconds) || !resolve<Camera3D>(camera)) {
        return;
    }
    time = std::clamp(seconds, 0.0, length);
    const auto current = std::upper_bound(spans.begin(), spans.end(), time,
            [](double at, const Span &span) { return at < span.end; });
    apply_span(current == spans.end() ? spans.back() : *current);
    update_ghosts();
    redraw_overlay();
}

void AnimationPreview::advance(double delta) {
    if (length > 0 && std::isfinite(delta)) {
        const double next = time + delta;
        const double wrapped = looping ? std::fmod(next, length) : next;
        seek(looping && wrapped < 0 ? wrapped + length : wrapped);
    }
}

void AnimationPreview::sample(int strand, double seconds) {
    const Source &source = sources[strand];
    AnimationPlayer *sampler = resolve<AnimationPlayer>(source.sampler);
    if (!sampler) {
        return;
    }
    for (const PoseNode &entry : pose_nodes) {
        if (Node3D *node = resolve<Node3D>(entry.node)) {
            if (node->get_transform() != entry.bind) {
                node->set_transform(entry.bind);
            }
        }
    }
    sampler->seek(std::clamp(seconds, 0.0, source.length), true, true);
}

void AnimationPreview::apply_span(const Span &span) {
    const double outgoing_time = span.outgoing_start + time - span.start;
    if (span.incoming < 0 || time < span.blend || (time == span.blend && span.end > span.blend)) {
        sample(span.outgoing, outgoing_time);
        return;
    }
    const double incoming_time = span.incoming_start + time - span.blend;
    if (time >= span.end) {
        sample(span.incoming, incoming_time);
        return;
    }
    sample(span.outgoing, outgoing_time);
    for (PoseNode &entry : pose_nodes) {
        if (Node3D *node = resolve<Node3D>(entry.node)) {
            entry.outgoing = node->get_transform();
        }
    }
    sample(span.incoming, incoming_time);
    const double weight = (time - span.blend) / (span.end - span.blend);
    for (const PoseNode &entry : pose_nodes) {
        if (Node3D *node = resolve<Node3D>(entry.node)) {
            node->set_transform(entry.outgoing.interpolate_with(node->get_transform(), weight));
        }
    }
}
} // namespace crimson::weapon_animation

#endif
