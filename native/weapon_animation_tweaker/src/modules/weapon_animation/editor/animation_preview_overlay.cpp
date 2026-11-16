// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "animation_preview_overlay.hpp"

#ifdef DEBUG_ENABLED

#include "animation_preview.hpp"

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/font.hpp>
#include <godot_cpp/classes/input.hpp>
#include <godot_cpp/classes/input_event_key.hpp>
#include <godot_cpp/classes/input_event_mouse_button.hpp>
#include <godot_cpp/classes/input_event_mouse_motion.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/core/object.hpp>

#include <algorithm>
#include <cmath>

namespace crimson::weapon_animation {
using namespace godot;

namespace {

/// Resolve a preview-owned object without retaining a freed scene node.
template <class T>
T *preview_node(ObjectID id) {
    return id.is_valid() ? Object::cast_to<T>(ObjectDB::get_instance(static_cast<uint64_t>(id))) : nullptr;
}

/// Squared range from the pointer to one screen-space line segment.
double distance_squared(const Vector2 &point, const Vector2 &a, const Vector2 &b) {
    const Vector2 segment = b - a;
    const double length = segment.length_squared();
    const double fraction = length > 0 ? std::clamp(double((point - a).dot(segment)) / length, 0.0, 1.0) : 0.0;
    return point.distance_squared_to(a + segment * fraction);
}

/// Keep colors consistent with the usual editor axes.
Color axis_color(int axis) {
    const std::array<Color, 3> colors{Color(0.96, 0.30, 0.33), Color(0.54, 0.86, 0.32), Color(0.35, 0.64, 1.0)};
    return colors[axis];
}

} // namespace

void register_animation_preview_overlay_type() {
    GDREGISTER_INTERNAL_CLASS(AnimationPreviewOverlay);
}

void AnimationPreviewOverlay::bind(AnimationPreview *source) {
    reset_interaction();
    preview = source;
    set_mouse_filter(MOUSE_FILTER_STOP);
    set_focus_mode(FOCUS_CLICK);
    set_process(false);
    queue_redraw();
}

void AnimationPreviewOverlay::reset_interaction() {
    orbiting = false;
    flying = false;
    dragging = false;
    changed = false;
    handles = {};
    set_process(false);
    set_default_cursor_shape(CURSOR_ARROW);
}

Camera3D *AnimationPreviewOverlay::view_camera() const {
    if (!preview) {
        return nullptr;
    }
    return preview->pose_mode ? preview_node<Camera3D>(preview->orbit_camera) : preview->get_camera();
}

Node3D *AnimationPreviewOverlay::selected_node() const {
    return preview ? preview->get_preview_node(preview->get_target()) : nullptr;
}

Vector2 AnimationPreviewOverlay::camera_pixels(Camera3D *view, const Vector2 &screen) const {
    const Vector2 canvas = get_size();
    const Vector2 viewport_size = view->get_viewport()->get_visible_rect().size;
    return canvas.x > 0 && canvas.y > 0 ? screen / canvas * viewport_size : screen;
}

bool AnimationPreviewOverlay::project(Camera3D *view, const Vector3 &world, Vector2 &screen) const {
    if (!view || view->is_position_behind(world)) {
        return false;
    }
    const Vector2 viewport_size = view->get_viewport()->get_visible_rect().size;
    if (viewport_size.x <= 0 || viewport_size.y <= 0) {
        return false;
    }
    screen = view->unproject_position(world) / viewport_size * get_size();
    return screen.is_finite();
}

void AnimationPreviewOverlay::frame_pose() {
    Camera3D *view = view_camera();
    if (!preview || !preview->pose_mode || !view) {
        return;
    }
    Vector3 minimum;
    Vector3 maximum;
    bool found = false;
    for (const AnimationPreview::Target &target : preview->targets) {
        if (target.kind != StringName("bone") && target.kind != StringName("socket")) {
            continue;
        }
        if (Node3D *node = preview_node<Node3D>(target.node)) {
            const Vector3 position = node->get_global_position();
            minimum = found ? minimum.min(position) : position;
            maximum = found ? maximum.max(position) : position;
            found = true;
        }
    }
    orbit_center = found ? (maximum + minimum) / 2 : Vector3(0, 0, -0.7);
    orbit_radius = found ? std::max(0.4, double(maximum.distance_to(minimum)) * 1.4) : 1.2;
    if (Node3D *selection = selected_node()) {
        if (selection != preview->get_camera()) {
            orbit_center = selection->get_global_position();
        }
    }
    const Vector3 direction = Vector3(0.84, 0.42, 0.72).normalized();
    view->set_global_position(orbit_center + direction * orbit_radius);
    view->look_at(orbit_center);
    queue_redraw();
}

void AnimationPreviewOverlay::_notification(int what) {
    if (what == NOTIFICATION_DRAW) {
        draw_pose();
    } else if (what == NOTIFICATION_VISIBILITY_CHANGED && !is_visible_in_tree()) {
        reset_interaction();
    }
}

void AnimationPreviewOverlay::draw_joints(Camera3D *view, Node3D *ghost_camera, const Color &ink) {
    for (const AnimationPreview::Target &target : preview->targets) {
        if (target.kind != StringName("bone") && target.kind != StringName("socket")) {
            continue;
        }
        Node3D *node = preview_node<Node3D>(target.node);
        if (!node) {
            continue;
        }
        if (ghost_camera) {
            node = Object::cast_to<Node3D>(ghost_camera->get_node_or_null(preview->get_camera()->get_path_to(node)));
        }
        Vector2 point;
        if (!node || !project(view, node->get_global_position(), point)) {
            continue;
        }
        Node3D *parent = node->get_parent_node_3d();
        Vector2 parent_point;
        if (parent && parent->has_meta("native_pose_index") && project(view, parent->get_global_position(), parent_point)) {
            draw_line(point, parent_point, ink, 1.5, true);
        }
        const bool selected = !ghost_camera && target.path == preview->get_target();
        draw_circle(point, selected ? 4.5 : 2.6, selected ? Color(0.30, 0.75, 1.0) : ink);
        if (selected) {
            const Ref<Font> font = get_theme_default_font();
            if (font.is_valid()) {
                draw_string(font, point + Vector2(8, -8), String(node->get_name()), HORIZONTAL_ALIGNMENT_LEFT,
                        -1, get_theme_default_font_size(), Color(0.76, 0.9, 1.0));
            }
        }
    }
}

void AnimationPreviewOverlay::draw_pose() {
    Camera3D *view = view_camera();
    if (!view || !preview) {
        return;
    }
    if (preview->pose_mode) {
        for (const AnimationPreview::Ghost &ghost : preview->ghosts) {
            Node3D *root = preview_node<Node3D>(ghost.root);
            if (root && root->is_visible()) {
                auto *ghost_view = Object::cast_to<Node3D>(root->get_node_or_null(NodePath("PreviewCamera")));
                if (ghost_view) {
                    draw_joints(view, ghost_view, Color(ghost.tint.r, ghost.tint.g, ghost.tint.b, 0.52));
                }
            }
        }
        draw_joints(view, nullptr, Color(0.78, 0.83, 0.92, 0.9));
    }
    for (const AnimationPreview::Trail &trail : preview->trails) {
        Node3D *socket = preview_node<Node3D>(trail.socket);
        if (!socket) {
            continue;
        }
        const Color ink = trail.left ? Color(0.20, 0.90, 0.96) : Color(1.0, 0.65, 0.12);
        Vector2 point;
        if (preview->show_sockets && project(view, socket->get_global_position(), point)) {
            draw_circle(point, 5, ink);
        }
        if (preview->show_trails && socket->get_parent_node_3d()) {
            const Transform3D parent = socket->get_parent_node_3d()->get_global_transform();
            Vector2 previous;
            bool previous_visible = false;
            for (int64_t i = 0; i < trail.points.size(); ++i) {
                const bool visible = project(view, parent.xform(trail.points[i]), point);
                if (visible) {
                    if (previous_visible) {
                        draw_line(previous, point, ink, 1.0, true);
                    }
                    draw_circle(point, 2, ink);
                    previous = point;
                }
                previous_visible = visible;
            }
        }
    }
    draw_gizmo(view);
}

void AnimationPreviewOverlay::draw_gizmo(Camera3D *view) {
    handles = {};
    Node3D *node = selected_node();
    if (!node || node == view || preview->playing) {
        return;
    }
    const Vector3 origin = node->get_global_position();
    Vector2 center;
    if (!project(view, origin, center)) {
        return;
    }
    const Basis axes = (preview->rotate_gizmo || !node->get_parent_node_3d()) ? node->get_global_basis().orthonormalized() :
            node->get_parent_node_3d()->get_global_basis().orthonormalized();
    const double depth = view->get_global_transform().affine_inverse().xform(origin).z;
    const double fov = view->get_fov() * Math::PI / 180.0;
    const double radius = std::max(0.01, std::abs(depth) * std::tan(fov / 2) * 120.0 / std::max(120.0, double(get_size().y)));
    for (int axis = 0; axis < 3; ++axis) {
        Handle &handle = handles[axis];
        handle.axis = axes.get_column(axis);
        const Color ink = axis_color(axis);
        if (preview->rotate_gizmo) {
            const Vector3 first = axes.get_column((axis + 1) % 3) * radius;
            const Vector3 second = axes.get_column((axis + 2) % 3) * radius;
            for (int i = 0; i <= 48; ++i) {
                const double at = i * Math::TAU / 48;
                Vector2 point;
                if (!project(view, origin + first * std::cos(at) + second * std::sin(at), point)) {
                    handle.points.clear();
                    break;
                }
                handle.points.push_back(point);
            }
            if (handle.points.size() > 1) {
                draw_polyline(handle.points, ink, 2, true);
            }
        } else {
            Vector2 end;
            if (project(view, origin + handle.axis * radius, end) && end.distance_squared_to(center) > 16) {
                handle.points.push_back(center);
                handle.points.push_back(end);
                draw_line(center, end, ink, 2, true);
                draw_circle(end, 4, ink);
            }
        }
    }
}

void AnimationPreviewOverlay::pick_target(const Vector2 &screen) {
    Camera3D *view = view_camera();
    NodePath path;
    double best = 10 * 10;
    for (const AnimationPreview::Target &target : preview->targets) {
        if (target.kind != StringName("bone") && target.kind != StringName("socket")) {
            continue;
        }
        Node3D *node = preview_node<Node3D>(target.node);
        Vector2 point;
        if (node && project(view, node->get_global_position(), point) && screen.distance_squared_to(point) < best) {
            best = screen.distance_squared_to(point);
            path = target.path;
        }
    }
    if (!path.is_empty()) {
        preview->set_target(path);
        if (preview->target_selected) {
            preview->target_selected(path);
        }
    }
}

bool AnimationPreviewOverlay::axis_parameter(const Vector2 &screen, double &parameter) const {
    Camera3D *view = view_camera();
    if (!view) {
        return false;
    }
    const Vector2 pixels = camera_pixels(view, screen);
    const Vector3 ray = view->project_ray_normal(pixels);
    const Vector3 difference = drag_origin - view->project_ray_origin(pixels);
    const double alignment = drag_axis.dot(ray);
    const double denominator = 1 - alignment * alignment;
    if (denominator < 0.001) {
        return false;
    }
    parameter = (alignment * ray.dot(difference) - drag_axis.dot(difference)) / denominator;
    return std::isfinite(parameter);
}

bool AnimationPreviewOverlay::ring_vector(const Vector2 &screen, Vector3 &direction) const {
    Camera3D *view = view_camera();
    if (!view) {
        return false;
    }
    const Vector2 pixels = camera_pixels(view, screen);
    const Vector3 eye = view->project_ray_origin(pixels);
    const Vector3 ray = view->project_ray_normal(pixels);
    const double facing = drag_axis.dot(ray);
    if (std::abs(facing) < 0.001) {
        return false;
    }
    const double parameter = drag_axis.dot(drag_origin - eye) / facing;
    direction = (eye + ray * parameter - drag_origin).normalized();
    return parameter > 0 && direction.length_squared() > 0.9;
}

bool AnimationPreviewOverlay::start_drag(const Vector2 &screen) {
    Node3D *node = selected_node();
    if (!node || preview->playing) {
        return false;
    }
    int axis = -1;
    double best = 9 * 9;
    for (int candidate = 0; candidate < 3; ++candidate) {
        const PackedVector2Array &points = handles[candidate].points;
        for (int64_t i = 1; i < points.size(); ++i) {
            const double distance = distance_squared(screen, points[i - 1], points[i]);
            if (distance < best) {
                axis = candidate;
                best = distance;
            }
        }
    }
    if (axis < 0) {
        return false;
    }
    drag_pose = node->get_transform();
    drag_origin = node->get_global_position();
    drag_axis = handles[axis].axis.normalized();
    const Node3D *parent = node->get_parent_node_3d();
    drag_parent_axis = parent ? parent->get_global_basis().inverse().xform(drag_axis) : drag_axis;
    rotating = preview->rotate_gizmo;
    dragging = rotating ? ring_vector(screen, drag_ring_start) : axis_parameter(screen, drag_distance);
    changed = false;
    return dragging;
}

void AnimationPreviewOverlay::drag_to(const Vector2 &screen) {
    Transform3D pose = drag_pose;
    if (rotating) {
        Vector3 direction;
        if (!ring_vector(screen, direction)) {
            return;
        }
        const double angle = std::atan2(drag_axis.dot(drag_ring_start.cross(direction)), drag_ring_start.dot(direction));
        pose.basis = Basis(drag_parent_axis.normalized(), angle) * drag_pose.basis;
    } else {
        double parameter = 0;
        if (!axis_parameter(screen, parameter)) {
            return;
        }
        pose.origin += drag_parent_axis * (parameter - drag_distance);
    }
    preview->set_target_pose(pose);
    changed = !pose.is_equal_approx(drag_pose);
}

void AnimationPreviewOverlay::commit_drag() {
    dragging = false;
    if (changed && preview->pose_committed) {
        preview->pose_committed(preview->get_target_pose());
    }
    changed = false;
}

void AnimationPreviewOverlay::navigate(const Vector2 &relative, bool shift) {
    Camera3D *view = view_camera();
    if (!view) {
        return;
    }
    Transform3D pose = view->get_global_transform();
    if (flying || !shift) {
        const Basis yaw(Vector3(0, 1, 0), -relative.x * 0.007);
        const Vector3 right = (yaw * pose.basis).get_column(0).normalized();
        const Basis pitch(right, -relative.y * 0.007);
        const Basis next = pitch * yaw * pose.basis;
        if (std::abs(next.get_column(2).y) < 0.985) {
            pose.basis = next.orthonormalized();
        } else {
            pose.basis = (yaw * pose.basis).orthonormalized();
        }
        if (flying) {
            orbit_center = pose.origin - pose.basis.get_column(2) * orbit_radius;
        } else {
            pose.origin = orbit_center + pose.basis.get_column(2) * orbit_radius;
        }
    } else {
        const Vector3 offset = pose.basis.xform(Vector3(-relative.x, relative.y, 0)) * orbit_radius * 0.002;
        orbit_center += offset;
        pose.origin += offset;
    }
    view->set_global_transform(pose);
    queue_redraw();
}

void AnimationPreviewOverlay::_process(double delta) {
    Camera3D *view = view_camera();
    if (!flying || !view) {
        return;
    }
    const Input *input = Input::get_singleton();
    const Vector3 axis(int(input->is_physical_key_pressed(KEY_D)) - int(input->is_physical_key_pressed(KEY_A)),
            int(input->is_physical_key_pressed(KEY_E)) - int(input->is_physical_key_pressed(KEY_Q)),
            int(input->is_physical_key_pressed(KEY_S)) - int(input->is_physical_key_pressed(KEY_W)));
    if (axis.length_squared() > 0) {
        const Vector3 offset = view->get_global_basis().xform(axis.normalized()) * delta * std::max(0.25, orbit_radius);
        view->set_global_position(view->get_global_position() + offset);
        orbit_center += offset;
        queue_redraw();
    }
}

void AnimationPreviewOverlay::_gui_input(const Ref<InputEvent> &event) {
    Camera3D *view = view_camera();
    if (!preview || !view) {
        return;
    }
    if (const Ref<InputEventMouseButton> mouse = event; mouse.is_valid()) {
        const auto button = mouse->get_button_index();
        const bool pressed = mouse->is_pressed();
        if (button == MOUSE_BUTTON_LEFT) {
            if (pressed) {
                grab_focus();
                if (!start_drag(mouse->get_position()) && preview->pose_mode) {
                    pick_target(mouse->get_position());
                }
            } else if (dragging) {
                commit_drag();
            }
            accept_event();
        } else if (preview->pose_mode && (button == MOUSE_BUTTON_RIGHT || button == MOUSE_BUTTON_MIDDLE)) {
            grab_focus();
            if (button == MOUSE_BUTTON_RIGHT) {
                flying = pressed;
                set_process(flying);
            } else {
                orbiting = pressed;
            }
            set_default_cursor_shape(flying || orbiting ? CURSOR_MOVE : CURSOR_ARROW);
            accept_event();
        } else if (preview->pose_mode && pressed && (button == MOUSE_BUTTON_WHEEL_UP || button == MOUSE_BUTTON_WHEEL_DOWN)) {
            orbit_radius = std::clamp(orbit_radius * (button == MOUSE_BUTTON_WHEEL_UP ? 0.85 : 1.18), 0.06, 25.0);
            view->set_global_position(orbit_center + view->get_global_basis().get_column(2) * orbit_radius);
            queue_redraw();
            accept_event();
        }
    } else if (const Ref<InputEventMouseMotion> motion = event; motion.is_valid()) {
        if (dragging) {
            drag_to(motion->get_position());
            accept_event();
        } else if (orbiting || flying) {
            navigate(motion->get_relative(), motion->is_shift_pressed());
            accept_event();
        }
    } else if (const Ref<InputEventKey> key = event; key.is_valid() && key->is_pressed() &&
            preview->pose_mode && key->get_keycode() == KEY_F) {
        frame_pose();
        accept_event();
    }
}

} // namespace crimson::weapon_animation

#endif
