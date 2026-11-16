// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#ifdef DEBUG_ENABLED

#include <godot_cpp/classes/animation.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <functional>
#include <vector>

namespace godot {
class AnimationPlayer;
class Camera3D;
class Control;
class Node3D;
class SubViewport;
}

namespace crimson::weapon_animation {

class AnimationPreviewOverlay;

/// Register the private editor control that translates viewport mouse gestures into pose edits.
void register_animation_preview_overlay_type();

/// Evaluates pose-only clips on one isolated copy of the authored camera rig.
class AnimationPreview {
public:
    /// Visible clip segment on one of the two animation tracks.
    struct ClipBand {
        int index; ///< Clip's index in the authored order.
        int lane; ///< Track row, which alternates to expose overlapping poses.
        double start; ///< First second of the segment in the preview.
        double end; ///< Last second of the segment in the preview.
    };

    /// Span where both clips contribute, including zero-duration hard cuts.
    struct BlendBand {
        int index; ///< Outgoing clip's index in the authored order.
        double start; ///< First second of the overlap in the preview.
        double end; ///< Last second of the overlap in the preview.
    };

    /// Report the single camera targeted by a clip's position tracks.
    static godot::Camera3D *find_camera(godot::AnimationPlayer *player, const godot::Ref<godot::Animation> &clip);
    /// Mount the viewport that owns the preview's camera and samplers.
    void attach(godot::SubViewport *owner);
    /// Place pose navigation, picking, and gizmos over the private viewport.
    void attach_overlay(godot::Control *holder);
    /// Retire any mounted preview nodes before the workspace is destroyed.
    ~AnimationPreview();
    /// Stop playback and release the copied camera and pose samplers.
    void clear();
    /// Prepare an entire clip for precise scrubbing.
    bool load_clip(godot::AnimationPlayer *player, const godot::StringName &key, bool loop);
    /// Play a private draft associated with the given player's authored rig.
    bool load_clip_resource(godot::AnimationPlayer *player, const godot::Ref<godot::Animation> &clip, bool loop);
    /// Resolve the private first-person camera independently of the orbit view.
    godot::Camera3D *get_camera() const;
    /// Resolve a path relative to the authored AnimationPlayer root on the private rig.
    godot::Node3D *get_preview_node(const godot::NodePath &source_path) const;
    /// List weapon mounts, sockets, and meshless joints that can be keyed.
    godot::Array get_pose_targets() const;
    /// Select a target for preview-only position/rotation editing.
    void set_target(const godot::NodePath &path);
    /// Return the selected target's authored path.
    const godot::NodePath &get_target() const { return selected_target; }
    /// Read the selected target's local pose from the current evaluated frame.
    godot::Transform3D get_target_pose() const;
    /// Update the private local pose without writing to a clip resource.
    void set_target_pose(const godot::Transform3D &pose);
    /// Observe bone picking and the completion of one gizmo gesture.
    void set_edit_callbacks(std::function<void(const godot::NodePath &)> selection,
            std::function<void(const godot::Transform3D &)> commit);
    /// Switch between first person and orbit navigation.
    void set_pose_mode(bool enabled);
    /// Switch the selected local gizmo between translation and rotation.
    void set_gizmo_rotation(bool enabled);
    /// Display socket dots, authored paths, and per-key timing dots.
    void set_guides(bool sockets, bool trails);
    /// Choose how many neighboring posed samples to show in each direction.
    void set_onion(int past, int future, double step);
    /// Suppress temporal ghosts during transport playback.
    void set_playing(bool enabled);
    /// Update the independent comparison sample or clear it with a null clip.
    void set_comparison(godot::AnimationPlayer *player, const godot::Ref<godot::Animation> &clip, double time);
    /// Prepare a combo sequence from key order and resolved join dictionaries.
    bool load_combo(godot::AnimationPlayer *player, const godot::TypedArray<godot::StringName> &keys,
            const godot::Array &joins, bool loop);
    /// Prepare one resolved join with short context on either side.
    bool load_join(godot::AnimationPlayer *player, const godot::Dictionary &join, int outgoing, int incoming);
    /// Sample a precise preview time, clamped to the playable range.
    void seek(double seconds);
    /// Advance the preview and repeat only when the active mode permits looping.
    void advance(double delta);
    /// Return the current playhead in preview seconds.
    double get_time() const { return time; }
    /// Return the duration of the active schedule.
    double get_length() const { return length; }
    /// Return whether the schedule repeats.
    bool is_looping() const { return looping; }
    /// Return the visible playback lanes, including trimmed and overlapped ranges.
    const std::vector<ClipBand> &get_clip_bands() const { return clip_bands; }
    /// Return the exact effective overlap ranges used by the evaluator.
    const std::vector<BlendBand> &get_blend_bands() const { return blend_bands; }

private:
    friend class AnimationPreviewOverlay;

    /// One safe, private animation strand.
    struct Source {
        godot::ObjectID sampler; ///< Private player that owns only its filtered pose clip.
        double length; ///< Length of the imported animation in seconds.
        int index; ///< Original combo clip index.
        int lane; ///< Display lane to use outside transitions.
    };

    /// Solo section followed by an optional transition.
    struct Span {
        int outgoing; ///< Source active for the entire span.
        int incoming; ///< Secondary source, or -1 for a solo span.
        double start; ///< Preview time where this span begins.
        double blend; ///< Preview time where the overlap begins.
        double end; ///< Preview time where this span ends.
        double outgoing_start; ///< Local outgoing clip time at the start of this span.
        double incoming_start; ///< Local incoming clip time at the start of the overlap.
    };

    /// A transform to restore before sampling independent strands.
    struct PoseNode {
        godot::ObjectID node; ///< Node in the private viewport.
        godot::Transform3D bind; ///< Transform copied from the authored rig.
        godot::Transform3D outgoing; ///< Scratch sample from the first clip of a blend.
    };

    /// Editable node mapping between the authored scene and private rig.
    struct Target {
        godot::NodePath path; ///< AnimationPlayer-root-relative path.
        godot::ObjectID node; ///< Matching node in preview storage.
        godot::StringName kind; ///< Socket, mount or bone.
    };

    /// Authored socket positions in first-person camera coordinates.
    struct Trail {
        godot::ObjectID socket; ///< Private socket shown with its authored path.
        godot::PackedVector3Array points; ///< Camera-local key positions.
        bool left; ///< Which socket colors to use for paths.
    };

    /// Isolated onion/comparison render copies, kept outside the playing rig.
    struct Ghost {
        godot::ObjectID root; ///< Private scene containing a copied camera hierarchy.
        godot::ObjectID player; ///< Pose-only sampler scoped to this ghost.
        godot::Ref<godot::Animation> clip; ///< Resource currently bound to the sample.
        godot::Color tint; ///< Directional or comparison color.
        double sampled_time = -1; ///< Last evaluated time of this retained pose.
    };

    /// Install a private duplicate of the camera and its authored rig hierarchy.
    bool create_camera(godot::Camera3D *original);
    /// Collect editable sockets, mounts and asset-provided bone nodes.
    void collect_targets(godot::AnimationPlayer *player, godot::Camera3D *original);
    /// Build the socket path cache using source key times.
    void build_trails(const godot::Ref<godot::Animation> &clip);
    /// Generate a script-free pose clip whose paths address the copied rig.
    godot::Ref<godot::Animation> remap(godot::AnimationPlayer *player,
            godot::Camera3D *original, const godot::Ref<godot::Animation> &clip);
    /// Add an independently seekable sampler for a remapped clip.
    bool add_source(const godot::Ref<godot::Animation> &clip, int index, int lane);
    /// Record one interval in both the playback schedule and the timeline.
    void append_span(int outgoing, double outgoing_start, double solo, double overlap = 0,
            int incoming = -1, double incoming_start = 0);
    /// Merge adjacent segments of the same visible clip in the same lane.
    void append_clip_band(int index, int lane, double start, double end);
    /// Restore the authored pose and sample a single clip without executing events.
    void sample(int strand, double seconds);
    /// Select and sample the current span, interpolating local transforms in the overlap.
    void apply_span(const Span &span);
    /// Refresh the active neighboring and comparison poses at the paused playhead.
    void update_ghosts();
    /// Bind and sample one retained ghost.
    void show_ghost(size_t index, const godot::Ref<godot::Animation> &clip, double seconds, const godot::Color &tint);
    /// Update the active camera when the first-person or pose view changes.
    void update_view();
    /// Request the overlay to project current poses into the viewport.
    void redraw_overlay();

    godot::ObjectID viewport; ///< Viewport owned by the animation tool.
    godot::ObjectID camera; ///< Private duplicate under the viewport.
    std::vector<Source> sources; ///< Playable copied clips in preview order.
    std::vector<Span> spans; ///< Ordered non-overlapping sections.
    std::vector<PoseNode> pose_nodes; ///< Animated nodes in the private scene.
    std::vector<ClipBand> clip_bands; ///< Clip lanes projected from the same spans.
    std::vector<BlendBand> blend_bands; ///< Blend lanes projected from the same spans.
    std::vector<Target> targets; ///< Valid editor targets from the active source rig.
    std::vector<Trail> trails; ///< Socket paths and step spacing for overlay guides.
    std::vector<Ghost> ghosts; ///< Reusable onion skin and comparison samplers.
    godot::ObjectID overlay; ///< Input and drawing control tied to the viewport container.
    godot::ObjectID orbit_camera; ///< Separate camera for pose inspection.
    godot::ObjectID source_camera; ///< Authoring camera matched by the active source clip.
    godot::Ref<godot::Animation> primary_preview_clip; ///< Remapped primary pose used for neighboring skin frames.
    godot::Ref<godot::Animation> comparison_source; ///< User-selected full comparison resource.
    godot::Ref<godot::Animation> comparison_preview_clip; ///< Comparison remapped to the private rig.
    godot::ObjectID comparison_player; ///< Authored rig that owns the independent comparison.
    godot::NodePath selected_target; ///< Authored path selected in the viewport or inspector.
    std::function<void(const godot::NodePath &)> target_selected; ///< Send a picked bone or socket to the window.
    std::function<void(const godot::Transform3D &)> pose_committed; ///< Record one finished drag in the window draft.
    double comparison_time = 0; ///< Independent comparison playhead.
    double onion_step = 0; ///< Explicit sample interval, zero for the primary clip step.
    int onion_past = 0; ///< Number of earlier neighboring samples.
    int onion_future = 0; ///< Number of later neighboring samples.
    bool pose_mode = false; ///< Display bones and navigate the private orbit camera.
    bool rotate_gizmo = false; ///< True for local-axis rotation rings.
    bool show_sockets = false; ///< Draw projected weapon socket dots.
    bool show_trails = false; ///< Draw socket paths and key points.
    bool playing = false; ///< Suppress expensive neighboring samples while playing.
    double length = 0; ///< Total duration of the active schedule in seconds.
    double time = 0; ///< Current playhead position in seconds.
    bool looping = false; ///< Whether the schedule wraps after its final pose.
};

}

#endif
