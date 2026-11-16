// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "modules/weapon_animation/editor/register_weapon_animation_editor.hpp"

#ifdef DEBUG_ENABLED

#include "editor/ui/editor_compositions.hpp"
#include "editor/ui/editor_controls.hpp"
#include "editor/ui/editor_spacing.hpp"
#include "modules/weapon_animation/animation_clip.hpp"
#include "modules/weapon_animation/animation_combo.hpp"
#include "modules/weapon_animation/animation_tracks.hpp"
#include "modules/weapon_animation/editor/animation_draft.hpp"
#include "modules/weapon_animation/editor/animation_preview.hpp"
#include "modules/weapon_animation/editor/animation_track_editor.hpp"
#include "modules/weapon_animation/editor/viewer_clip_import.hpp"


#include <godot_cpp/classes/animation_library.hpp>
#include <godot_cpp/classes/animation_player.hpp>
#include <godot_cpp/classes/aspect_ratio_container.hpp>
#include <godot_cpp/classes/button.hpp>
#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/check_button.hpp>
#include <godot_cpp/classes/confirmation_dialog.hpp>
#include <godot_cpp/classes/directional_light3d.hpp>
#include <godot_cpp/classes/editor_file_dialog.hpp>
#include <godot_cpp/classes/editor_file_system.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/editor_plugin.hpp>
#include <godot_cpp/classes/editor_plugin_registration.hpp>
#include <godot_cpp/classes/editor_selection.hpp>
#include <godot_cpp/classes/editor_undo_redo_manager.hpp>
#include <godot_cpp/classes/environment.hpp>
#include <godot_cpp/classes/font.hpp>
#include <godot_cpp/classes/h_box_container.hpp>
#include <godot_cpp/classes/h_slider.hpp>
#include <godot_cpp/classes/h_split_container.hpp>
#include <godot_cpp/classes/input_event_key.hpp>
#include <godot_cpp/classes/input_event_mouse_button.hpp>
#include <godot_cpp/classes/input_event_mouse_motion.hpp>
#include <godot_cpp/classes/item_list.hpp>
#include <godot_cpp/classes/label.hpp>
#include <godot_cpp/classes/line_edit.hpp>
#include <godot_cpp/classes/margin_container.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/option_button.hpp>
#include <godot_cpp/classes/packed_scene.hpp>
#include <godot_cpp/classes/panel_container.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/classes/scroll_container.hpp>
#include <godot_cpp/classes/spin_box.hpp>
#include <godot_cpp/classes/sub_viewport.hpp>
#include <godot_cpp/classes/sub_viewport_container.hpp>
#include <godot_cpp/classes/text_server.hpp>
#include <godot_cpp/classes/undo_redo.hpp>
#include <godot_cpp/classes/v_box_container.hpp>
#include <godot_cpp/classes/v_split_container.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/classes/world_environment.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <set>

namespace crimson::weapon_animation {
namespace {


using namespace godot;
namespace ui = crimson::editor_ui;

constexpr auto tool_name = "Weapon Animation (Native)"; ///< Editor project-tools entry.
constexpr auto default_combo_setting = "crimson/weapon_animation/default_combo"; ///< Optional game-owned opening resource.
constexpr auto preview_stage_setting = "crimson/weapon_animation/preview_stage"; ///< Optional game-owned 3D reference stage.
constexpr auto play_scene_setting = "crimson/weapon_animation/play_scene"; ///< Optional project scene opened by Play Scene.
constexpr double minimum_window = 0.005; ///< Smallest visible interval, in seconds.
constexpr double keyboard_step = 1.0 / 60.0; ///< Keyboard scrub increment, in seconds.
constexpr float fp_preview_ratio = 16.0f / 9.0f; ///< Same first-person composition as the original Tweaker.

/// Show a readable leaf while retaining library-qualified names in storage and tooltips.
String clip_label(const String &clip_key) {
    return clip_key.get_file().replace("_", " ").capitalize();
}

/// Pick a rounded major division at the current visible width.
double tick_step(double duration, double width) {
    const double raw = duration / std::max(1.0, width / 95.0);
    const double magnitude = std::pow(10.0, std::floor(std::log10(raw)));
    const double scaled = raw / magnitude;
    return magnitude * (scaled <= 1.0 ? 1.0 : scaled <= 2.0 ? 2.0 : scaled <= 5.0 ? 5.0 : 10.0);
}

/// An input-transparent crosshair at the center of the rendered camera frame.
class WeaponAnimationCrosshair final : public Control {
    GDCLASS(WeaponAnimationCrosshair, Control)

protected:
    /// The mark is decorative feedback owned by the preview window.
    static void _bind_methods() {}

    /// Paint the same beveled center point over both dark and bright reference scenes.
    void _notification(int what) {
        if (what == NOTIFICATION_RESIZED) {
            queue_redraw();
        }
        if (what != NOTIFICATION_DRAW) return;
        const Vector2 center = (get_size() * 0.5).floor();
        const real_t half = ui::pixels(this, 6);
        const Vector2 horizontal(half, 0);
        const Vector2 vertical(0, half);
        const Color shadow(0.02, 0.02, 0.02, 0.78);
        const Color ink(0.95, 0.96, 0.98, 0.94);
        draw_line(center - horizontal, center + horizontal, shadow, ui::pixels(this, 4));
        draw_line(center - vertical, center + vertical, shadow, ui::pixels(this, 4));
        draw_line(center - horizontal, center + horizontal, ink, ui::pixels(this, 1));
        draw_line(center - vertical, center + vertical, ink, ui::pixels(this, 1));
    }
};

/// Zoomable pose ruler and native combo track canvas.
class WeaponAnimationTimeline : public Control {
    GDCLASS(WeaponAnimationTimeline, Control)

    /// Read-only visible preview from the window that owns this control.
    const AnimationPreview *preview = nullptr;
    /// Clip labels keyed by their indices in the draft.
    PackedStringArray keys;
    /// Receiver for precise preview time in seconds.
    Callable seek_time;
    /// Receiver for a selected transition's outgoing index.
    Callable choose_join;
    /// Receiver for a selected clip's index.
    Callable choose_clip;
    /// Receiver for the old and new clip indices.
    Callable move_clip;
    /// Receiver for opening or stopping playback.
    Callable toggle_play;
    /// Receives fit, zoom, and pan changes so track rows share the visible time span.
    Callable view_changed;
    /// Sorted unique times of the active clip's authored transform keys.
    std::vector<double> keys_at;
    /// Start of the highlighted range in seconds, or -1 for the whole clip.
    double region_begin = -1;
    /// End of the highlighted range in seconds.
    double region_end = -1;
    /// Index of the section being edited, or -1 outside combo mode.
    int selected_join = -1;
    /// Index of the clip selected for reordering.
    int selected_clip = -1;
    /// Left edge of the visible interval, in seconds.
    double offset = 0;
    /// Duration visible at the current zoom, in seconds.
    double visible_duration = 0;
    /// Raw timeline extent, including a fallback sequence while no rig is available.
    double duration = 0;
    /// Whether to show combo lanes below the scrub ruler.
    bool combo_mode = false;
    /// Whether the selected intervals can reorder the draft.
    bool allow_reorder = false;
    /// Active mouse button type for scrubbing or horizontal panning.
    MouseButton held_button = MOUSE_BUTTON_NONE;
    /// Candidate clip before pointer movement crosses the reorder threshold.
    int picked_clip = -1;
    /// Current potential landing clip during a reorder drag.
    int drop_clip = -1;
    /// Initial click position, used to separate a drag from a clip selection.
    Vector2 drag_origin;
    /// Whether to skip the click action after a reorder gesture.
    bool dragging = false;

    /// Width reserved for lane names and the time-axis origin.
    double gutter() const { return ui::pixels(const_cast<WeaponAnimationTimeline *>(this), 76); }
    /// Height of the ruler and each track row.
    double row_height() const { return ui::pixels(const_cast<WeaponAnimationTimeline *>(this), 29); }
    /// Drawing space available to the visible time interval.
    double plot_width() const { return std::max(1.0, static_cast<double>(get_size().x) - gutter() - 8.0); }
    /// Map one preview second to the horizontal axis.
    double x_at(double seconds) const { return gutter() + (seconds - offset) * plot_width() / visible_duration; }
    /// Decode pointer position on the same axis used by the renderer.
    double time_at(double x) const {
        return std::clamp(offset + std::clamp((x - gutter()) / plot_width(), 0.0, 1.0) * visible_duration, 0.0, duration);
    }
    /// Clamp viewport edges after a pan, resize or playback change.
    void clamp_view() {
        if (duration <= 0) return;
        visible_duration = std::clamp(visible_duration, std::min(duration, minimum_window), duration);
        offset = std::clamp(offset, 0.0, duration - visible_duration);
        if (view_changed.is_valid()) view_changed.call(offset, visible_duration);
        queue_redraw();
    }
    /// Snap the mouse to the closest authored key unless Ctrl requests an exact time.
    double scrub_time(double x, bool free) const {
        const double time = time_at(x);
        if (free || keys_at.empty()) return time;
        const auto next = std::lower_bound(keys_at.begin(), keys_at.end(), time);
        if (next == keys_at.begin()) return *next;
        if (next == keys_at.end()) return keys_at.back();
        return time - *(next - 1) < *next - time ? *(next - 1) : *next;
    }
    /// Step to the next or previous authored key, bounded by both ends.
    double adjacent_time(bool forward) const {
        const double time = preview->get_time();
        if (keys_at.empty()) return time + (forward ? keyboard_step : -keyboard_step);
        if (forward) {
            const auto next = std::upper_bound(keys_at.begin(), keys_at.end(), time + 0.0000001);
            return next == keys_at.end() ? keys_at.back() : *next;
        }
        const auto key = std::lower_bound(keys_at.begin(), keys_at.end(), time - 0.0000001);
        return key == keys_at.begin() ? keys_at.front() : *(key - 1);
    }
    /// Compute a visible rectangle for one time interval, retaining small hard-cut targets.
    Rect2 band_rect(double start, double end, int lane) const {
        if (end < offset || start > offset + visible_duration || visible_duration <= 0) return {};
        const double width = plot_width();
        const double left = gutter();
        const double right = left + width;
        const double a = std::clamp(x_at(start), left, right);
        const double b = std::clamp(x_at(end), left, right);
        const double size = std::min(width, std::max(6.0, b - a - 1.0));
        const double x = std::clamp((a + b - size) * 0.5, left, right - size);
        return Rect2(x, row_height() * lane + 2, size, row_height() - 4);
    }
    /// Return the clip under the cursor, including an order-only draft without a preview.
    int clip_at(const Vector2 &point) const {
        if (!combo_mode) return -1;
        if (preview->get_length() <= 0) {
            for (int index = 0; index < keys.size(); ++index) {
                if (band_rect(index, index + 0.96, 1).has_point(point)) return index;
            }
        }
        for (const AnimationPreview::ClipBand &band : preview->get_clip_bands()) {
            if (band_rect(band.start, band.end, band.lane + 1).has_point(point)) return band.index;
        }
        return -1;
    }
    /// Return the outgoing join whose blend band is under the cursor.
    int join_at(const Vector2 &point) const {
        if (!combo_mode) return -1;
        for (const AnimationPreview::BlendBand &band : preview->get_blend_bands()) {
            if (band_rect(band.start, band.end, 3).has_point(point)) return band.index;
        }
        return -1;
    }
    /// Draw a bounded text label on the current theme's dark surface.
    void caption(const Rect2 &area, const String &label, ui::Surface role) const {
        const Ref<Font> font = get_theme_default_font();
        const int size = get_theme_default_font_size();
        const double horizontal_padding = 6;
        if (area.size.x <= horizontal_padding * 2) return;
        const double baseline = area.position.y + (area.size.y - font->get_height(size)) * 0.5 + font->get_ascent(size);
        draw_string(font, Vector2(area.position.x + horizontal_padding, baseline), label, HORIZONTAL_ALIGNMENT_LEFT,
                area.size.x - horizontal_padding * 2, size, ui::color(role));
    }
    /// Draw a selectable segment or blend band and its caption.
    void paint_band(const Rect2 &area, const String &text, const Color &fill, bool selected) {
        if (!area.has_area()) return;
        draw_rect(area, fill);
        draw_rect(area.grow(-0.5), ui::color(selected ? ui::Surface::ACCENT : ui::Surface::OUTLINE), false, 1);
        caption(area, text, ui::Surface::TEXT);
    }

protected:
    /// All input is forwarded to the native workbench.
    static void _bind_methods() {}

    /// Draw the same playable intervals used by the evaluator.
    void _notification(int what) {
        if (what != NOTIFICATION_DRAW || !preview) return;
        const double height = row_height();
        draw_rect(Rect2(Vector2(), get_size()), ui::color(ui::Surface::SIDEBAR));
        if (duration <= 0 || visible_duration <= 0) return;
        if (preview->get_length() > 0) {
            const double step = tick_step(visible_duration, plot_width());
            for (double tick = std::ceil(offset / step) * step; tick <= offset + visible_duration + step * 0.0001; tick += step) {
                const double x = x_at(tick);
                draw_line(Vector2(x, height - 6), Vector2(x, get_size().y), ui::color(ui::Surface::RULE), 1);
                caption(Rect2(x, 0, std::min(94.0, get_size().x - x), height - 3),
                        String::num(tick, visible_duration < 1.0 ? 3 : 2), ui::Surface::MUTED);
            }
            if (!combo_mode) {
                if (region_begin >= 0 && region_end > region_begin) {
                    draw_rect(band_rect(region_begin, region_end, 0), ui::color(ui::Surface::ACCENT).darkened(0.5), false, 1.0);
                }
                for (const double key : keys_at) {
                    if (key < offset || key > offset + visible_duration) continue;
                    const double x = x_at(key);
                    draw_line(Vector2(x, height - 8.0), Vector2(x, height - 2.0), ui::color(ui::Surface::TEXT), 1);
                }
            }
        }
        if (combo_mode) {
            caption(Rect2(0, height, gutter(), height * 2), "Clips", ui::Surface::MUTED);
            caption(Rect2(0, height * 3, gutter(), height), "Blends", ui::Surface::MUTED);
            for (int row = 1; row <= 4; ++row) {
                draw_line(Vector2(0, row * height), Vector2(get_size().x, row * height), ui::color(ui::Surface::RULE), 1);
            }
            const Color selected = ui::color(ui::Surface::SELECTED);
            const Color base = ui::color(ui::Surface::RAISED);
            const Color accent = ui::color(ui::Surface::ACCENT);
            for (const AnimationPreview::ClipBand &band : preview->get_clip_bands()) {
                if (band.index < 0 || band.index >= keys.size()) continue;
                const bool active = band.index == selected_clip || band.index == drop_clip;
                paint_band(band_rect(band.start, band.end, band.lane + 1), clip_label(keys[band.index]),
                        active ? selected.lerp(accent, 0.28) : base.lerp(accent, band.lane == 0 ? 0.13 : 0.05), active);
            }
            if (preview->get_length() <= 0) {
                for (int index = 0; index < keys.size(); ++index) {
                    paint_band(band_rect(index, index + 0.96, 1), clip_label(keys[index]), base, index == selected_clip);
                }
            }
            for (const AnimationPreview::BlendBand &band : preview->get_blend_bands()) {
                const double overlap = band.end - band.start;
                paint_band(band_rect(band.start, band.end, 3), overlap > 0 ? String::num(overlap, 3) + " s" : String("Cut"),
                        base.lerp(accent, band.index == selected_join ? 0.52 : 0.23), band.index == selected_join);
            }
        }
        const double time = preview->get_time();
        if (preview->get_length() > 0 && time >= offset && time <= offset + visible_duration) {
            const double x = x_at(time);
            draw_line(Vector2(x, 0), Vector2(x, get_size().y), ui::color(ui::Surface::ACCENT), 1);
        }
    }

public:
    /// Install receivers when the owning tool constructs the workspace.
    void bind(const AnimationPreview *source, const Callable &seek, const Callable &join,
            const Callable &clip, const Callable &reorder, const Callable &play, const Callable &view) {
        preview = source;
        seek_time = seek;
        choose_join = join;
        choose_clip = clip;
        move_clip = reorder;
        toggle_play = play;
        view_changed = view;
        set_focus_mode(FOCUS_ALL);
        set_clip_contents(true);
    }
    /// Update the key ruler and a possible playback region in clip mode.
    void set_clip_keys(std::vector<double> times, double first, double last) {
        keys_at = std::move(times);
        region_begin = first;
        region_end = last;
        queue_redraw();
    }
    /// Change the visible source without losing an existing zoom unless requested.
    void refresh(const TypedArray<StringName> &clip_keys, bool show_combo, bool reorder,
            int active_join, int active_clip, bool reset_zoom) {
        keys.clear();
        for (const Variant &key : clip_keys) keys.push_back(String(key));
        combo_mode = show_combo;
        allow_reorder = reorder;
        selected_join = active_join;
        selected_clip = active_clip;
        set_custom_minimum_size(Vector2(0, row_height() * (combo_mode ? 4 : 1)));
        const double next = preview->get_length() > 0 ? preview->get_length() : (combo_mode ? keys.size() : 0);
        if (reset_zoom || duration != next || visible_duration <= 0) {
            duration = next;
            fit();
        }
        queue_redraw();
    }
    /// Set the entire clip or sequence as the current time window.
    void fit() {
        offset = 0;
        visible_duration = duration;
        if (view_changed.is_valid()) view_changed.call(offset, visible_duration);
        queue_redraw();
    }
    /// Zoom around a chosen position, or the playhead when applied by a toolbar command.
    void zoom(double scale, double anchor = -1.0) {
        if (duration <= 0 || visible_duration <= 0) return;
        const double pivot = anchor >= 0 ? time_at(anchor) : std::clamp(preview->get_time(), offset, offset + visible_duration);
        const double ratio = (pivot - offset) / visible_duration;
        visible_duration = std::clamp(visible_duration * scale, std::min(duration, minimum_window), duration);
        offset = pivot - ratio * visible_duration;
        clamp_view();
    }
    /// Expose the complete animation key without making labels overrun the bands.
    String _get_tooltip(const Vector2 &point) const override {
        if (!preview || duration <= 0) return {};
        const int hit = clip_at(point);
        if (hit >= 0 && hit < keys.size()) return keys[hit];
        const int blend = join_at(point);
        return blend >= 0 ? "Transition " + String::num_int64(blend + 1) : String();
    }
    /// Scrub, zoom, pan and reorder native animation tracks.
    void _gui_input(const Ref<InputEvent> &event) override {
        if (!preview || duration <= 0 || !event.is_valid()) return;
        const Ref<InputEventKey> key = event;
        if (key.is_valid() && key->is_pressed()) {
            if (key->get_keycode() == KEY_SPACE && !key->is_echo()) toggle_play.call();
            else if (key->get_keycode() == KEY_LEFT) seek_time.call(adjacent_time(false));
            else if (key->get_keycode() == KEY_RIGHT) seek_time.call(adjacent_time(true));
            else return;
            accept_event();
            return;
        }
        const Ref<InputEventMouseButton> mouse = event;
        if (mouse.is_valid()) {
            const MouseButton button = mouse->get_button_index();
            const Vector2 point = mouse->get_position();
            if (mouse->is_pressed()) {
                if (button == MOUSE_BUTTON_WHEEL_UP || button == MOUSE_BUTTON_WHEEL_DOWN) {
                    zoom(button == MOUSE_BUTTON_WHEEL_UP ? 0.65 : 1.54, point.x);
                } else if (button == MOUSE_BUTTON_MIDDLE) {
                    held_button = button;
                } else if (button == MOUSE_BUTTON_LEFT) {
                    grab_focus();
                    held_button = button;
                    drag_origin = point;
                    picked_clip = clip_at(point);
                    const int join = join_at(point);
                    if (join >= 0) {
                        held_button = MOUSE_BUTTON_NONE;
                        choose_join.call(join);
                    } else if (picked_clip < 0) {
                        seek_time.call(scrub_time(point.x, mouse->is_ctrl_pressed()));
                    }
                } else return;
            } else if (held_button == button) {
                held_button = MOUSE_BUTTON_NONE;
                if (button == MOUSE_BUTTON_LEFT && picked_clip >= 0) {
                    const int from = picked_clip;
                    const int destination = clip_at(point);
                    const bool reorder = dragging && destination >= 0 && destination != from;
                    const bool select = !dragging && destination == from;
                    dragging = false;
                    picked_clip = -1;
                    drop_clip = -1;
                    queue_redraw();
                    if (reorder) move_clip.call(from, destination);
                    else if (select) choose_clip.call(from);
                }
            } else return;
            accept_event();
            return;
        }
        const Ref<InputEventMouseMotion> motion = event;
        if (motion.is_valid() && held_button != MOUSE_BUTTON_NONE) {
            if (held_button == MOUSE_BUTTON_MIDDLE) {
                offset -= motion->get_relative().x * visible_duration / plot_width();
                clamp_view();
            } else if (picked_clip < 0) {
                seek_time.call(scrub_time(motion->get_position().x, motion->is_ctrl_pressed()));
            } else if (allow_reorder && (dragging || drag_origin.distance_to(motion->get_position()) >= 6)) {
                dragging = true;
                drop_clip = clip_at(motion->get_position());
                queue_redraw();
            }
            accept_event();
        }
    }
};

/// Native detached preview, combo editing, and persistence workspace.
class WeaponAnimationWindow final : public Window {
    GDCLASS(WeaponAnimationWindow, Window)

    /// Clip parameters kept in source units until they are baked.
    struct ClipDraft {
        Ref<Animation> base; ///< Detached edited animation before motion adjustment.
        std::array<double, 6> motion{0, 1, 1, 1, 0, 0}; ///< Vertical offset, scale XYZ, depth offset, duration.
        std::map<String, Transform3D> mounts; ///< Pending transforms on authored sword mount nodes.
    };
    /// User file action remembered by the stock editor resource picker.
    enum class FileAction { OPEN_COMBO, SAVE_COMBO, VIEWER_PACK, PLAY_SCENE };
    /// How single clip playback should wrap.
    enum class ClipPlayback { LOOP, REGION, ONCE };

    /// Preview schedule and its scene copy, owned by this tool's private viewport.
    AnimationPreview preview;
    /// Source player in the edited scene. Resolve its ID before accessing any property.
    ObjectID animation_player;
    /// Scene history service used for library replacement and mount position commits.
    EditorUndoRedoManager *scene_history = nullptr;
    /// Last saved clip and its key within the player.
    Ref<Animation> saved_clip;
    /// Stable key matching the current draft's source animation.
    StringName draft_key;
    /// Working animation with private changes, undo, and preview state.
    ClipDraft clip_draft;
    /// Baked pose, timing, and track metadata currently visible in the private viewport.
    Ref<Animation> preview_clip;
    /// Earlier clip states retained for draft Undo.
    std::vector<ClipDraft> undo_clip;
    /// Later clip states retained for draft Redo.
    std::vector<ClipDraft> redo_clip;
    /// Draft state before a mouse drag so it commits as a single edit.
    ClipDraft motion_drag_start;
    /// True while a motion slider owns the pointer.
    bool motion_dragging = false;
    /// Targets reported by the active private rig.
    Array pose_targets;
    /// Selected target path relative to the authored AnimationPlayer root.
    NodePath target_path;
    /// Selected target's edit behavior, reported by the evaluator.
    StringName target_kind;
    /// Transform before numeric pose offsets are applied.
    Transform3D pose_anchor;
    /// Transient numeric adjustment before Set Key or mount commit.
    bool pose_pending = false;
    /// Toggle for orbit camera and skeleton editing.
    bool pose_mode = false;
    /// Clip-mode wrapping behavior.
    ClipPlayback clip_playback = ClipPlayback::LOOP;
    /// Start of the active preview region in clip seconds.
    double loop_start = 0;
    /// End of the active preview region or -1 to use the clip's endpoint.
    double loop_end = -1;
    /// Opened game scene for rapid in-editor motion testing.
    String play_scene_path;
    /// Working copy of the combo; authoring never edits the saved resource directly.
    Ref<CrimsonWeaponAnimationCombo> combo;
    /// Path suggested in Open and Save As after a draft has been loaded or saved.
    String combo_path;
    /// Ordered player animation keys matching the clip selector's options.
    TypedArray<StringName> available_clips;
    /// Selected outgoing clip in the join inspector.
    int join_index = 0;
    /// Clip for the remove and reorder actions.
    int clip_index = -1;
    /// True when the window is previewing authored combos.
    bool combo_mode = false;
    /// True while the preview contains the isolated selected transition.
    bool focus_join = false;
    /// Whether there is an active preview clock.
    bool playing = false;
    /// Whether callbacks must ignore programmatic inspector field changes.
    bool syncing = false;
    /// Whether a draft was changed since opening or saving it.
    bool dirty = false;
    /// Remember if boot has already considered the optional project default.
    bool checked_default = false;
    /// Main command bar source picker.
    OptionButton *clip_options = nullptr;
    /// Command for switching between single-clip and sequence work.
    Button *mode_button = nullptr;
    /// Command for playing or pausing the current preview.
    Button *play_button = nullptr;
    /// Command for isolating the selected join.
    Button *join_button = nullptr;
    /// Command for returning to the full combo timeline.
    Button *sequence_button = nullptr;
    /// Command for appending a source to the current draft.
    Button *add_button = nullptr;
    /// Reorder command moving one clip earlier.
    Button *earlier_button = nullptr;
    /// Reorder command moving one clip later.
    Button *later_button = nullptr;
    /// Remove command for the selected sequence step.
    Button *remove_button = nullptr;
    /// Programmatic loop setting, used in clip and combo modes.
    CheckButton *loop_button = nullptr;
    /// Current time and duration as presented to the user.
    Label *time_label = nullptr;
    /// Contextual failure and load/save feedback.
    Label *status = nullptr;
    /// Current document name and unsaved-change indicator.
    Label *document = nullptr;
    /// One ruler shared by the preview clock and the combo ranges.
    WeaponAnimationTimeline *timeline = nullptr;
    /// Private first-person viewport used by the pose evaluator.
    SubViewport *preview_viewport = nullptr;
    /// Aiming reference fixed at the center of the rendered viewport.
    WeaponAnimationCrosshair *crosshair = nullptr;
    /// Whether setup of the game-authored reference environment has run.
    bool reference_ready = false;
    /// Visible only while the sequence has an editable join.
    HBoxContainer *join_inspector = nullptr;
    /// Outgoing clip name and authoritative marker mode.
    Label *exit_label = nullptr;
    /// Incoming clip name and authoritative marker mode.
    Label *entry_label = nullptr;
    /// Dropdown containing outgoing marker choices.
    OptionButton *exit_marker = nullptr;
    /// Dropdown containing incoming marker choices.
    OptionButton *entry_marker = nullptr;
    /// Explicit outgoing endpoint in seconds.
    SpinBox *exit_time = nullptr;
    /// Explicit incoming endpoint in seconds.
    SpinBox *entry_time = nullptr;
    /// Requested blend duration in seconds.
    SpinBox *blend_time = nullptr;
    /// Single-clip toolbar and numeric inspector.
    Control *clip_tools = nullptr;
    /// Single-clip draft sidebar and its layout with the preview.
    Control *clip_sidebar = nullptr;
    /// Shared native clip track and curve editor.
    CrimsonAnimationTrackEditor *track_editor = nullptr;
    /// Target and playback choice controls.
    OptionButton *pose_targets_option = nullptr; ///< Pick one editable target path.
    OptionButton *playback_option = nullptr; ///< Choose looping, range, or one pass.
    OptionButton *comparison_option = nullptr; ///< Pick a ghost clip or clear it.
    OptionButton *gizmo_option = nullptr; ///< Select move or rotate mode.
    /// Draft action buttons.
    Button *apply_button = nullptr; ///< Apply the draft to its authored scene.
    Button *variant_button = nullptr; ///< Save a new clip in the current library.
    Button *undo_button = nullptr; ///< Step backwards in clip history.
    Button *redo_button = nullptr; ///< Step forwards in clip history.
    Button *reset_button = nullptr; ///< Restore the current source animation.
    Button *key_button = nullptr; ///< Bake the preview target transform into the draft.
    Button *import_button = nullptr; ///< Open a Viewer clip pack.
    Button *play_scene_button = nullptr; ///< Run the currently chosen scene.
    /// Preview guide toggles and onion settings.
    CheckButton *pose_toggle = nullptr; ///< Switch to the private orbit camera.
    CheckButton *socket_toggle = nullptr; ///< Show socket dot guides.
    CheckButton *trail_toggle = nullptr; ///< Show selected animation paths.
    SpinBox *past_ghosts = nullptr; ///< Number of earlier pose samples.
    SpinBox *future_ghosts = nullptr; ///< Number of later pose samples.
    SpinBox *ghost_spacing = nullptr; ///< Time between onion poses, in seconds.
    SpinBox *comparison_time = nullptr; ///< Independent second of the comparison clip.
    HSlider *comparison_ruler = nullptr; ///< Scrub the comparison clip independently.
    /// Motion and transform numeric fields, in the same order as their draft values.
    std::array<SpinBox *, 6> motion_fields{}; ///< Offsets, XYZ scale, and duration.
    std::array<SpinBox *, 6> pose_fields{}; ///< XYZ position and rotation offsets.
    std::array<HSlider *, 6> motion_sliders{}; ///< Direct-manipulation equivalents of the motion fields.
    HBoxContainer *region_row = nullptr; ///< Region-only controls.
    SpinBox *region_first = nullptr; ///< Loop in, in seconds.
    SpinBox *region_last = nullptr; ///< Loop out, in seconds.
    ConfirmationDialog *variant_dialog = nullptr; ///< New animation name prompt.
    LineEdit *variant_name = nullptr; ///< Clip name in the source library.
    Label *variant_error = nullptr; ///< Validation help for the proposed name.
    ConfirmationDialog *import_dialog = nullptr; ///< Pack selection and destination prompt.
    ItemList *import_items = nullptr; ///< Pack entries selectable as a group.
    OptionButton *import_libraries = nullptr; ///< New or automatically grouped existing destination.
    LineEdit *import_name = nullptr; ///< Name proposed for a new library.
    Label *import_error = nullptr; ///< Import validation and diagnostics.
    Dictionary import_pack; ///< Parsed Viewer JSON held until commit or cancellation.
    ObjectID import_target; ///< Player resolved when its file picker opened.
    /// Stock project resource dialog shared by combo open/save, Viewer packs, and scene selection.
    EditorFileDialog *file_dialog = nullptr;
    /// Current operation for the shared file picker.
    FileAction file_action = FileAction::OPEN_COMBO;

    /// Resolve the current animation player from its weak handle.
    AnimationPlayer *player() const { return Object::cast_to<AnimationPlayer>(ObjectDB::get_instance(animation_player)); }
    /// Find an authored player on the selected branch or under the edited root.
    AnimationPlayer *find_player() const {
        auto *editor = EditorInterface::get_singleton();
        Node *root = editor->get_edited_scene_root();
        if (!root) return nullptr;
        for (const Variant &entry : editor->get_selection()->get_selected_nodes()) {
            Node *selected = Object::cast_to<Node>(entry);
            if (!selected || (selected != root && !root->is_ancestor_of(selected))) continue;
            if (auto *candidate = Object::cast_to<AnimationPlayer>(selected)) return candidate;
            const auto matches = selected->find_children("*", "AnimationPlayer", true, false);
            if (!matches.is_empty()) return Object::cast_to<AnimationPlayer>(matches[0]);
        }
        if (auto *candidate = Object::cast_to<AnimationPlayer>(root)) return candidate;
        for (const Variant &entry : root->find_children("*", "AnimationPlayer", true, false)) {
            auto *candidate = Object::cast_to<AnimationPlayer>(entry);
            for (const String &key : candidate->get_animation_list()) {
                if (AnimationPreview::find_camera(candidate, candidate->get_animation(key))) return candidate;
            }
        }
        return nullptr;
    }
    /// Prefer the current clip key when reloading the edited scene.
    StringName current_clip() const {
        const int selected = clip_options->get_selected();
        return selected >= 0 && selected < available_clips.size() ? StringName(available_clips[selected]) : StringName();
    }
    /// Resolve the current source without changing detached working data for the same clip.
    void sync_clip_source() {
        AnimationPlayer *target = player();
        const StringName key = current_clip();
        const Ref<Animation> animation = target && target->has_animation(key) ? target->get_animation(key) : Ref<Animation>();
        if (draft_key == key && saved_clip == animation) return;
        saved_clip = animation;
        draft_key = key;
        clip_draft = {};
        clip_draft.base = saved_clip;
        if (saved_clip.is_valid()) clip_draft.motion[5] = saved_clip->get_length();
        preview_clip.unref();
        undo_clip.clear();
        redo_clip.clear();
        target_path = NodePath();
        target_kind = StringName();
        pose_pending = false;
        loop_start = 0;
        loop_end = -1;
    }
    /// Check the detached motion, curves, keyframes, or mount values for unsaved work.
    bool clip_is_dirty() const {
        if (saved_clip.is_null()) return false;
        const std::array<double, 6> defaults{0, 1, 1, 1, 0, saved_clip->get_length()};
        return clip_draft.base != saved_clip || clip_draft.motion != defaults || !clip_draft.mounts.empty() || pose_pending;
    }
    /// Read the authored animation root so scene edits resolve exactly the same paths as preview.
    Node *animation_root() const {
        AnimationPlayer *target = player();
        return target ? target->get_node_or_null(target->get_root()) : nullptr;
    }
    /// Only the scene that owns an AnimationPlayer can change its saved libraries.
    bool owns_player() const {
        const Node *scene = EditorInterface::get_singleton()->get_edited_scene_root();
        const AnimationPlayer *target = player();
        return scene && target && (target == scene || target->get_owner() == scene);
    }
    /// Locate camera-local sockets from the current draft even if the preview needs rebuilding.
    Array socket_paths() const {
        Array paths;
        AnimationPlayer *target = player();
        Node *rig = animation_root();
        Camera3D *camera = AnimationPreview::find_camera(target, clip_draft.base);
        if (!rig || !camera) return paths;
        for (int index = 0; index < clip_draft.base->get_track_count(); ++index) {
            if (!clip_draft.base->track_is_enabled(index)) continue;
            const NodePath raw = clip_draft.base->track_get_path(index);
            const auto type = clip_draft.base->track_get_type(index);
            if (type != Animation::TYPE_POSITION_3D && (type != Animation::TYPE_VALUE ||
                    raw.get_concatenated_subnames() != StringName("position"))) continue;
            const NodePath path(String(raw.get_concatenated_names()));
            Node *node = rig->get_node_or_null(path);
            if (node && node->get_parent() == camera && !paths.has(path)) paths.append(path);
        }
        return paths;
    }
    /// Resolve the current detached motion offsets into one playable, storable animation.
    Ref<Animation> bake_clip() const {
        if (clip_draft.base.is_null()) return {};
        const auto &motion = clip_draft.motion;
        if (motion == std::array<double, 6>{0, 1, 1, 1, 0, clip_draft.base->get_length()}) return clip_draft.base;
        return tweak_motion(clip_draft.base, socket_paths(), motion[0], motion[1], motion[2], motion[3], motion[4], motion[5]);
    }
    /// Save the previous draft for a single undoable editor gesture.
    void remember_clip(const ClipDraft &before) {
        constexpr size_t undo_limit = 80;
        if (undo_clip.size() >= undo_limit) undo_clip.erase(undo_clip.begin());
        undo_clip.push_back(before);
        redo_clip.clear();
    }
    /// Step clip draft history without touching the authored scene.
    void step_clip_history(bool redo) {
        auto &source = redo ? redo_clip : undo_clip;
        auto &destination = redo ? undo_clip : redo_clip;
        if (combo_mode || source.empty()) return;
        destination.push_back(clip_draft);
        clip_draft = source.back();
        source.pop_back();
        pose_pending = false;
        rebuild(true);
    }
    /// Clear a draft back to the selected saved clip.
    void reset_clip() {
        if (saved_clip.is_null() || !clip_is_dirty()) return;
        remember_clip(clip_draft);
        clip_draft = {};
        clip_draft.base = saved_clip;
        clip_draft.motion[5] = saved_clip->get_length();
        pose_pending = false;
        rebuild(true);
    }
    /// Set one motion parameter while preserving exact clip-time edits.
    void motion_changed(double value, int64_t index) {
        if (syncing || combo_mode || clip_draft.base.is_null() || clip_draft.motion[index] == value) return;
        const ClipDraft before = clip_draft;
        clip_draft.motion[index] = value;
        const Ref<Animation> prepared = bake_clip();
        if (prepared.is_null()) {
            clip_draft = before;
            refresh_clip_tools();
            show_status("This animation cannot preserve its keys with that adjustment.");
            return;
        }
        if (!motion_dragging) remember_clip(before);
        rebuild(true, prepared);
    }
    /// Begin one undo transaction before a slider drag.
    void begin_motion_drag() {
        motion_dragging = true;
        motion_drag_start = clip_draft;
    }
    /// Store one snapshot after the slider motion ends.
    void finish_motion_drag(bool changed) {
        if (motion_dragging && changed && motion_drag_start.motion != clip_draft.motion) remember_clip(motion_drag_start);
        motion_dragging = false;
        motion_drag_start = {};
        refresh_clip_buttons();
    }
    /// Apply an updated curve/notify/marker set while retaining independent duration tuning.
    void track_changed() {
        if (combo_mode || clip_draft.base.is_null() || preview_clip.is_null()) return;
        Ref<CrimsonWeaponAnimationTracks> edited_tracks = track_editor->get_tracks();
        if (edited_tracks.is_null()) return;
        const double ratio = clip_draft.base->get_length() / preview_clip->get_length();
        if (ratio != 1.0) edited_tracks = retime_tracks(edited_tracks, ratio);
        Ref<Animation> next = clip_draft.base->duplicate();
        if (edited_tracks.is_null() || next.is_null() || !edited_tracks->write_to(next)) {
            show_status("Those animation tracks could not be saved in the draft.");
            return;
        }
        remember_clip(clip_draft);
        clip_draft.base = next;
        preview_clip = bake_clip();
        refresh_clip_buttons();
    }
    /// Pass ruler pan and zoom to the native curve and event rows.
    void track_view_changed(double first, double duration) {
        if (track_editor && !combo_mode) track_editor->set_time_view(first, duration);
    }
    /// Show an inline status without modifying any of the user's current settings.
    void show_status(const String &message) {
        status->set_text(message);
        status->set_visible(!message.is_empty());
    }
    /// Rebuild the source choices and stop referencing a previously edited scene.
    void refresh_scene() {
        AnimationPlayer *target = find_player();
        const StringName retained = current_clip();
        animation_player = ObjectID(target ? target->get_instance_id() : 0);
        available_clips.clear();
        clip_options->clear();
        int selected = -1;
        if (target) {
            for (const String &entry : target->get_animation_list()) {
                const StringName key(entry);
                if (!AnimationPreview::find_camera(target, target->get_animation(key))) continue;
                if (key == retained) selected = available_clips.size();
                available_clips.push_back(key);
                clip_options->add_item(entry);
            }
        }
        if (!available_clips.is_empty()) clip_options->select(std::max(0, selected));
        clip_options->set_disabled(available_clips.is_empty());
        if (!combo_mode) sync_clip_source();
        refill_comparison();
        if (!checked_default && target) {
            checked_default = true;
            const String path = ProjectSettings::get_singleton()->get_setting(default_combo_setting, String());
            if (!path.is_empty() && ResourceLoader::get_singleton()->exists(path)) {
                load_combo(path);
                return;
            }
        }
        rebuild(false);
    }
    /// Handle a new edited scene while the window remains open.
    void edited_scene_changed(Node *) { if (is_visible()) refresh_scene(); else preview.clear(); }
    /// Show the source clip on a compatible first-person rig.
    void select_source(int64_t) { if (!combo_mode) { sync_clip_source(); rebuild(false); } }
    /// Toggle combo authoring while retaining its unsaved draft.
    void switch_mode() {
        combo_mode = !combo_mode;
        focus_join = false;
        if (!combo_mode) sync_clip_source();
        rebuild(false);
    }
    /// Present run state and current preview clock.
    void refresh_transport() {
        const double duration = preview.get_length();
        time_label->set_text(duration > 0 ?
                String::num(preview.get_time(), 3) + " / " + String::num(duration, 3) + " s" : String());
        play_button->set_disabled(duration <= 0);
        crosshair->set_visible(duration > 0 && (combo_mode || !pose_mode));
        play_button->set_text(playing ? "Pause" : (combo_mode && !focus_join ? "Play Combo" : "Play"));
        if (!combo_mode && track_editor) track_editor->set_playhead(preview.get_time());
        refresh_clip_buttons();
        timeline->queue_redraw();
    }
    /// Build the requested preview on the current source and authored chain.
    void rebuild(bool keep_time, const Ref<Animation> &prepared_clip = {}) {
        const double previous = keep_time ? preview.get_time() : 0.0;
        const double previous_length = preview.get_length();
        const bool resume = keep_time && playing;
        set_playing(false);
        preview.clear();
        String message;
        AnimationPlayer *target = player();
        bool prepared = false;
        if (!target) {
            message = "Open a player scene with a compatible AnimationPlayer.";
        } else if (!combo_mode) {
            preview_clip = prepared_clip.is_valid() ? prepared_clip : bake_clip();
            prepared = preview.load_clip_resource(target, preview_clip, clip_playback == ClipPlayback::LOOP);
            if (!prepared) message = "Choose a clip with an animated camera-local pose.";
        } else if (combo->get_clip_keys().size() < 2) {
            message = "Add two clips to make a transition.";
        } else if (focus_join) {
            const Dictionary resolved = combo->resolve_join(target, join_index);
            if (resolved.has("error")) message = resolved["error"];
            else prepared = preview.load_join(target, resolved, join_index, (join_index + 1) % combo->get_clip_keys().size());
        } else {
            message = combo->validate(target);
            if (message.is_empty()) {
                Array joins;
                for (int i = 0; i < combo->get_join_count(); ++i) joins.push_back(combo->resolve_join(target, i));
                prepared = preview.load_combo(target, combo->get_clip_keys(), joins, combo->get_loop());
            }
        }
        if (!prepared && message.is_empty()) message = "The selected clips need pose tracks on one camera rig.";
        if (prepared) {
            const double ratio = !combo_mode && keep_time && previous_length > 0 ? preview.get_length() / previous_length : 1.0;
            loop_start *= ratio;
            if (loop_end >= 0) loop_end *= ratio;
            preview.seek(previous * ratio);
        }
        if (!combo_mode) {
            restore_clip_preview_controls();
        } else {
            preview.set_pose_mode(false);
            preview.set_guides(false, false);
            preview.set_onion(0, 0, keyboard_step);
            preview.set_comparison(target, {}, 0);
        }
        show_status(message);
        refresh_tools(!keep_time);
        if (resume && prepared) set_playing(true);
    }
    /// Reconcile all controls with the active draft and preview schedule.
    void refresh_tools(bool reset_zoom) {
        const auto keys = combo->get_clip_keys();
        const int join_count = combo->get_join_count();
        join_index = std::clamp(join_index, 0, std::max(0, join_count - 1));
        const String displayed_name = combo_mode ? combo->get_display_name() : clip_label(String(current_clip()));
        document->set_text((displayed_name.is_empty() ? String(combo_mode ? "Untitled Combo" : "Weapon Animation") :
                displayed_name) + String((combo_mode ? dirty : clip_is_dirty()) ? " *" : ""));
        mode_button->set_text(combo_mode ? "Clip" : "Combo");
        join_button->set_visible(combo_mode && !focus_join);
        join_button->set_disabled(join_count <= 0);
        sequence_button->set_visible(combo_mode && focus_join);
        syncing = true;
        loop_button->set_text("Close Loop");
        loop_button->set_visible(combo_mode);
        loop_button->set_pressed_no_signal(combo->get_loop());
        playback_option->set_visible(!combo_mode);
        syncing = false;
        earlier_button->set_visible(combo_mode);
        later_button->set_visible(combo_mode);
        remove_button->set_visible(combo_mode);
        add_button->set_visible(combo_mode);
        earlier_button->set_disabled(clip_index <= 0);
        later_button->set_disabled(clip_index < 0 || clip_index + 1 >= keys.size());
        remove_button->set_disabled(clip_index < 0 || clip_index >= keys.size());
        refresh_clip_tools();
        timeline->refresh(keys, combo_mode, !focus_join, join_index, clip_index, reset_zoom);
        refresh_join();
        refresh_transport();
    }
    /// Enable the current document actions and keep the unsaved indicator current.
    void refresh_clip_buttons() {
        if (!apply_button) return;
        const bool editable = !combo_mode && owns_player() && preview_clip.is_valid();
        apply_button->set_disabled(!editable || !clip_is_dirty() || pose_pending);
        variant_button->set_disabled(!editable || pose_pending);
        reset_button->set_disabled(!editable || !clip_is_dirty());
        undo_button->set_disabled(!editable || undo_clip.empty());
        redo_button->set_disabled(!editable || redo_clip.empty());
        key_button->set_disabled(!editable || target_path.is_empty() || !pose_pending || playing);
        const String name = combo_mode ? combo->get_display_name() : clip_label(String(current_clip()));
        const String caption = name.is_empty() ? String(combo_mode ? "Untitled Combo" : "Weapon Animation") : name;
        const String desired = caption + String((combo_mode ? dirty : clip_is_dirty()) ? " *" : "");
        if (document->get_text() != desired) document->set_text(desired);
    }
    /// Synchronize numeric controls with the existing private draft and its loop range.
    void refresh_clip_tools() {
        if (!clip_tools) return;
        clip_tools->set_visible(!combo_mode);
        clip_sidebar->set_visible(!combo_mode);
        track_editor->set_visible(!combo_mode);
        if (combo_mode) {
            region_row->hide();
            timeline->set_clip_keys({}, -1, -1);
            return;
        }
        import_button->set_disabled(!ViewerClipImport::can_import(EditorInterface::get_singleton()->get_edited_scene_root(),
                player(), AnimationPreview::find_camera(player(), saved_clip)));
        const bool available = preview_clip.is_valid() && preview.get_length() > 0;
        const bool old_sync = syncing;
        syncing = true;
        for (size_t index = 0; index < motion_fields.size(); ++index) {
            if (index == 5 && available) {
                const double limit = std::max(6.0, std::ceil(clip_draft.base->get_length() * 2.0));
                motion_fields[index]->set_max(limit);
                motion_sliders[index]->set_max(limit);
            }
            motion_fields[index]->set_value_no_signal(clip_draft.motion[index]);
            motion_fields[index]->set_editable(available);
            motion_sliders[index]->set_value_no_signal(clip_draft.motion[index]);
            motion_sliders[index]->set_editable(available);
        }
        playback_option->select(static_cast<int>(clip_playback));
        playback_option->set_disabled(!available);
        region_row->set_visible(available && clip_playback == ClipPlayback::REGION);
        region_first->set_max(preview.get_length());
        region_last->set_max(preview.get_length());
        region_first->set_value_no_signal(loop_start);
        region_last->set_value_no_signal(loop_end < 0 ? preview.get_length() : loop_end);
        syncing = old_sync;
        publish_key_times();
        refresh_clip_buttons();
    }
    /// Draw and snap to actual transform keys instead of synthesized frame times.
    void publish_key_times() {
        std::set<double> times;
        if (!combo_mode && preview_clip.is_valid()) {
            Array paths;
            if (target_kind == StringName("bone")) paths.push_back(target_path);
            else paths = socket_paths();
            for (int index = 0; index < preview_clip->get_track_count(); ++index) {
                if (!preview_clip->track_is_enabled(index)) continue;
                const NodePath raw = preview_clip->track_get_path(index);
                const NodePath path(String(raw.get_concatenated_names()));
                if (!paths.has(path)) continue;
                for (int key = 0; key < preview_clip->track_get_key_count(index); ++key) {
                    times.insert(preview_clip->track_get_key_time(index, key));
                }
            }
        }
        const bool has_range = !combo_mode && clip_playback == ClipPlayback::REGION;
        timeline->set_clip_keys(std::vector<double>(times.begin(), times.end()), has_range ? loop_start : -1,
                loop_end < 0 ? preview.get_length() : loop_end);
    }
    /// Apply pending mount edits to the current private camera and restore clip controls.
    void restore_clip_preview_controls() {
        for (const auto &[path, transform] : clip_draft.mounts) {
            if (auto *mount = preview.get_preview_node(NodePath(path))) mount->set_transform(transform);
        }
        preview.set_pose_mode(pose_mode);
        preview.set_gizmo_rotation(gizmo_option->get_selected() == 1);
        refresh_guides(false);
        refresh_onion(0.0);
        adjust_comparison(comparison_time->get_value());
        pose_targets = preview.get_pose_targets();
        pose_targets_option->clear();
        int selected = -1;
        for (int index = 0; index < pose_targets.size(); ++index) {
            const Dictionary item = pose_targets[index];
            const String kind = item.get("kind", StringName());
            const NodePath path = item.get("path", NodePath());
            const String name = item.get("name", String());
            pose_targets_option->add_item(kind.capitalize() + " - " + name);
            pose_targets_option->set_item_tooltip(index, String(path));
            if (path == target_path) selected = index;
        }
        if (selected < 0 && !pose_targets.is_empty()) selected = 0;
        if (selected >= 0) {
            pose_targets_option->select(selected);
            select_pose_target(selected);
        } else {
            target_path = NodePath();
            target_kind = StringName();
            update_pose_anchor();
        }
        pose_targets_option->set_disabled(pose_targets.is_empty());
        track_editor->set_tracks(CrimsonWeaponAnimationTracks::from_animation(preview_clip), preview.get_length());
    }
    /// Choose a numeric or gizmo target and capture the sampled local transform.
    void select_pose_target(int64_t index) {
        if (combo_mode || index < 0 || index >= pose_targets.size()) return;
        if (pose_pending) preview.set_target_pose(pose_anchor);
        const Dictionary item = pose_targets[index];
        target_path = item.get("path", NodePath());
        target_kind = item.get("kind", StringName());
        preview.set_target(target_path);
        update_pose_anchor();
        publish_key_times();
        key_button->set_text(target_kind == StringName("mount") ? "Set Mount" : "Set Key");
    }
    /// Synchronize a joint picked in the preview with the native inspector.
    void select_pose_path(const NodePath &path) {
        for (int index = 0; index < pose_targets.size(); ++index) {
            const Dictionary item = pose_targets[index];
            if (NodePath(item.get("path", NodePath())) != path) continue;
            pose_targets_option->select(index);
            select_pose_target(index);
            break;
        }
    }
    /// Reset relative numeric controls after seeking or selecting a different transform.
    void update_pose_anchor() {
        pose_pending = false;
        pose_anchor = preview.get_target_pose();
        for (auto *field : pose_fields) {
            field->set_value_no_signal(0);
            field->set_editable(!target_path.is_empty() && !playing);
        }
        refresh_clip_buttons();
    }
    /// Manipulate the local preview transform without changing animation data.
    void pose_value_changed(double, int64_t) {
        if (syncing || combo_mode || target_path.is_empty() || playing) return;
        Transform3D pose = pose_anchor;
        const Vector3 shift(pose_fields[0]->get_value(), pose_fields[1]->get_value(), pose_fields[2]->get_value());
        const Vector3 rotation(Math::deg_to_rad(pose_fields[3]->get_value()),
                Math::deg_to_rad(pose_fields[4]->get_value()), Math::deg_to_rad(pose_fields[5]->get_value()));
        pose.basis = Basis::from_euler(rotation) * pose.basis;
        pose.origin += shift;
        preview.set_target_pose(pose);
        pose_pending = !shift.is_zero_approx() || !rotation.is_zero_approx();
        refresh_clip_buttons();
    }
    /// Reflect the completed gizmo preview in numeric controls until Set Key.
    void gizmo_committed(const Transform3D &pose) {
        if (combo_mode || target_path.is_empty() || playing) return;
        const Vector3 shift = pose.origin - pose_anchor.origin;
        const Basis delta = pose.basis.orthonormalized() * pose_anchor.basis.orthonormalized().inverse();
        const Vector3 rotation = delta.get_euler();
        for (int axis = 0; axis < 3; ++axis) {
            pose_fields[axis]->set_value_no_signal(shift[axis]);
            pose_fields[axis + 3]->set_value_no_signal(Math::rad_to_deg(rotation[axis]));
        }
        pose_pending = true;
        refresh_clip_buttons();
    }
    /// Commit a local mount offset or set a transform key on a detached clip copy.
    void commit_pose_key() {
        if (combo_mode || target_path.is_empty() || !pose_pending || playing || preview_clip.is_null()) return;
        const Transform3D pose = preview.get_target_pose();
        const ClipDraft before = clip_draft;
        if (target_kind == StringName("mount")) {
            clip_draft.mounts[String(target_path)] = pose;
        } else {
            Ref<Animation> next = preview_clip->duplicate(true);
            if (next.is_null() || !write_pose_key(next, target_path, preview.get_time(), pose)) {
                show_status("This target cannot store a transform key.");
                return;
            }
            clip_draft.base = next;
            clip_draft.motion = {0, 1, 1, 1, 0, next->get_length()};
        }
        remember_clip(before);
        pose_pending = false;
        rebuild(true);
    }
    /// Orbit for pose editing or restore the first-person view.
    void set_pose_mode(bool enabled) {
        pose_mode = enabled;
        preview.set_pose_mode(enabled && !combo_mode);
        pose_toggle->set_pressed_no_signal(enabled);
        refresh_transport();
    }
    /// Select an axis-constrained translation or rotation gizmo.
    void set_gizmo_mode(int64_t mode) { preview.set_gizmo_rotation(mode == 1); }
    /// Pass current socket and trail visibility to the private stage.
    void refresh_guides(bool) {
        preview.set_guides(!combo_mode && socket_toggle->is_pressed(), !combo_mode && trail_toggle->is_pressed());
    }
    /// Display neighboring posed samples at the selected spacing.
    void refresh_onion(double) {
        const double default_spacing = preview_clip.is_valid() ? preview_clip->get_step() : 1.0 / 60.0;
        const double step = ghost_spacing->get_value() > 0 ? ghost_spacing->get_value() : default_spacing;
        preview.set_onion(combo_mode ? 0 : past_ghosts->get_value(), combo_mode ? 0 : future_ghosts->get_value(), step);
    }
    /// List animations that can share the edited player and camera.
    void refill_comparison() {
        if (!comparison_option) return;
        StringName old;
        const int selected = comparison_option->get_selected();
        if (selected > 0) old = comparison_option->get_item_metadata(selected);
        comparison_option->clear();
        comparison_option->add_item("No comparison");
        comparison_option->select(0);
        for (const Variant &entry : available_clips) {
            const StringName key = entry;
            comparison_option->add_item(clip_label(String(key)));
            comparison_option->set_item_metadata(comparison_option->get_item_count() - 1, key);
            if (key == old) comparison_option->select(comparison_option->get_item_count() - 1);
        }
    }
    /// Clamp the independent ghost cursor to a newly selected animation.
    void change_comparison(int64_t) { adjust_comparison(0); }
    /// Sample a second first-person animation against the current pose.
    void adjust_comparison(double time) {
        if (syncing) return;
        AnimationPlayer *target = player();
        const int index = comparison_option->get_selected();
        Ref<Animation> compare;
        if (target && index > 0 && !combo_mode) {
            const StringName key = comparison_option->get_item_metadata(index);
            if (target->has_animation(key)) compare = target->get_animation(key);
        }
        const double length = compare.is_valid() ? compare->get_length() : 0;
        time = std::clamp(time, 0.0, length);
        const bool old_sync = syncing;
        syncing = true;
        comparison_ruler->set_max(length);
        comparison_time->set_max(length);
        comparison_ruler->set_value_no_signal(time);
        comparison_time->set_value_no_signal(time);
        comparison_time->set_editable(compare.is_valid());
        comparison_ruler->set_editable(compare.is_valid());
        syncing = old_sync;
        preview.set_comparison(target, compare, time);
    }
    /// Apply one of the three single-clip transport modes.
    void change_clip_playback(int64_t mode) {
        if (syncing || combo_mode) return;
        clip_playback = static_cast<ClipPlayback>(mode);
        rebuild(true);
    }
    /// Update one region endpoint and keep the range valid.
    void set_region_time(double seconds, bool out) {
        if (syncing || preview.get_length() <= 0.0) return;
        constexpr double frame_epsilon = 0.000001;
        if (out) loop_end = std::clamp(seconds, std::min(preview.get_length(), loop_start + frame_epsilon), preview.get_length());
        else loop_start = std::clamp(seconds, 0.0, std::max(0.0, (loop_end < 0 ? preview.get_length() : loop_end) - frame_epsilon));
        refresh_clip_tools();
    }
    /// Use the current private playhead as a loop endpoint.
    void mark_region(bool out) { set_region_time(preview.get_time(), out); }
    /// Populate an endpoint picker from native or legacy marker records.
    void fill_endpoint(OptionButton *selector, SpinBox *seconds, const Ref<CrimsonWeaponAnimationClip> &clip,
            const StringName &name, double custom_time, bool outgoing) {
        selector->clear();
        selector->add_item(outgoing ? "Clip End" : "Clip Start");
        selector->add_item("Custom Time");
        int chosen = custom_time < 0 ? 0 : 1;
        const double duration = clip.is_valid() ? clip->get_duration() : std::max(0.0, custom_time);
        const double boundary = outgoing ? duration : 0.0;
        double resolved = chosen == 0 ? boundary : custom_time;
        if (clip.is_valid()) {
            for (const Variant &entry : clip->get_markers()) {
                const Dictionary marker = entry;
                const StringName marker_name = marker.get("name", StringName());
                selector->add_item(String(marker_name));
                selector->set_item_metadata(selector->get_item_count() - 1, marker_name);
                if (name == marker_name) {
                    chosen = selector->get_item_count() - 1;
                    resolved = marker.get("time", resolved);
                }
            }
        }
        if (name != StringName() && chosen <= 1) {
            selector->add_item(String(name) + " (missing)");
            chosen = selector->get_item_count() - 1;
            selector->set_item_metadata(chosen, name);
        }
        selector->select(chosen);
        seconds->set_max(duration);
        seconds->set_value_no_signal(std::clamp(resolved, 0.0, duration));
        seconds->set_editable(chosen == 1);
    }
    /// Reconcile the selected join's source and endpoint fields.
    void refresh_join() {
        const int count = combo->get_join_count();
        join_inspector->set_visible(combo_mode && count > 0);
        if (!combo_mode || count <= 0) return;
        join_index = std::clamp(join_index, 0, count - 1);
        const auto keys = combo->get_clip_keys();
        const StringName outgoing_key = keys[join_index];
        const StringName incoming_key = keys[(join_index + 1) % keys.size()];
        const Dictionary join = combo->get_join(join_index);
        exit_label->set_text("Exit - " + clip_label(String(outgoing_key)));
        entry_label->set_text("Entry - " + clip_label(String(incoming_key)));
        exit_label->set_tooltip_text(String(outgoing_key));
        entry_label->set_tooltip_text(String(incoming_key));
        syncing = true;
        const auto out = CrimsonWeaponAnimationClip::from_player(player(), outgoing_key);
        const auto in = CrimsonWeaponAnimationClip::from_player(player(), incoming_key);
        fill_endpoint(exit_marker, exit_time, out, join.get("exit_marker", StringName()), join.get("exit_time", -1.0), true);
        fill_endpoint(entry_marker, entry_time, in, join.get("entry_marker", StringName()), join.get("entry_time", -1.0), false);
        blend_time->set_value_no_signal(join.get("blend_duration", 0.0));
        syncing = false;
    }
    /// Select a transition and seek to its effective overlap midpoint.
    void select_join(int64_t index) {
        if (index < 0 || index >= combo->get_join_count()) return;
        join_index = index;
        select_clip(index);
        for (const auto &band : preview.get_blend_bands()) {
            if (band.index == join_index) {
                seek_preview((band.start + band.end) / 2.0);
                break;
            }
        }
    }
    /// Select a clip for the sequence ordering commands.
    void select_clip(int64_t index) {
        if (index < 0 || index >= combo->get_clip_keys().size()) return;
        clip_index = index;
        refresh_tools(false);
    }
    /// Open the selected join and continue playing within its short context.
    void loop_join() {
        focus_join = true;
        rebuild(false);
        set_playing(preview.get_length() > 0);
    }
    /// Return to a paused overview of the full sequence.
    void show_sequence() {
        focus_join = false;
        rebuild(false);
        select_join(join_index);
    }
    /// Store the current endpoint field values in the selected join's draft.
    void apply_join() {
        if (syncing || join_index >= combo->get_join_count()) return;
        const int out = exit_marker->get_selected();
        const int in = entry_marker->get_selected();
        combo->set_join(join_index,
                out > 1 ? StringName(exit_marker->get_item_metadata(out)) : StringName(),
                in > 1 ? StringName(entry_marker->get_item_metadata(in)) : StringName(),
                blend_time->get_value(), out == 1 ? exit_time->get_value() : -1, in == 1 ? entry_time->get_value() : -1);
        dirty = true;
        rebuild(true);
    }
    /// Convert the selected endpoint option after committing its current time.
    void endpoint_selected(int64_t) { apply_join(); }
    /// Update native live preview immediately after an inspector value is committed.
    void endpoint_changed(double) { apply_join(); }
    /// Switch wrapping for the active playback mode.
    void set_loop(bool enabled) {
        if (syncing || !combo_mode) return;
        combo->set_loop(enabled);
        join_index = std::clamp(join_index, 0, std::max(0, static_cast<int>(combo->get_join_count()) - 1));
        dirty = true;
        rebuild(true);
    }
    /// Update clip order while preserving unchanged adjacent-pair edits.
    void set_order(const TypedArray<StringName> &order, int index) {
        combo->set_clips(order);
        clip_index = index;
        join_index = std::clamp(index, 0, std::max(0, static_cast<int>(combo->get_join_count()) - 1));
        dirty = true;
        combo_mode = true;
        focus_join = false;
        rebuild(false);
    }
    /// Append the currently selected animation to the draft.
    void add_clip() {
        const StringName key = current_clip();
        if (key == StringName()) return;
        TypedArray<StringName> order = combo->get_clip_keys().duplicate();
        order.push_back(key);
        set_order(order, order.size() - 1);
    }
    /// Delete an authored sequence step without altering the player animation library.
    void remove_clip() {
        TypedArray<StringName> order = combo->get_clip_keys().duplicate();
        if (clip_index < 0 || clip_index >= order.size()) return;
        order.remove_at(clip_index);
        set_order(order, std::min(clip_index, static_cast<int>(order.size()) - 1));
    }
    /// Move one sequence clip to another valid index.
    void reorder_clip(int64_t from, int64_t to) {
        TypedArray<StringName> order = combo->get_clip_keys().duplicate();
        if (from < 0 || from >= order.size() || to < 0 || to >= order.size() || from == to) return;
        const StringName key = order[from];
        order.remove_at(from);
        order.insert(to, key);
        set_order(order, to);
    }
    /// Apply an accessible one-step ordering command from the toolbar.
    void shift_clip(int64_t direction) { reorder_clip(clip_index, clip_index + direction); }
    /// Show only the editor-owned preview clock while the window is playing.
    void set_playing(bool enabled) {
        const bool was_playing = playing;
        playing = enabled && preview.get_length() > 0;
        preview.set_playing(playing);
        set_process(playing);
        if (!combo_mode && (playing || was_playing)) {
            if (playing && pose_pending) preview.seek(preview.get_time());
            update_pose_anchor();
        }
        if (play_button) refresh_transport();
    }
    /// Start the current duration from the beginning if it reached the endpoint.
    void toggle_playing() {
        if (!playing && !combo_mode && clip_playback == ClipPlayback::REGION) {
            const double end = loop_end < 0 ? preview.get_length() : loop_end;
            if (preview.get_time() < loop_start || preview.get_time() >= end) preview.seek(loop_start);
        } else if (!playing && preview.get_time() >= preview.get_length()) {
            preview.seek(0);
        }
        set_playing(!playing);
    }
    /// Pause and display the pose at a precise timeline position.
    void seek_preview(double seconds) {
        set_playing(false);
        preview.seek(seconds);
        if (!combo_mode) update_pose_anchor();
        refresh_transport();
    }
    /// Zoom the ruler from a command in the transport strip.
    void zoom(double scale) { timeline->zoom(scale); }
    /// Fit the current clip or editable sequence.
    void fit_timeline() { timeline->fit(); }
    /// Obtain an independent native draft from either a native or older saved resource.
    void load_combo(const String &path) {
        const Ref<Resource> resource = ResourceLoader::get_singleton()->load(path, "", ResourceLoader::CACHE_MODE_IGNORE);
        const auto loaded = CrimsonWeaponAnimationCombo::from_resource(resource);
        if (loaded.is_null()) {
            status->set_text("Choose a weapon animation combo resource.");
            status->show();
            return;
        }
        combo = loaded;
        combo_path = path;
        dirty = false;
        combo_mode = true;
        focus_join = false;
        clip_index = -1;
        join_index = 0;
        rebuild(false);
    }
    /// Save an independent draft so rebuilding the preview cannot mutate the saved object.
    void save_combo(const String &path) {
        if (!combo_mode || combo->get_clip_keys().size() < 2) {
            status->set_text("Add at least two clips before saving a combo.");
            status->show();
            return;
        }
        Ref<CrimsonWeaponAnimationCombo> snapshot = combo->copy();
        if (snapshot->get_display_name().strip_edges().is_empty()) {
            snapshot->set_display_name(path.get_file().get_basename());
        }
        const Error saved = ResourceSaver::get_singleton()->save(snapshot, path);
        if (saved == OK) {
            combo_path = path;
            dirty = false;
            combo->set_display_name(snapshot->get_display_name());
            EditorInterface::get_singleton()->get_resource_filesystem()->update_file(path);
            refresh_tools(false);
        }
        status->set_text(saved == OK ? "Saved " + path.get_file() : "Could not save the combo.");
        status->show();
    }
    /// Use a shared editor resource picker with the correct scope and file filter.
    void show_dialog(int64_t operation) {
        set_playing(false);
        file_action = static_cast<FileAction>(operation);
        const bool write = file_action == FileAction::SAVE_COMBO;
        file_dialog->set_file_mode(write ? EditorFileDialog::FILE_MODE_SAVE_FILE : EditorFileDialog::FILE_MODE_OPEN_FILE);
        file_dialog->clear_filters();
        file_dialog->set_access(file_action == FileAction::VIEWER_PACK ? EditorFileDialog::ACCESS_FILESYSTEM : EditorFileDialog::ACCESS_RESOURCES);
        switch (file_action) {
            case FileAction::VIEWER_PACK:
                import_target = animation_player;
                file_dialog->set_title("Open Viewer Clip Pack");
                file_dialog->add_filter("*.json", "Viewer clip packs");
                file_dialog->set_current_file("");
                break;
            case FileAction::PLAY_SCENE:
                file_dialog->set_title("Choose Preview Play Scene");
                file_dialog->add_filter("*.tscn, *.scn", "Godot scenes");
                file_dialog->set_current_path(play_scene_path.is_empty() ? String("res://") : play_scene_path);
                break;
            case FileAction::OPEN_COMBO:
            case FileAction::SAVE_COMBO:
                file_dialog->set_title(write ? "Save Animation Combo" : "Open Animation Combo");
                file_dialog->add_filter("*.tres, *.res", "Godot resources");
                file_dialog->set_current_dir(combo_path.is_empty() ? String("res://") : combo_path.get_base_dir());
                file_dialog->set_current_file(write ? String("animation_combo.tres") : String());
                break;
        }
        file_dialog->popup_centered_clamped(Vector2i(ui::pixels(this, 760), ui::pixels(this, 510)));
    }
    /// Dispatch a user-confirmed file operation outside the private viewport.
    void file_selected(const String &path) {
        switch (file_action) {
            case FileAction::OPEN_COMBO: load_combo(path); break;
            case FileAction::SAVE_COMBO: save_combo(path); break;
            case FileAction::VIEWER_PACK:
                file_dialog->hide();
                read_import_pack(path);
                break;
            case FileAction::PLAY_SCENE:
                play_scene_path = path;
                play_scene_button->set_tooltip_text(path);
                break;
        }
    }
    /// Run the chosen scene with a fallback to the scene in front of the editor.
    void play_scene() {
        set_playing(false);
        String path = play_scene_path;
        if (path.is_empty()) {
            if (Node *scene = EditorInterface::get_singleton()->get_edited_scene_root()) path = scene->get_scene_file_path();
        }
        if (path.is_empty() || !ResourceLoader::get_singleton()->exists(path, "PackedScene")) {
            show_status("Choose a saved Godot scene to run.");
            return;
        }
        EditorInterface::get_singleton()->play_custom_scene(path);
    }
    /// Read the source clip's owning library ID.
    StringName clip_library() const {
        const String path(draft_key);
        const int index = path.find("/");
        return index >= 0 ? StringName(path.left(index)) : StringName();
    }
    /// Return a validation line for a new clip name in the selected library.
    String variant_name_error(const String &raw) const {
        if (!owns_player() || saved_clip.is_null() || preview_clip.is_null() || pose_pending) return "Select an editable animation and finish its pose edit.";
        const String name = raw.strip_edges();
        if (name.is_empty()) return "Enter a new clip name.";
        if (name.contains("/") || name.contains(":") || name.contains(",") || name.contains("[")) return "Clip names cannot use / : , or [.";
        AnimationPlayer *target = player();
        const StringName key = clip_library();
        if (!target->has_animation_library(key)) return "Select an animation library.";
        const Ref<AnimationLibrary> library = target->get_animation_library(key);
        return library->has_animation(name) ? String("This clip name already exists in the library.") : String();
    }
    /// Update the Save Variant dialog as the user types.
    void validate_variant(const String &name) {
        const String error = variant_name_error(name);
        variant_dialog->get_ok_button()->set_disabled(!error.is_empty());
        variant_error->set_text(error.is_empty() && !clip_draft.mounts.empty() ? "Apply the draft to save mount changes." : error);
        variant_error->set_visible(!variant_error->get_text().is_empty());
    }
    /// Propose an unused _vN name next to the current animation.
    void open_variant() {
        if (!owns_player() || preview_clip.is_null() || pose_pending) return;
        set_playing(false);
        const Ref<AnimationLibrary> library = player()->get_animation_library(clip_library());
        const String base = String(draft_key).get_file();
        int next = 2;
        String name;
        do {
            name = base + String("_v") + String::num_int64(next++);
        } while (library->has_animation(name));
        variant_name->set_text(name);
        validate_variant(name);
        variant_dialog->popup_centered_clamped(Vector2i(ui::pixels(this, 460), ui::pixels(this, 160)));
        variant_name->grab_focus();
        variant_name->select_all();
    }
    /// Commit a new clip while leaving the original animation and mount transforms intact.
    void save_variant() {
        const String name = variant_name->get_text().strip_edges();
        if (!variant_name_error(name).is_empty()) return;
        if (!commit_clip(name, true)) return;
        const String library(clip_library());
        const StringName key(library.is_empty() ? name : library + String("/") + name);
        refresh_scene();
        for (int index = 0; index < available_clips.size(); ++index) {
            if (StringName(available_clips[index]) == key) {
                clip_options->select(index);
                select_source(index);
                break;
            }
        }
    }
    /// Write scene-owned animation and mount changes into Godot editor history atomically.
    bool commit_clip(const StringName &name, bool variant) {
        if (!scene_history || !owns_player() || preview_clip.is_null() || pose_pending) return false;
        AnimationPlayer *target = player();
        if (!target->has_animation(draft_key) || target->get_animation(draft_key) != saved_clip) {
            show_status("The source clip changed. Refresh the rig before applying edits.");
            return false;
        }
        const StringName destination = clip_library();
        const Ref<AnimationLibrary> previous = target->get_animation_library(destination);
        Ref<AnimationLibrary> updated = previous->duplicate();
        Ref<Animation> copy = preview_clip->duplicate(true);
        if (updated.is_null() || copy.is_null()) return false;
        copy->set_name(String(name));
        if (!variant) updated->remove_animation(name);
        if (updated->add_animation(name, copy) != OK) return false;
        Node *rig = animation_root();
        Node *scene = EditorInterface::get_singleton()->get_edited_scene_root();
        if (!variant) {
            for (const auto &[path, transform] : clip_draft.mounts) {
                const auto *mount = rig ? Object::cast_to<Node3D>(rig->get_node_or_null(NodePath(path))) : nullptr;
                if (!mount || (mount != scene && mount->get_owner() != scene)) {
                    show_status("Open the scene that owns the selected sword mount to apply its transform.");
                    return false;
                }
            }
        }
        scene_history->create_action(variant ? "Save Weapon Animation Variant" : "Apply Weapon Animation Draft", UndoRedo::MERGE_DISABLE, target);
        const StringName property(String("libraries/") + String(destination));
        scene_history->add_do_property(target, property, updated);
        scene_history->add_undo_property(target, property, previous);
        if (!variant) {
            for (const auto &[path, transform] : clip_draft.mounts) {
                auto *mount = Object::cast_to<Node3D>(rig->get_node_or_null(NodePath(path)));
                scene_history->add_do_property(mount, "transform", transform);
                scene_history->add_undo_property(mount, "transform", mount->get_transform());
            }
        }
        scene_history->commit_action();
        return true;
    }
    /// Apply the active clip without modifying other resources in its animation library.
    void apply_clip() {
        set_playing(false);
        if (commit_clip(StringName(String(draft_key).get_file()), false)) {
            refresh_scene();
            show_status("Applied to the edited scene.");
        }
    }
    /// Parse a selected Viewer pack and display eligible clips with readable names.
    void read_import_pack(const String &path) {
        if (import_target != animation_player) return;
        import_pack = ViewerClipImport::inspect(path);
        const String error = import_pack.get("error", String());
        if (!error.is_empty()) {
            show_status(error);
            return;
        }
        import_items->clear();
        const Array clips = import_pack.get("clips", Array());
        for (int index = 0; index < clips.size(); ++index) {
            const Dictionary row = clips[index];
            const String name = row.get("name", String());
            const String set = row.get("weapon_set", String("Unclassified"));
            import_items->add_item(set + String(" - ") + ViewerClipImport::clip_label(name));
            import_items->set_item_tooltip(index, name);
            import_items->select(index, false);
        }
        AnimationPlayer *target = player();
        if (!target) return;
        import_libraries->clear();
        import_libraries->add_item("New Library");
        for (const Variant &entry : target->get_animation_library_list()) {
            const StringName key = entry;
            import_libraries->add_item(key == StringName() ? String("Global Animation Library") : String(key));
            import_libraries->set_item_metadata(import_libraries->get_item_count() - 1, key);
        }
        import_libraries->select(0);
        import_name->set_text(ViewerClipImport::suggested_library_name(target, import_pack));
        validate_import();
        import_dialog->popup_centered_clamped(Vector2i(ui::pixels(this, 600), ui::pixels(this, 460)));
    }
    /// Return the requested library, preserving the empty ID for the global library.
    StringName import_library() const {
        const int selected = import_libraries->get_selected();
        return selected <= 0 ? StringName(import_name->get_text().strip_edges()) : StringName(import_libraries->get_item_metadata(selected));
    }
    /// Enable Import only for a valid destination and a nonempty selection.
    void validate_import() {
        const bool create = import_libraries->get_selected() <= 0;
        import_name->set_visible(create);
        String error = ViewerClipImport::destination_error(player(), import_library(), create);
        if (error.is_empty() && import_items->get_selected_items().is_empty()) error = "Select at least one clip.";
        import_error->set_text(error);
        import_error->set_visible(!error.is_empty());
        import_dialog->get_ok_button()->set_disabled(!error.is_empty());
    }
    /// Refresh the destination validator after changing library choice.
    void import_library_changed(int64_t) { validate_import(); }
    /// Refresh the destination validator after typing.
    void import_name_changed(const String &) { validate_import(); }
    /// Refresh the validator after selecting or deselecting an individual clip.
    void import_selection_changed(int64_t, bool) { validate_import(); }
    /// Commit the pack to the original authored rig in Godot editor history.
    void commit_import() {
        AnimationPlayer *target = player();
        if (!target || import_target != animation_player) {
            show_status("Select the same player scene that opened this pack before importing.");
            return;
        }
        const PackedInt32Array selected = import_items->get_selected_items();
        if (selected.is_empty()) return;
        const Dictionary result = ViewerClipImport::commit(EditorInterface::get_singleton()->get_edited_scene_root(), target,
                AnimationPreview::find_camera(target, saved_clip), scene_history, import_pack, import_library(),
                import_libraries->get_selected() <= 0, selected);
        const String error = result.get("error", String());
        const String message = error.is_empty() ? String(result.get("message", String())) : error;
        import_pack.clear();
        refresh_scene();
        show_status(message);
    }
    /// Stop and hide the window while retaining a draft in memory.
    void close_window() { set_playing(false); hide(); }
    /// Create one precise inspector number field with the matching update callback.
    SpinBox *number(HBoxContainer *row, const String &title) {
        return field_number(row, title, 0.0, 60.0, 0.001, " s", callable_mp(this, &WeaponAnimationWindow::endpoint_changed));
    }
    /// Create a bounded themed numeric field with an accessible name.
    SpinBox *field_number(HBoxContainer *row, const String &title, double low, double high,
            double step, const String &suffix, const Callable &changed) {
        auto *input = memnew(SpinBox);
        input->set_step(step);
        input->set_min(low);
        input->set_max(high);
        input->set_suffix(suffix);
        input->set_tooltip_text(title);
        input->set_accessibility_name(title);
        row->add_child(input);
        input->connect("value_changed", changed);
        return input;
    }
    /// Use one captioned row for a compact group of draft controls.
    HBoxContainer *field_row(VBoxContainer *body, const String &caption, double label_width = 88) {
        auto *row = memnew(HBoxContainer);
        body->add_child(row);
        auto *label = ui::label(row, caption, ui::LabelStyle::MUTED);
        label->set_custom_minimum_size(Vector2(ui::pixels(this, label_width), 0));
        return row;
    }
    /// Build the clip pose and motion inspector used beside the first-person view.
    Control *build_clip_sidebar() {
        auto *pane = memnew(PanelContainer);
        pane->set_custom_minimum_size(Vector2(ui::pixels(this, 276), 0));
        auto *layout = memnew(VBoxContainer);
        pane->add_child(layout);
        auto *scroll = memnew(ScrollContainer);
        scroll->set_horizontal_scroll_mode(ScrollContainer::SCROLL_MODE_DISABLED);
        scroll->set_v_size_flags(Control::SIZE_EXPAND_FILL);
        layout->add_child(scroll);
        auto *body = memnew(VBoxContainer);
        body->set_h_size_flags(Control::SIZE_EXPAND_FILL);
        body->add_theme_constant_override("separation", ui::pixels(this, ui::spacing::xs));
        ui::inset(scroll, 10, 8)->add_child(body);
        ui::label(body, "Transform", ui::LabelStyle::HEADING);
        pose_targets_option = memnew(OptionButton);
        pose_targets_option->set_fit_to_longest_item(false);
        pose_targets_option->set_text_overrun_behavior(TextServer::OVERRUN_TRIM_ELLIPSIS);
        pose_targets_option->set_accessibility_name("Editable weapon rig target");
        body->add_child(pose_targets_option);
        pose_targets_option->connect("item_selected", callable_mp(this, &WeaponAnimationWindow::select_pose_target));
        constexpr std::array<const char *, 6> axis_names{"Position X", "Position Y", "Position Z",
                "Rotation X", "Rotation Y", "Rotation Z"};
        for (size_t axis = 0; axis < axis_names.size(); ++axis) {
            auto *row = field_row(body, axis_names[axis]);
            const bool rotation = axis >= 3;
            pose_fields[axis] = field_number(row, axis_names[axis], rotation ? -360.0 : -5.0,
                    rotation ? 360.0 : 5.0, rotation ? 0.1 : 0.001, rotation ? "" : " m",
                    callable_mp(this, &WeaponAnimationWindow::pose_value_changed).bind(static_cast<int64_t>(axis)));
            pose_fields[axis]->set_h_size_flags(Control::SIZE_EXPAND_FILL);
        }
        key_button = ui::button(body, "Set Key", "Record the private transform at the cursor.",
                callable_mp(this, &WeaponAnimationWindow::commit_pose_key));
        ui::label(body, "Clip Motion", ui::LabelStyle::HEADING);
        constexpr std::array<const char *, 6> motion_names{"Vertical", "Width", "Height", "Depth", "Camera Depth", "Duration"};
        for (size_t axis = 0; axis < motion_names.size(); ++axis) {
            auto *row = field_row(body, motion_names[axis]);
            const bool distance = axis == 0 || axis == 4;
            const bool duration = axis == 5;
            const double low = distance ? -3.0 : duration ? 0.001 : 0.0;
            const double high = duration ? 6.0 : 3.0;
            const double step = distance || duration ? 0.001 : 0.01;
            const auto change = callable_mp(this, &WeaponAnimationWindow::motion_changed).bind(static_cast<int64_t>(axis));
            auto *slider = memnew(HSlider);
            slider->set_min(low);
            slider->set_max(high);
            slider->set_step(step);
            slider->set_h_size_flags(Control::SIZE_EXPAND_FILL);
            slider->set_accessibility_name(motion_names[axis]);
            slider->set_tooltip_text(motion_names[axis]);
            slider->connect("value_changed", change);
            slider->connect("drag_started", callable_mp(this, &WeaponAnimationWindow::begin_motion_drag));
            slider->connect("drag_ended", callable_mp(this, &WeaponAnimationWindow::finish_motion_drag));
            row->add_child(slider);
            motion_sliders[axis] = slider;
            motion_fields[axis] = field_number(row, motion_names[axis], low, high, step, distance ? " m" : duration ? " s" : "", change);
            motion_fields[axis]->set_custom_minimum_size(Vector2(ui::pixels(this, 85), 0));
        }
        auto *footer = memnew(VBoxContainer);
        ui::inset(layout, 10, 6)->add_child(footer);
        auto *history_row = memnew(HBoxContainer);
        footer->add_child(history_row);
        undo_button = ui::button(history_row, "Undo", "Undo the last clip-draft edit.",
                callable_mp(this, &WeaponAnimationWindow::step_clip_history).bind(false));
        redo_button = ui::button(history_row, "Redo", "Redo the last clip-draft edit.",
                callable_mp(this, &WeaponAnimationWindow::step_clip_history).bind(true));
        reset_button = ui::button(history_row, "Reset", "Restore this draft to the saved clip.",
                callable_mp(this, &WeaponAnimationWindow::reset_clip));
        auto *save_row = memnew(HBoxContainer);
        footer->add_child(save_row);
        apply_button = ui::button(save_row, "Apply", "Write clip and mount edits to the current scene.",
                callable_mp(this, &WeaponAnimationWindow::apply_clip), ui::ButtonStyle::PRIMARY);
        variant_button = ui::button(save_row, "Save Variant", "Save a new clip in the current animation library.",
                callable_mp(this, &WeaponAnimationWindow::open_variant));
        return pane;
    }
    /// Create the viewport's editing mode, guides, and independent comparison controls.
    void build_clip_view_tools(VBoxContainer *stage) {
        auto *tools = memnew(VBoxContainer);
        clip_tools = tools;
        stage->add_child(tools);
        auto *first = memnew(HBoxContainer);
        tools->add_child(first);
        pose_toggle = memnew(CheckButton);
        pose_toggle->set_text("Pose View");
        pose_toggle->set_tooltip_text("Orbit and select the private pose skeleton with Tab.");
        pose_toggle->connect("toggled", callable_mp(this, &WeaponAnimationWindow::set_pose_mode));
        first->add_child(pose_toggle);
        gizmo_option = memnew(OptionButton);
        gizmo_option->add_item("Move");
        gizmo_option->add_item("Rotate");
        gizmo_option->set_tooltip_text("Choose a translation or rotation gizmo.");
        gizmo_option->connect("item_selected", callable_mp(this, &WeaponAnimationWindow::set_gizmo_mode));
        first->add_child(gizmo_option);
        socket_toggle = memnew(CheckButton);
        socket_toggle->set_text("Sockets");
        socket_toggle->connect("toggled", callable_mp(this, &WeaponAnimationWindow::refresh_guides));
        first->add_child(socket_toggle);
        trail_toggle = memnew(CheckButton);
        trail_toggle->set_text("Trails");
        trail_toggle->connect("toggled", callable_mp(this, &WeaponAnimationWindow::refresh_guides));
        first->add_child(trail_toggle);
        auto *second = memnew(HBoxContainer);
        tools->add_child(second);
        ui::label(second, "Onion", ui::LabelStyle::MUTED);
        const auto update = callable_mp(this, &WeaponAnimationWindow::refresh_onion);
        past_ghosts = field_number(second, "Earlier poses", 0, 3, 1, " past", update);
        future_ghosts = field_number(second, "Later poses", 0, 3, 1, " next", update);
        ghost_spacing = field_number(second, "Onion spacing in seconds. Zero uses the animation step.", 0, 1, 0.001, " s", update);
        comparison_option = memnew(OptionButton);
        comparison_option->set_fit_to_longest_item(false);
        comparison_option->set_text_overrun_behavior(TextServer::OVERRUN_TRIM_ELLIPSIS);
        comparison_option->set_accessibility_name("Ghost comparison animation");
        comparison_option->add_item("No comparison");
        comparison_option->set_h_size_flags(Control::SIZE_EXPAND_FILL);
        second->add_child(comparison_option);
        comparison_option->connect("item_selected", callable_mp(this, &WeaponAnimationWindow::change_comparison));
        comparison_ruler = memnew(HSlider);
        comparison_ruler->set_h_size_flags(Control::SIZE_EXPAND_FILL);
        comparison_ruler->set_max(0);
        comparison_ruler->set_step(0.001);
        comparison_ruler->set_tooltip_text("Scrub the comparison ghost in its own clip time.");
        comparison_ruler->set_accessibility_name("Comparison timeline");
        second->add_child(comparison_ruler);
        const auto compare_time = callable_mp(this, &WeaponAnimationWindow::adjust_comparison);
        comparison_ruler->connect("value_changed", compare_time);
        comparison_time = field_number(second, "Comparison Time", 0, 0, 0.001, " s", compare_time);
    }
    /// Initialize native Save Variant and Viewer import dialogs.
    void build_authoring_dialogs() {
        variant_dialog = memnew(ConfirmationDialog);
        add_child(variant_dialog);
        variant_dialog->set_theme(get_theme());
        variant_dialog->set_title("Save Animation Variant");
        variant_dialog->set_ok_button_text("Save Variant");
        auto *variant_body = memnew(VBoxContainer);
        variant_dialog->add_child(variant_body);
        variant_name = ui::text_input(variant_body, "", "Unique name in the selected animation library.");
        variant_dialog->register_text_enter(variant_name);
        variant_name->connect("text_changed", callable_mp(this, &WeaponAnimationWindow::validate_variant));
        variant_error = ui::label(variant_body, "", ui::LabelStyle::MUTED);
        variant_error->set_autowrap_mode(TextServer::AUTOWRAP_WORD_SMART);
        variant_dialog->connect("confirmed", callable_mp(this, &WeaponAnimationWindow::save_variant));

        import_dialog = memnew(ConfirmationDialog);
        add_child(import_dialog);
        import_dialog->set_theme(get_theme());
        import_dialog->set_title("Import Viewer Animations");
        import_dialog->set_ok_button_text("Import");
        auto *import_body = memnew(VBoxContainer);
        import_dialog->add_child(import_body);
        import_items = memnew(ItemList);
        import_items->set_select_mode(ItemList::SELECT_MULTI);
        import_items->set_custom_minimum_size(Vector2(ui::pixels(this, 540), ui::pixels(this, 250)));
        import_items->set_v_size_flags(Control::SIZE_EXPAND_FILL);
        import_items->set_accessibility_name("Viewer animations to import");
        import_body->add_child(import_items);
        import_items->connect("multi_selected", callable_mp(this, &WeaponAnimationWindow::import_selection_changed));
        import_libraries = memnew(OptionButton);
        import_libraries->set_accessibility_name("Animation library destination");
        import_body->add_child(import_libraries);
        import_libraries->connect("item_selected", callable_mp(this, &WeaponAnimationWindow::import_library_changed));
        import_name = ui::text_input(import_body, "", "Name for a new animation library.");
        import_name->connect("text_changed", callable_mp(this, &WeaponAnimationWindow::import_name_changed));
        import_error = ui::label(import_body, "", ui::LabelStyle::MUTED);
        import_error->set_autowrap_mode(TextServer::AUTOWRAP_WORD_SMART);
        import_dialog->connect("confirmed", callable_mp(this, &WeaponAnimationWindow::commit_import));
    }
    /// Refresh affected source libraries when the editor replays a scene action.
    void scene_history_changed() {
        if (is_visible()) callable_mp(this, &WeaponAnimationWindow::refresh_scene).call_deferred();
    }
    /// Populate the private viewport with an authored stage or neutral preview lighting.
    void build_reference_stage(SubViewport *viewport) {
        const String path = ProjectSettings::get_singleton()->get_setting(preview_stage_setting, String());
        if (!path.is_empty() && ResourceLoader::get_singleton()->exists(path, "PackedScene")) {
            const Ref<PackedScene> stage = ResourceLoader::get_singleton()->load(path, "PackedScene");
            if (stage.is_valid()) {
                viewport->add_child(stage->instantiate());
                return;
            }
        }
        Ref<Environment> ambient;
        ambient.instantiate();
        ambient->set_background(Environment::BG_COLOR);
        ambient->set_bg_color(Color(0.11, 0.12, 0.15));
        ambient->set_ambient_source(Environment::AMBIENT_SOURCE_COLOR);
        ambient->set_ambient_light_color(Color(0.69, 0.75, 0.85));
        ambient->set_ambient_light_energy(0.55);
        auto *environment = memnew(WorldEnvironment);
        environment->set_environment(ambient);
        viewport->add_child(environment);
        auto *key_light = memnew(DirectionalLight3D);
        key_light->set_rotation_degrees(Vector3(-45, -30, 0));
        viewport->add_child(key_light);
    }

protected:
    /// The tool is opened by the framework's project-menu command.
    static void _bind_methods() {}

    /// Update the active preview only when the window owns a running clock.
    void _notification(int what) {
        if (what != NOTIFICATION_PROCESS || !playing) return;
        const double delta = get_process_delta_time();
        if (!combo_mode && clip_playback == ClipPlayback::REGION) {
            const double end = loop_end < 0 ? preview.get_length() : loop_end;
            const double span = end - loop_start;
            if (span > 0) {
                const double current = std::clamp(preview.get_time(), loop_start, end);
                preview.seek(loop_start + std::fmod(current - loop_start + delta, span));
                refresh_transport();
                return;
            }
        }
        preview.advance(delta);
        if (!preview.is_looping() && preview.get_time() >= preview.get_length()) set_playing(false);
        else refresh_transport();
    }

public:
    /// Keep clip edit shortcuts scoped to the window and preserve text editing shortcuts.
    void _shortcut_input(const Ref<InputEvent> &event) override {
        if (!is_visible() || !has_focus() || combo_mode || file_dialog->is_visible() ||
                variant_dialog->is_visible() || import_dialog->is_visible()) return;
        const Ref<InputEventKey> key = event;
        if (key.is_null() || !key->is_pressed() || key->is_echo() || key->is_alt_pressed()) return;
        if (const Control *focus = gui_get_focus_owner()) {
            if (focus->is_class("LineEdit") || focus->is_class("TextEdit") || focus->is_class("CodeEdit")) return;
        }
        if (key->is_command_or_control_pressed() && (key->get_keycode() == KEY_Z || key->get_keycode() == KEY_Y)) {
            step_clip_history(key->get_keycode() == KEY_Y || key->is_shift_pressed());
        } else if (!key->is_command_or_control_pressed() && !key->is_shift_pressed()) {
            if (key->get_keycode() == KEY_TAB) set_pose_mode(!pose_mode);
            else if (key->get_keycode() == KEY_M) track_editor->add_marker_at_playhead();
            else return;
        } else {
            return;
        }
        set_input_as_handled();
    }
    /// Build the toolkit window and establish the private pose viewport.
    void build(EditorPlugin *plugin) {
        combo.instantiate();
        scene_history = plugin->get_undo_redo();
        play_scene_path = ProjectSettings::get_singleton()->get_setting(play_scene_setting, String());
        set_name("CrimsonWeaponAnimationWindow");
        set_title("Weapon Animation");
        set_theme(ui::create_theme(this, EditorInterface::get_singleton()->get_editor_scale()));
        set_min_size(Vector2i(ui::pixels(this, 820), ui::pixels(this, 560)));
        set_size(Vector2i(ui::pixels(this, 1220), ui::pixels(this, 800)));
        ui::embed_editor_popups(this);
        connect("close_requested", callable_mp(this, &WeaponAnimationWindow::close_window));
        plugin->connect("scene_changed", callable_mp(this, &WeaponAnimationWindow::edited_scene_changed));
        scene_history->connect("version_changed", callable_mp(this, &WeaponAnimationWindow::scene_history_changed));
        set_process(false);
        set_process_shortcut_input(true);

        PanelContainer *surface = ui::surface_panel(this, ui::Surface::CANVAS);
        surface->set_anchors_and_offsets_preset(Control::PRESET_FULL_RECT);
        auto *content = memnew(VBoxContainer);
        ui::inset(surface, 12, 10)->add_child(content);
        content->add_theme_constant_override("separation", ui::pixels(this, 8));
        auto *head = memnew(HBoxContainer);
        content->add_child(head);
        document = ui::label(head, "Weapon Animation", ui::LabelStyle::HEADING);
        document->set_text_overrun_behavior(TextServer::OVERRUN_TRIM_ELLIPSIS);
        document->set_h_size_flags(Control::SIZE_EXPAND_FILL);
        mode_button = ui::button(head, "Combo", "Switch between clip and combo authoring.", callable_mp(this, &WeaponAnimationWindow::switch_mode));
        ui::button(head, "Refresh Rig", "Read the AnimationPlayer from the edited scene.", callable_mp(this, &WeaponAnimationWindow::refresh_scene));
        ui::button(head, "Open", "Open a saved animation combo.", callable_mp(this, &WeaponAnimationWindow::show_dialog).bind(static_cast<int64_t>(FileAction::OPEN_COMBO)));
        ui::button(head, "Save As", "Save the current combo resource.", callable_mp(this, &WeaponAnimationWindow::show_dialog).bind(static_cast<int64_t>(FileAction::SAVE_COMBO)));
        import_button = ui::button(head, "Import Clips", "Import a selected Viewer animation pack.", callable_mp(this, &WeaponAnimationWindow::show_dialog).bind(static_cast<int64_t>(FileAction::VIEWER_PACK)));
        ui::button(head, "Choose Scene", "Choose the scene opened by Play Scene.", callable_mp(this, &WeaponAnimationWindow::show_dialog).bind(static_cast<int64_t>(FileAction::PLAY_SCENE)));
        play_scene_button = ui::button(head, "Play Scene", "Run the selected scene.", callable_mp(this, &WeaponAnimationWindow::play_scene));
        if (!play_scene_path.is_empty()) play_scene_button->set_tooltip_text(play_scene_path);

        auto *viewport_holder = memnew(SubViewportContainer);
        viewport_holder->set_stretch(true);
        viewport_holder->set_h_size_flags(Control::SIZE_EXPAND_FILL);
        viewport_holder->set_v_size_flags(Control::SIZE_EXPAND_FILL);
        preview_viewport = memnew(SubViewport);
        preview_viewport->set_name("AnimationPreviewViewport");
        preview_viewport->set_use_own_world_3d(true);
        preview_viewport->set_update_mode(SubViewport::UPDATE_WHEN_VISIBLE);
        viewport_holder->add_child(preview_viewport);
        preview.attach(preview_viewport);
        crosshair = memnew(WeaponAnimationCrosshair);
        crosshair->set_name("AnimationPreviewCrosshair");
        crosshair->set_mouse_filter(Control::MOUSE_FILTER_IGNORE);
        crosshair->set_z_index(2);
        viewport_holder->add_child(crosshair);
        crosshair->set_anchors_and_offsets_preset(Control::PRESET_FULL_RECT);
        preview.attach_overlay(viewport_holder);
        preview.set_edit_callbacks([this](const NodePath &path) { select_pose_path(path); },
                [this](const Transform3D &pose) { gizmo_committed(pose); });
        auto *framing = memnew(AspectRatioContainer);
        framing->set_ratio(fp_preview_ratio);
        framing->set_custom_minimum_size(Vector2(320, 180));
        framing->set_h_size_flags(Control::SIZE_EXPAND_FILL);
        framing->set_v_size_flags(Control::SIZE_EXPAND_FILL);
        framing->add_child(viewport_holder);
        auto *preview_column = memnew(VBoxContainer);
        preview_column->set_v_size_flags(Control::SIZE_EXPAND_FILL);
        build_clip_view_tools(preview_column);
        preview_column->add_child(framing);
        clip_sidebar = build_clip_sidebar();

        auto *editor = memnew(VBoxContainer);
        editor->set_h_size_flags(Control::SIZE_EXPAND_FILL);
        editor->set_v_size_flags(Control::SIZE_EXPAND_FILL);
        editor->add_theme_constant_override("separation", ui::pixels(this, 6));
        auto *toolbar = memnew(HBoxContainer);
        editor->add_child(toolbar);
        play_button = ui::button(toolbar, "Play", "Play or pause the private preview.", callable_mp(this, &WeaponAnimationWindow::toggle_playing), ui::ButtonStyle::PRIMARY, KEY_SPACE);
        join_button = ui::button(toolbar, "Loop Join", "Repeat the selected transition.", callable_mp(this, &WeaponAnimationWindow::loop_join));
        sequence_button = ui::button(toolbar, "Sequence View", "Return to the full sequence timeline.", callable_mp(this, &WeaponAnimationWindow::show_sequence));
        loop_button = memnew(CheckButton);
        toolbar->add_child(loop_button);
        loop_button->connect("toggled", callable_mp(this, &WeaponAnimationWindow::set_loop));
        playback_option = memnew(OptionButton);
        playback_option->add_item("Loop Clip");
        playback_option->add_item("Loop Region");
        playback_option->add_item("Play Once");
        playback_option->set_accessibility_name("Clip playback mode");
        toolbar->add_child(playback_option);
        playback_option->connect("item_selected", callable_mp(this, &WeaponAnimationWindow::change_clip_playback));
        time_label = ui::label(toolbar, "", ui::LabelStyle::MUTED);
        time_label->set_custom_minimum_size(Vector2(ui::pixels(this, 110), 0));
        clip_options = memnew(OptionButton);
        clip_options->set_name("AnimationClipChoice");
        clip_options->set_fit_to_longest_item(false);
        clip_options->set_h_size_flags(Control::SIZE_EXPAND_FILL);
        clip_options->set_accessibility_name("Animations in the selected player");
        toolbar->add_child(clip_options);
        clip_options->connect("item_selected", callable_mp(this, &WeaponAnimationWindow::select_source));
        add_button = ui::button(toolbar, "Add Clip", "Append the selected source to this combo.", callable_mp(this, &WeaponAnimationWindow::add_clip));
        earlier_button = ui::button(toolbar, "<", "Move the selected clip earlier.", callable_mp(this, &WeaponAnimationWindow::shift_clip).bind(-1));
        later_button = ui::button(toolbar, ">", "Move the selected clip later.", callable_mp(this, &WeaponAnimationWindow::shift_clip).bind(1));
        remove_button = ui::button(toolbar, "Remove", "Remove the selected clip from the combo.", callable_mp(this, &WeaponAnimationWindow::remove_clip));
        ui::button(toolbar, "-", "Zoom the timeline out.", callable_mp(this, &WeaponAnimationWindow::zoom).bind(1.54));
        ui::button(toolbar, "+", "Zoom the timeline in.", callable_mp(this, &WeaponAnimationWindow::zoom).bind(0.65));
        ui::button(toolbar, "Fit", "Show the full preview duration.", callable_mp(this, &WeaponAnimationWindow::fit_timeline));
        region_row = memnew(HBoxContainer);
        editor->add_child(region_row);
        ui::button(region_row, "Set In", "Set the start of the region to the playhead.", callable_mp(this, &WeaponAnimationWindow::mark_region).bind(false));
        region_first = field_number(region_row, "Loop In", 0, 60, 0.001, " s",
                callable_mp(this, &WeaponAnimationWindow::set_region_time).bind(false));
        ui::button(region_row, "Set Out", "Set the end of the region to the playhead.", callable_mp(this, &WeaponAnimationWindow::mark_region).bind(true));
        region_last = field_number(region_row, "Loop Out", 0, 60, 0.001, " s",
                callable_mp(this, &WeaponAnimationWindow::set_region_time).bind(true));

        timeline = memnew(WeaponAnimationTimeline);
        timeline->set_name("AnimationTimeline");
        editor->add_child(timeline);
        timeline->bind(&preview, callable_mp(this, &WeaponAnimationWindow::seek_preview),
                callable_mp(this, &WeaponAnimationWindow::select_join), callable_mp(this, &WeaponAnimationWindow::select_clip),
                callable_mp(this, &WeaponAnimationWindow::reorder_clip), callable_mp(this, &WeaponAnimationWindow::toggle_playing),
                callable_mp(this, &WeaponAnimationWindow::track_view_changed));
        track_editor = memnew(CrimsonAnimationTrackEditor);
        track_editor->set_name("AnimationTrackAuthoring");
        track_editor->set_v_size_flags(Control::SIZE_EXPAND_FILL);
        editor->add_child(track_editor);
        track_editor->build(callable_mp(this, &WeaponAnimationWindow::track_changed), callable_mp(this, &WeaponAnimationWindow::seek_preview));

        join_inspector = memnew(HBoxContainer);
        editor->add_child(join_inspector);
        for (int index = 0; index < 2; ++index) {
            auto *column = memnew(VBoxContainer);
            column->set_h_size_flags(Control::SIZE_EXPAND_FILL);
            join_inspector->add_child(column);
            auto *label = ui::label(column, index == 0 ? "Exit" : "Entry", ui::LabelStyle::HEADING);
            label->set_text_overrun_behavior(TextServer::OVERRUN_TRIM_ELLIPSIS);
            auto *row = memnew(HBoxContainer);
            column->add_child(row);
            auto *option = memnew(OptionButton);
            option->set_fit_to_longest_item(false);
            option->set_h_size_flags(Control::SIZE_EXPAND_FILL);
            option->set_accessibility_name(index == 0 ? "Outgoing clip exit marker" : "Incoming clip entry marker");
            row->add_child(option);
            option->connect("item_selected", callable_mp(this, &WeaponAnimationWindow::endpoint_selected));
            auto *seconds = number(row, index == 0 ? "Outgoing clip exit time" : "Incoming clip entry time");
            if (index == 0) {
                exit_label = label;
                exit_marker = option;
                exit_time = seconds;
            } else {
                entry_label = label;
                entry_marker = option;
                entry_time = seconds;
            }
        }
        auto *blend_column = memnew(VBoxContainer);
        join_inspector->add_child(blend_column);
        ui::label(blend_column, "Blend duration", ui::LabelStyle::HEADING);
        auto *blend_row = memnew(HBoxContainer);
        blend_column->add_child(blend_row);
        blend_time = number(blend_row, "Duration of the transition blend");
        status = ui::label(editor, "", ui::LabelStyle::MUTED);
        status->set_autowrap_mode(TextServer::AUTOWRAP_WORD_SMART);
        auto *top = memnew(HBoxContainer);
        top->set_v_size_flags(Control::SIZE_EXPAND_FILL);
        top->set_stretch_ratio(2.65);
        auto *work_area = ui::split_pane(top, clip_sidebar, preview_column);
        work_area->set_h_size_flags(Control::SIZE_EXPAND_FILL);
        auto *split = ui::split_pane_vertical(content, top, editor);
        split->set_v_size_flags(Control::SIZE_EXPAND_FILL);

        file_dialog = memnew(EditorFileDialog);
        add_child(file_dialog);
        file_dialog->set_theme(get_theme());
        file_dialog->set_access(EditorFileDialog::ACCESS_RESOURCES);
        file_dialog->add_filter("*.tres, *.res", "Godot resources");
        file_dialog->connect("file_selected", callable_mp(this, &WeaponAnimationWindow::file_selected));
        build_authoring_dialogs();
        refresh_tools(true);
    }
    /// Open against the current edited scene and restore the last in-memory draft.
    void open() {
        if (!reference_ready) {
            build_reference_stage(preview_viewport);
            reference_ready = true;
        }
        popup_centered_clamped(get_size(), 0.9f);
        refresh_scene();
    }
    /// Expose the unsaved combo draft to the editor's quit flow.
    String unsaved_status() const {
        if (dirty) return "Weapon Animation has an unsaved combo draft.";
        return clip_is_dirty() ? String("Weapon Animation has an unsaved clip draft.") : String();
    }
};

/// Install the editor tool without changing the game's runtime project plugins.
class WeaponAnimationEditorPlugin final : public EditorPlugin {
    GDCLASS(WeaponAnimationEditorPlugin, EditorPlugin)

    /// Child window owned by this editor plugin's lifetime.
    WeaponAnimationWindow *tool = nullptr;

    /// Open the native animation workspace from Project > Tools.
    void open_tool() {
        if (!tool) {
            tool = memnew(WeaponAnimationWindow);
            tool->hide();
            add_child(tool);
            tool->build(this);
        }
        tool->open();
    }

protected:
    /// The tool entry point is editor-only.
    static void _bind_methods() {}

    /// Tie tool registration and cleanup to the editor's own lifetime.
    void _notification(int what) {
        if (what == NOTIFICATION_ENTER_TREE) {
            add_tool_menu_item(tool_name, callable_mp(this, &WeaponAnimationEditorPlugin::open_tool));
        } else if (what == NOTIFICATION_EXIT_TREE) {
            remove_tool_menu_item(tool_name);
            tool = nullptr;
        }
    }

public:
    /// Keep a pending native combo draft visible in the quit dialog.
    String _get_unsaved_status(const String &scene_path) const override {
        return scene_path.is_empty() && tool ? tool->unsaved_status() : String();
    }
};

}

void register_weapon_animation_editor(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_EDITOR) return;
    GDREGISTER_INTERNAL_CLASS(WeaponAnimationCrosshair);
    register_animation_preview_overlay_type();
    register_animation_track_editor_types();
    GDREGISTER_INTERNAL_CLASS(WeaponAnimationTimeline);
    GDREGISTER_INTERNAL_CLASS(WeaponAnimationWindow);
    GDREGISTER_INTERNAL_CLASS(WeaponAnimationEditorPlugin);
    EditorPlugins::add_by_type<WeaponAnimationEditorPlugin>();
}

void unregister_weapon_animation_editor(ModuleInitializationLevel level) {
    if (level == MODULE_INITIALIZATION_LEVEL_EDITOR) EditorPlugins::remove_by_type<WeaponAnimationEditorPlugin>();
}

}

#else

namespace crimson::weapon_animation {

void register_weapon_animation_editor(godot::ModuleInitializationLevel) {}
void unregister_weapon_animation_editor(godot::ModuleInitializationLevel) {}

}

#endif
