// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#ifdef DEBUG_ENABLED

#include <godot_cpp/classes/control.hpp>
#include <godot_cpp/classes/input_event.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include <array>

namespace godot {
class Camera3D;
class Node3D;
}

namespace crimson::weapon_animation {

class AnimationPreview;

/// Projects private animation poses and edits their local transforms.
class AnimationPreviewOverlay final : public godot::Control {
    GDCLASS(AnimationPreviewOverlay, godot::Control)

public:
    /// Connect the overlay to the preview that owns its pose state.
    void bind(AnimationPreview *source);
    /// Clear pending interaction after the target rig is retired.
    void reset_interaction();
    /// Center the orbit camera on the current skeleton or target.
    void frame_pose();
    /// Draw or manipulate the preview without forwarding input to the scene.
    void _gui_input(const godot::Ref<godot::InputEvent> &event) override;
    /// Advance camera fly movement while the right button is held.
    void _process(double delta) override;

protected:
    /// Register this internal editor control.
    static void _bind_methods() {}
    /// Draw editor overlays and end pointer capture when the workspace hides.
    void _notification(int what);

private:
    /// One projected axis or rotation ring.
    struct Handle {
        godot::Vector3 axis; ///< World-space edit axis.
        godot::PackedVector2Array points; ///< Visible axis or ring samples.
    };

    /// Return the active camera, including orbit when Pose is active.
    godot::Camera3D *view_camera() const;
    /// Return the selected private Node3D, or null when out of context.
    godot::Node3D *selected_node() const;
    /// Convert a 3D position into this overlay's coordinates.
    bool project(godot::Camera3D *view, const godot::Vector3 &world, godot::Vector2 &screen) const;
    /// Convert this overlay's coordinates to camera viewport pixels.
    godot::Vector2 camera_pixels(godot::Camera3D *view, const godot::Vector2 &screen) const;
    /// Draw main and ghost skeletons, sockets and their timing paths.
    void draw_pose();
    /// Project eligible rig joints as selectable points and parent lines.
    void draw_joints(godot::Camera3D *view, godot::Node3D *ghost_camera, const godot::Color &ink);
    /// Draw local gizmo handles for the selected edit target.
    void draw_gizmo(godot::Camera3D *view);
    /// Pick a visible bone or socket on pointer press in Pose mode.
    void pick_target(const godot::Vector2 &screen);
    /// Try to start translation or rotation with the hovered handle.
    bool start_drag(const godot::Vector2 &screen);
    /// Preview motion along the captured axis while the pointer is down.
    void drag_to(const godot::Vector2 &screen);
    /// Complete one edit gesture in the window's draft history.
    void commit_drag();
    /// Evaluate the mouse ray against the captured translation axis.
    bool axis_parameter(const godot::Vector2 &screen, double &parameter) const;
    /// Evaluate the mouse ray against the captured rotation plane.
    bool ring_vector(const godot::Vector2 &screen, godot::Vector3 &direction) const;
    /// Adjust the pose camera orientation, center, or distance.
    void navigate(const godot::Vector2 &relative, bool shift);

    AnimationPreview *preview = nullptr; ///< Preview lifetime contains this interaction control.
    std::array<Handle, 3> handles; ///< Last drawn manipulator hit regions.
    godot::Vector3 orbit_center; ///< World-space navigation pivot.
    double orbit_radius = 1.0; ///< Distance from the orbit camera to the pivot.
    bool orbiting = false; ///< Middle pointer drag.
    bool flying = false; ///< Right pointer drag plus WASD/QE.
    bool dragging = false; ///< Active gizmo gesture.
    bool changed = false; ///< Whether a gesture produced a valid pose change.
    bool rotating = false; ///< Whether this active gesture moves a ring.
    godot::Transform3D drag_pose; ///< Original local pose at the start of the edit.
    godot::Vector3 drag_origin; ///< Original world-space handle origin.
    godot::Vector3 drag_axis; ///< World-space gesture axis.
    godot::Vector3 drag_ring_start; ///< Unit vector on the rotation plane at press.
    godot::Vector3 drag_parent_axis; ///< Unit axis in the parent frame.
    double drag_distance = 0; ///< Original translation axis parameter.
};

} // namespace crimson::weapon_animation

#endif
