// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "animation_track_editor.hpp"

#ifdef DEBUG_ENABLED

#include "editor/ui/editor_controls.hpp"

#include <godot_cpp/classes/button.hpp>
#include <godot_cpp/classes/check_box.hpp>
#include <godot_cpp/classes/color_picker_button.hpp>
#include <godot_cpp/classes/confirmation_dialog.hpp>
#include <godot_cpp/classes/editor_file_system.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/font.hpp>
#include <godot_cpp/classes/h_box_container.hpp>
#include <godot_cpp/classes/input_event_key.hpp>
#include <godot_cpp/classes/input_event_mouse_button.hpp>
#include <godot_cpp/classes/input_event_mouse_motion.hpp>
#include <godot_cpp/classes/label.hpp>
#include <godot_cpp/classes/line_edit.hpp>
#include <godot_cpp/classes/option_button.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/resource_saver.hpp>
#include <godot_cpp/classes/scroll_container.hpp>
#include <godot_cpp/classes/spin_box.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

namespace crimson::weapon_animation {
namespace {

using namespace godot;
namespace ui = crimson::editor_ui;

/// Saved float curve modes, shared by the native and legacy runtime readers.
enum CurveMode { CONSTANT, LINEAR, AUTO, BREAK, LEGACY };
/// Thickness of the lane separator, after applying editor scale.
constexpr double separator_size = 1.0;
/// Draw the same axis gutter as the enclosing playback ruler.
constexpr double time_gutter = 76;
/// Distance across which dragging is recognized, in pixels before scaling.
constexpr double drag_threshold = 4;
/// Smallest nonzero time difference permitted inside one notify state, in seconds.
constexpr double min_state_length = 0.000001;
/// Generic native catalog path. Projects can point to a different saved Resource.
constexpr char preset_path_setting[] = "crimson/weapon_animation/curve_presets";
/// Native preset metadata key on the catalog's plain Resource.
constexpr char preset_metadata[] = "crimson_weapon_curve_presets";
/// Existing scripted catalog from earlier Tweaker versions, used as a read-only source.
constexpr char legacy_preset_path[] = "res://data/animation/weapon_curve_presets.tres";

/// Check an index that may represent an absent selection.
bool has_index(const Array &rows, int64_t index) {
    return index >= 0 && index < rows.size();
}

/// Read an addressed row without querying outside the collection.
Dictionary row_at(const Array &rows, int64_t index) {
    return has_index(rows, index) ? Dictionary(rows[index]) : Dictionary();
}

/// Read a nested array without converting an absent value into a typed collection.
Array row_array(const Dictionary &row, const StringName &key) {
    const Variant value = row.get(key, Array());
    return value.get_type() == Variant::ARRAY ? Array(value) : Array();
}

/// Generate a unique label without changing any existing authored row.
String unique_name(const Array &rows, const String &base) {
    String name = base;
    for (int suffix = 2;; ++suffix) {
        bool available = true;
        for (const Variant &row : rows) {
            if (String(Dictionary(row).get("name", String())) == name) {
                available = false;
                break;
            }
        }
        if (available) {
            return name;
        }
        name = vformat("%s %d", base, suffix);
    }
}

/// Read the current project's chosen native preset catalog path.
String native_preset_path() {
    ProjectSettings *settings = ProjectSettings::get_singleton();
    const String fallback = "res://weapon_curve_presets_native.tres";
    return settings->get_setting(preset_path_setting, fallback);
}

/// Open a catalog when present, ignoring stale ResourceLoader cache entries.
TypedArray<Dictionary> read_presets(const String &path, bool legacy) {
    TypedArray<Dictionary> rows;
    if (path.is_empty() || !ResourceLoader::get_singleton()->exists(path)) return rows;
    const Ref<Resource> catalog = ResourceLoader::get_singleton()->load(path, "", ResourceLoader::CACHE_MODE_IGNORE);
    if (catalog.is_null()) return rows;
    const Variant stored = legacy ? catalog->get("presets") : catalog->get_meta(preset_metadata, Array());
    if (stored.get_type() != Variant::ARRAY) return rows;
    for (const Variant &entry : Array(stored)) {
        if (entry.get_type() == Variant::DICTIONARY && !String(Dictionary(entry).get("name", String())).strip_edges().is_empty()) {
            rows.push_back(entry);
        }
    }
    return rows;
}

/// Return the index of a preset or lane with this exact name.
int64_t find_named_row(const Array &rows, const String &name) {
    for (int64_t index = 0; index < rows.size(); ++index) {
        if (String(Dictionary(rows[index]).get("name", String())) == name) return index;
    }
    return -1;
}

/// Upgrade a saved curve preset to detached native key rows.
Dictionary normalize_preset(const Dictionary &row) {
    Ref<Animation> clip;
    clip.instantiate();
    clip->set_length(1.0);
    Ref<CrimsonWeaponAnimationTracks> tracks;
    tracks.instantiate();
    TypedArray<Dictionary> curve_rows;
    curve_rows.push_back(row);
    tracks->set_curve_tracks(curve_rows);
    clip->set_meta("weapon_tweaker_tracks", tracks);
    const Ref<CrimsonWeaponAnimationTracks> converted = CrimsonWeaponAnimationTracks::from_animation(clip);
    return converted.is_valid() ? row_at(converted->get_curve_tracks(), 0) : Dictionary();
}

/// Make a new independent normalized curve key.
Dictionary make_key(double phase, double value) {
    Dictionary key;
    key["phase"] = phase;
    key["value"] = value;
    key["mode"] = LINEAR;
    key["in_slope"] = 0.0;
    key["out_slope"] = 0.0;
    key["in_weight"] = 0.0;
    key["out_weight"] = 0.0;
    key["weighted_in"] = false;
    key["weighted_out"] = false;
    return key;
}

/// Insert at a distinct phase while keeping the rows in time order.
int64_t insert_key(Array &keys, const Dictionary &key) {
    const double phase = key["phase"];
    for (int64_t index = 0; index < keys.size(); ++index) {
        const double other = Dictionary(keys[index])["phase"];
        if (phase == other) {
            return -1;
        }
        if (phase < other) {
            keys.insert(index, key);
            return index;
        }
    }
    keys.push_back(key);
    return keys.size() - 1;
}

/// Return the signed time coordinate of one cubic tangent handle.
double handle_delta(const Array &keys, int64_t index, bool incoming) {
    const Dictionary key = keys[index];
    const int64_t other = index + (incoming ? -1 : 1);
    if (!has_index(keys, other)) {
        return 0;
    }
    if (bool(key[incoming ? "weighted_in" : "weighted_out"])) {
        const double weight = key[incoming ? "in_weight" : "out_weight"];
        const double slope = key[incoming ? "in_slope" : "out_slope"];
        return (incoming ? -weight : weight) / std::hypot(1.0, slope);
    }
    return (double(Dictionary(keys[other])["phase"]) - double(key["phase"])) / 3.0;
}

/// Return whether the addressed side belongs to a cubic segment.
bool has_tangent(const Array &keys, int64_t index, bool incoming) {
    const int64_t other = index + (incoming ? -1 : 1);
    return has_index(keys, index) && has_index(keys, other) && int64_t(Dictionary(keys[index])["mode"]) >= AUTO &&
           (!incoming || int64_t(Dictionary(keys[other])["mode"]) >= AUTO);
}

/// Set a key mode while retaining the shape of a newly broken tangent.
void change_key_mode(Dictionary &key, const Dictionary &effective, int64_t mode) {
    const int64_t old_mode = key["mode"];
    if (mode == old_mode) {
        return;
    }
    if (mode == BREAK) {
        key["in_slope"] = effective["in_slope"];
        key["out_slope"] = effective["out_slope"];
    }
    key["mode"] = mode;
    key.erase("in_linear");
    key.erase("out_linear");
    if (mode < AUTO) {
        key["weighted_in"] = false;
        key["weighted_out"] = false;
    }
}

/// Attach a stock select to the options row, using the workbench inherited theme.
OptionButton *option(HBoxContainer *owner, const String &name, const PackedStringArray &values, const Callable &selected) {
    auto *result = memnew(OptionButton);
    result->set_name(name);
    result->set_clip_text(true);
    for (const String &value : values) {
        result->add_item(value);
    }
    owner->add_child(result);
    result->connect("item_selected", selected);
    return result;
}

/// Create the labeled input cell used for exact edits.
SpinBox *number(HBoxContainer *owner, const String &name, const String &suffix, double minimum, double maximum,
        const Callable &changed) {
    auto *cell = memnew(HBoxContainer);
    owner->add_child(cell);
    ui::label(cell, name, ui::LabelStyle::MUTED);
    auto *result = memnew(SpinBox);
    result->set_name(name);
    result->set_suffix(suffix);
    result->set_min(minimum);
    result->set_max(maximum);
    result->set_step(0.001);
    result->set_custom_minimum_size(Vector2(ui::pixels(owner, 86), 0));
    cell->add_child(result);
    result->connect("value_changed", changed);
    return result;
}

/// Keep a field's fixed caption and entry visibility synchronized.
void show_number(SpinBox *field, bool visible) {
    Object::cast_to<HBoxContainer>(field->get_parent())->set_visible(visible);
}

} // namespace

/// Paints clip-owned rows and converts pointer gestures into whole-draft operations.
class AnimationTrackCanvas final : public Control {
    GDCLASS(AnimationTrackCanvas, Control)

    using Hit = CrimsonAnimationTrackEditor::Hit;
    using Kind = CrimsonAnimationTrackEditor::Kind;

    /// One visible lane and its y coordinates in the canvas.
    struct Lane {
        Hit hit; ///< Row identity without an item.
        double top = 0; ///< Lane position in canvas pixels.
        double height = 0; ///< Lane height in canvas pixels.
    };

    /// Editor owning the draft and protected row selection.
    CrimsonAnimationTrackEditor *editor = nullptr;
    /// Hit recorded at left pointer press.
    Hit pressed;
    /// Initial position of the active gesture.
    Vector2 begin;
    /// Most recent position of the active gesture.
    Vector2 cursor;
    /// Whether a primary drag is in progress.
    bool active = false;
    /// Whether the press started an empty-area curve selection.
    bool boxing = false;
    /// Whether Ctrl requested a multi-selection toggle.
    bool toggle = false;

    /// Width of the time-axis header shared with the enclosing ruler.
    double gutter() const { return ui::pixels(const_cast<AnimationTrackCanvas *>(this), time_gutter); }
    /// Height of one compact lane.
    double row_height() const { return ui::pixels(const_cast<AnimationTrackCanvas *>(this), 27); }
    /// Height of the expanded active curve lane.
    double curve_height() const {
        const auto *scroll = Object::cast_to<ScrollContainer>(get_parent());
        const double available = scroll ? scroll->get_size().y : 0.0;
        const double lanes_height = (editor->notify_lanes.size() + editor->curve_lanes.size()) * row_height();
        return std::max(static_cast<double>(ui::pixels(const_cast<AnimationTrackCanvas *>(this), 126)), available - lanes_height);
    }
    /// Minimum x range for a fully collapsed editor.
    double plot_width() const {
        return std::max(1.0, static_cast<double>(editor->get_size().x) - gutter() - 8.0);
    }
    /// Map shared clip seconds to an x coordinate.
    double x_at(double seconds) const {
        return gutter() + (seconds - editor->visible_start) * plot_width() / editor->visible_duration;
    }
    /// Read a time from the same axis as the enclosing ruler.
    double time_at(double x) const {
        return std::clamp(editor->visible_start + (x - gutter()) * editor->visible_duration / plot_width(), 0.0, editor->duration);
    }
    /// Map a float value into an expanded curve row.
    double y_at(double value, const Lane &row) const {
        return row.top + row.height - 6 - (value - editor->low_value) * (row.height - 12) / (editor->high_value - editor->low_value);
    }
    /// Return visible lanes in authored order.
    std::vector<Lane> lanes() const {
        std::vector<Lane> result{{Hit{Kind::MARKER, 0}, 0.0, row_height()}};
        double offset = row_height();
        for (int64_t index = 0; index < editor->notify_lanes.size(); ++index) {
            result.push_back({Hit{Kind::NOTIFY, index}, offset, row_height()});
            offset += row_height();
        }
        for (int64_t index = 0; index < editor->curve_lanes.size(); ++index) {
            const bool expanded = editor->curve_expanded && editor->selected.kind == Kind::CURVE && editor->selected.lane == index;
            const double height = expanded ? curve_height() : row_height();
            result.push_back({Hit{Kind::CURVE, index}, offset, height});
            offset += height;
        }
        return result;
    }
    /// Whether time data and a valid window are available.
    bool has_time() const { return editor && editor->duration > 0 && editor->visible_duration > 0; }
    /// Return the item rows for a noncurve lane.
    Array lane_items(const Lane &lane) const {
        return lane.hit.kind == Kind::MARKER ? Array(editor->marker_rows) :
                row_array(Dictionary(editor->notify_lanes[lane.hit.lane]), "notifies");
    }
    /// Read a label for a lane header.
    String lane_name(const Lane &lane) const {
        if (lane.hit.kind == Kind::MARKER) {
            return "Markers";
        }
        const auto &rows = lane.hit.kind == Kind::CURVE ? editor->curve_lanes : editor->notify_lanes;
        return Dictionary(rows[lane.hit.lane])["name"];
    }
    /// Draw a clipped string with the workbench's typography.
    void caption(const String &name, const Rect2 &box, ui::Surface ink = ui::Surface::TEXT) {
        const Ref<Font> font = get_theme_default_font();
        const int font_size = get_theme_default_font_size();
        if (font.is_null() || box.size.x < 15) {
            return;
        }
        const double baseline = box.position.y + (box.size.y - font->get_height(font_size)) * 0.5 + font->get_ascent(font_size);
        draw_string(font, Vector2(box.position.x + 5, baseline), name, HORIZONTAL_ALIGNMENT_LEFT, box.size.x - 9, font_size, ui::color(ink));
    }
    /// Draw an individual marker or one-shot notify as a selectable diamond.
    void diamond(const Vector2 &point, double radius, const Color &fill) {
        PackedVector2Array points;
        points.push_back(point + Vector2(0, -radius));
        points.push_back(point + Vector2(radius, 0));
        points.push_back(point + Vector2(0, radius));
        points.push_back(point + Vector2(-radius, 0));
        draw_colored_polygon(points, fill);
    }
    /// Return the visual span of a marker, one-shot or state.
    Rect2 item_rect(const Lane &lane, const Dictionary &row) const {
        const double start = row["time"];
        const double end = row.get("end_time", -1.0);
        if (start > editor->visible_start + editor->visible_duration ||
                std::max(start, end) < editor->visible_start) {
            return {};
        }
        const double first = std::max(gutter(), x_at(start));
        if (end < 0) {
            return Rect2(std::max(gutter(), first - 5), lane.top + 3, 11, lane.height - 6);
        }
        const double last = std::min(gutter() + plot_width(), x_at(end));
        return Rect2(first, lane.top + 3, std::max(2.0, last - first), lane.height - 6);
    }
    /// Draw the marker or notify items on this lane in their authored color.
    void paint_events(const Lane &lane) {
        const Array entries = lane_items(lane);
        for (int64_t index = 0; index < entries.size(); ++index) {
            const Dictionary item = entries[index];
            const Rect2 area = item_rect(lane, item);
            if (!area.has_area()) {
                continue;
            }
            const bool selected = lane.hit.kind == editor->selected.kind && lane.hit.lane == editor->selected.lane &&
                    index == editor->selected.item;
            const Color fill = editor->row_color(item, lane.hit.kind);
            const Color outline = selected ? ui::color(ui::Surface::HIGHLIGHT) : fill;
            if (double(item.get("end_time", -1.0)) < 0) {
                diamond(area.get_center(), 6, outline);
                caption(item["name"], {area.get_end().x, area.position.y, get_size().x - area.get_end().x, area.size.y});
                continue;
            }
            draw_rect(area, fill.darkened(0.57));
            draw_rect(area, outline, false, separator_size);
            caption(item["name"], area);
        }
    }
    /// Return a curve key's screen position.
    Vector2 key_point(const Dictionary &key, const Lane &lane) const {
        return Vector2(x_at(double(key["phase"]) * editor->duration), y_at(key["value"], lane));
    }
    /// Return a tangent handle's screen position.
    Vector2 handle_point(const Array &keys, int64_t index, bool incoming, const Lane &lane) const {
        const Dictionary key = keys[index];
        const double dt = handle_delta(keys, index, incoming);
        const double slope = key[incoming ? "in_slope" : "out_slope"];
        return Vector2(x_at((double(key["phase"]) + dt) * editor->duration), y_at(double(key["value"]) + dt * slope, lane));
    }
    /// Draw a curve and expanded keys and tangent controls for the active lane.
    void paint_curve(const Lane &lane) {
        const Dictionary row = editor->curve_lanes[lane.hit.lane];
        const StringName name = row["name"];
        const Color fill = editor->row_color(row, Kind::CURVE);
        const bool expanded = editor->curve_expanded && lane.hit.lane == editor->selected.lane && editor->selected.kind == Kind::CURVE;
        draw_rect(Rect2(gutter(), lane.top, plot_width(), lane.height), Color(fill.r, fill.g, fill.b, 0.11));
        if (editor->evaluator.is_null()) {
            return;
        }
        const Array keys = editor->evaluator->get_curve_keys(name);
        if (keys.is_empty()) {
            return;
        }
        double compact_low = double(Dictionary(keys[0])["value"]);
        double compact_high = compact_low;
        for (const Variant &entry : keys) {
            const double value = Dictionary(entry)["value"];
            compact_low = std::min(compact_low, value);
            compact_high = std::max(compact_high, value);
        }
        Vector2 previous;
        const int samples = std::clamp(static_cast<int>(plot_width() / 6), 24, 180);
        for (int index = 0; index <= samples; ++index) {
            const double seconds = editor->visible_start + editor->visible_duration * index / samples;
            const double value = editor->evaluator->sample_curve(name, seconds);
            const double compact_y = lane.top + lane.height - 4 -
                    (value - compact_low) * (lane.height - 8) / std::max(0.000001, compact_high - compact_low);
            const Vector2 current(x_at(seconds), std::clamp(expanded ? y_at(value, lane) : compact_y, lane.top, lane.top + lane.height));
            if (index > 0) {
                draw_line(previous, current, fill, 1.35, true);
            }
            previous = current;
        }
        if (!expanded) {
            return;
        }
        for (int64_t index = 0; index < keys.size(); ++index) {
            const Dictionary key = keys[index];
            const Vector2 point = key_point(key, lane);
            if (point.x < gutter() || point.x > get_size().x || point.y < lane.top || point.y > lane.top + lane.height) {
                continue;
            }
            const bool picked = std::find(editor->keys_selected.begin(), editor->keys_selected.end(), index) != editor->keys_selected.end();
            const Color ink = picked ? ui::color(ui::Surface::HIGHLIGHT) : fill;
            if (int64_t(key["mode"]) == CONSTANT) {
                draw_rect({point - Vector2(4, 4), Size2(8, 8)}, ink);
            } else if (int64_t(key["mode"]) >= AUTO) {
                draw_circle(point, 4, ink);
            } else {
                diamond(point, 5, ink);
            }
            if (index != editor->selected.item) {
                continue;
            }
            for (const bool incoming : {true, false}) {
                if (!has_tangent(keys, index, incoming)) {
                    continue;
                }
                const Vector2 endpoint = handle_point(keys, index, incoming, lane);
                if (endpoint.x < gutter() || endpoint.x > get_size().x || endpoint.y < lane.top || endpoint.y > lane.top + lane.height) {
                    continue;
                }
                draw_line(point, endpoint, ink, 1, true);
                draw_circle(endpoint, 4, ink);
            }
        }
    }
    /// Resolve a visible pointer hit, prioritizing active tangent handles over keys.
    Hit hit_at(const Vector2 &point) const {
        for (const Lane &lane : lanes()) {
            if (point.y < lane.top || point.y >= lane.top + lane.height) {
                continue;
            }
            Hit hit = lane.hit;
            if (point.x < gutter()) {
                return hit;
            }
            if (hit.kind == Kind::CURVE) {
                if (!editor->curve_expanded || hit.lane != editor->selected.lane || editor->selected.kind != Kind::CURVE) {
                    return hit;
                }
                const Array keys = editor->effective_curve_keys();
                const int64_t selected = editor->selected.item;
                for (const bool incoming : {true, false}) {
                    if (has_tangent(keys, selected, incoming) && handle_point(keys, selected, incoming, lane).distance_to(point) < 7) {
                        hit.item = selected;
                        hit.handle = incoming ? -1 : 1;
                        return hit;
                    }
                }
                for (int64_t index = keys.size(); index-- > 0;) {
                    if (key_point(keys[index], lane).distance_to(point) < 7) {
                        hit.item = index;
                        return hit;
                    }
                }
                return hit;
            }
            const Array items = lane_items(lane);
            for (int64_t index = items.size(); index-- > 0;) {
                const Dictionary row = items[index];
                const Rect2 box = item_rect(lane, row);
                if (!box.has_point(point)) {
                    continue;
                }
                hit.item = index;
                if (double(row.get("end_time", -1.0)) >= 0 && box.size.x > 10) {
                    if (std::abs(point.x - box.position.x) <= 4) {
                        hit.handle = -1;
                    } else if (std::abs(point.x - box.get_end().x) <= 4) {
                        hit.handle = 1;
                    }
                }
                return hit;
            }
            return hit;
        }
        return {};
    }

protected:
    /// Canvas commands are routed to its owner from native input.
    static void _bind_methods() {}

    /// Draw the ordered lanes and an aligned playhead.
    void _notification(int what) {
        if (what != NOTIFICATION_DRAW || !editor) {
            return;
        }
        draw_rect({Vector2(), get_size()}, ui::color(ui::Surface::SIDEBAR));
        if (!has_time()) {
            caption("Select an animation clip to edit its tracks.", Rect2(0, 0, get_size().x, row_height()), ui::Surface::MUTED);
            return;
        }
        for (const Lane &lane : lanes()) {
            const bool selected = lane.hit.kind == editor->selected.kind && lane.hit.lane == editor->selected.lane;
            draw_rect(Rect2(0, lane.top, gutter(), lane.height), ui::color(selected ? ui::Surface::SELECTED : ui::Surface::RAISED));
            caption(lane_name(lane), Rect2(0, lane.top, gutter(), row_height()));
            if (lane.hit.kind == Kind::CURVE) {
                paint_curve(lane);
            } else {
                paint_events(lane);
            }
            const double y = lane.top + lane.height - 0.5;
            draw_line(Vector2(0, y), Vector2(get_size().x, y), ui::color(ui::Surface::RULE));
        }
        if (editor->playhead >= editor->visible_start && editor->playhead <= editor->visible_start + editor->visible_duration) {
            const double x = x_at(editor->playhead);
            draw_line(Vector2(x, 0), Vector2(x, get_size().y), ui::color(ui::Surface::ACCENT));
        }
        if (active && cursor.distance_to(begin) >= drag_threshold) {
            if (boxing) {
                const Rect2 box = Rect2(begin, cursor - begin).abs();
                const Color accent = ui::color(ui::Surface::ACCENT);
                draw_rect(box, Color(accent.r, accent.g, accent.b, 0.2));
                draw_rect(box, accent, false);
            } else if (pressed.item >= 0) {
                const double x = std::clamp(static_cast<double>(cursor.x), gutter(), gutter() + plot_width());
                draw_line(Vector2(x, 0), Vector2(x, get_size().y), ui::color(ui::Surface::HIGHLIGHT));
            }
        }
    }

public:
    /// Accept shared timeline actions and transactional drag gestures.
    void _gui_input(const Ref<InputEvent> &event) override {
        if (!has_time()) {
            return;
        }
        const Ref<InputEventKey> key = event;
        if (key.is_valid() && key->is_pressed() && !key->is_echo() && key->get_keycode() == KEY_DELETE) {
            editor->delete_selection();
            accept_event();
            return;
        }
        const Ref<InputEventMouseMotion> motion = event;
        if (motion.is_valid()) {
            cursor = motion->get_position();
            const Hit hover = hit_at(cursor);
            set_default_cursor_shape(hover.handle ? CURSOR_HSIZE : hover.item >= 0 ? CURSOR_POINTING_HAND : CURSOR_ARROW);
            if (active) {
                queue_redraw();
                accept_event();
            }
            return;
        }
        const Ref<InputEventMouseButton> button = event;
        if (button.is_null() || button->get_button_index() != MOUSE_BUTTON_LEFT) {
            return;
        }
        const Vector2 position = button->get_position();
        if (button->is_pressed()) {
            grab_focus();
            pressed = hit_at(position);
            begin = cursor = position;
            toggle = button->is_ctrl_pressed();
            boxing = editor->curve_expanded && pressed.kind == Kind::CURVE && editor->selected.kind == Kind::CURVE &&
                    pressed.lane == editor->selected.lane && pressed.item < 0 && position.x >= gutter();
            active = true;
            if (!boxing && pressed.item < 0) {
                editor->select(pressed);
            } else if (pressed.item >= 0 && (pressed.kind != Kind::CURVE || pressed.lane != editor->selected.lane ||
                    std::find(editor->keys_selected.begin(), editor->keys_selected.end(), pressed.item) == editor->keys_selected.end())) {
                editor->select(pressed, toggle);
                toggle = false;
            }
        } else if (active) {
            active = false;
            const Vector2 delta = position - begin;
            if (delta.length() >= drag_threshold) {
                if (boxing) {
                    editor->select_box(Rect2(begin, delta).abs());
                } else if (pressed.item >= 0) {
                    const double seconds_delta = delta.x * editor->visible_duration / plot_width();
                    const double value_delta = -delta.y * (editor->high_value - editor->low_value) / (curve_height() - 12);
                    editor->finish_drag(pressed, seconds_delta, value_delta, button->is_shift_pressed());
                }
            } else if (pressed.item >= 0) {
                editor->select(pressed, toggle);
            } else if (position.x >= gutter()) {
                editor->seek(time_at(position.x));
            }
            queue_redraw();
        }
        accept_event();
    }

    /// Attach the canvas to the native draft owner.
    void build(CrimsonAnimationTrackEditor *owner) {
        editor = owner;
        set_name("ClipTrackCanvas");
        set_focus_mode(FOCUS_ALL);
        set_clip_contents(true);
        set_h_size_flags(SIZE_EXPAND_FILL);
        set_v_size_flags(SIZE_EXPAND_FILL);
        sync_layout();
    }
    /// Recalculate the scrollable height for the active set of lanes.
    void sync_layout() {
        const auto rows = lanes();
        const Lane &last = rows.back();
        set_custom_minimum_size(Vector2(0, last.top + last.height));
        queue_redraw();
    }
    /// Collect the visible keys inside a box on the active curve.
    std::vector<int64_t> keys_in_box(const Rect2 &box) const {
        std::vector<int64_t> hits;
        for (const Lane &lane : lanes()) {
            if (lane.hit.kind != Kind::CURVE || lane.hit.lane != editor->selected.lane) {
                continue;
            }
            const Array keys = editor->effective_curve_keys();
            for (int64_t index = 0; index < keys.size(); ++index) {
                if (box.has_point(key_point(keys[index], lane))) {
                    hits.push_back(index);
                }
            }
        }
        return hits;
    }
};

void CrimsonAnimationTrackEditor::build(const Callable &on_changed, const Callable &on_seek) {
    changed = on_changed;
    seek_requested = on_seek;
    set_name("ClipTracks");
    set_v_size_flags(SIZE_EXPAND_FILL);
    auto *commands = memnew(HBoxContainer);
    add_child(commands);
    marker_button = ui::button(commands, "Add Marker", "Add a marker at the current preview time.",
            callable_mp(this, &CrimsonAnimationTrackEditor::add_marker_at_playhead));
    marker_button->set_name("AddMarker");
    notify_button = ui::button(commands, "Add Notify Lane", "Create a lane for notifications.",
            callable_mp(this, &CrimsonAnimationTrackEditor::add_lane).bind(static_cast<int>(Kind::NOTIFY)));
    notify_button->set_name("AddNotifyLane");
    curve_button = ui::button(commands, "Add Curve", "Create an editable float curve.",
            callable_mp(this, &CrimsonAnimationTrackEditor::add_lane).bind(static_cast<int>(Kind::CURVE)));
    curve_button->set_name("AddCurve");
    item_button = ui::button(commands, "Add Key", "Insert a key or one-shot event at the playhead.",
            callable_mp(this, &CrimsonAnimationTrackEditor::add_item).bind(0));
    item_button->set_name("AddTrackItem");
    state_button = ui::button(commands, "Add Notify State", "Add a duration event beginning at the playhead.",
            callable_mp(this, &CrimsonAnimationTrackEditor::add_item).bind(1));
    state_button->set_name("AddNotifyState");
    remove_button = ui::button(commands, "Remove", "Remove selected keys, an event, or a lane.",
            callable_mp(this, &CrimsonAnimationTrackEditor::delete_selection), ui::ButtonStyle::QUIET);
    remove_button->set_name("RemoveTrackItem");
    preset_options = option(commands, "CurvePresets", {}, callable_mp(this, &CrimsonAnimationTrackEditor::add_preset));
    preset_options->set_custom_minimum_size(Vector2(ui::pixels(this, 118), 0));
    preset_options->set_tooltip_text("Add a saved curve template with independent key data.");

    auto *scroll = memnew(ScrollContainer);
    scroll->set_name("TrackRows");
    scroll->set_horizontal_scroll_mode(ScrollContainer::SCROLL_MODE_DISABLED);
    scroll->set_custom_minimum_size(Vector2(0, ui::pixels(this, 70)));
    scroll->set_v_size_flags(SIZE_EXPAND_FILL);
    add_child(scroll);
    canvas = memnew(AnimationTrackCanvas);
    scroll->add_child(canvas);
    canvas->build(this);

    number_fields = memnew(HBoxContainer);
    add_child(number_fields);
    name_field = ui::text_input(number_fields, {}, "Name of the selected marker, event, or lane. Press Enter to commit.");
    name_field->set_name("TrackName");
    name_field->set_h_size_flags(SIZE_EXPAND_FILL);
    name_field->connect("text_submitted", callable_mp(this, &CrimsonAnimationTrackEditor::commit_name));
    color_field = memnew(ColorPickerButton);
    color_field->set_name("TrackColor");
    color_field->set_tooltip_text("Color of the selected marker, event, or curve.");
    color_field->set_custom_minimum_size(Vector2(ui::pixels(this, 29), 0));
    number_fields->add_child(color_field);
    color_field->connect("popup_closed", callable_mp(this, &CrimsonAnimationTrackEditor::commit_color));
    time_field = number(number_fields, "Time", "s", 0.0, 1.0,
            callable_mp(this, &CrimsonAnimationTrackEditor::commit_number).bind(static_cast<int>(Field::TIME)));
    end_field = number(number_fields, "End", "s", 0.0, 1.0,
            callable_mp(this, &CrimsonAnimationTrackEditor::commit_number).bind(static_cast<int>(Field::END)));
    value_field = number(number_fields, "Value", {}, -1000000, 1000000,
            callable_mp(this, &CrimsonAnimationTrackEditor::commit_number).bind(static_cast<int>(Field::VALUE)));
    kind_field = option(number_fields, "NotifyKind", {"One Shot", "State", "MeleeTrace"},
            callable_mp(this, &CrimsonAnimationTrackEditor::commit_notify_kind));

    curve_fields = memnew(HBoxContainer);
    add_child(curve_fields);
    mode_field = option(curve_fields, "CurveMode", {"Constant", "Linear", "Auto", "Broken", "Legacy"},
            callable_mp(this, &CrimsonAnimationTrackEditor::commit_mode));
    mode_field->set_item_disabled(LEGACY, true);
    weighted_field = ui::checkbox(curve_fields, "Weighted", ui::CheckState::UNCHECKED,
            callable_mp(this, &CrimsonAnimationTrackEditor::commit_weighted));
    weighted_field->set_name("WeightedTangent");
    axis_field = option(curve_fields, "DragAxis", {"Free", "Time Only", "Value Only"},
            callable_mp(this, &CrimsonAnimationTrackEditor::select_axis));
    ui::button(curve_fields, "Fit Values", "Fit the active curve vertically.",
            callable_mp(this, &CrimsonAnimationTrackEditor::fit_values), ui::ButtonStyle::QUIET);
    ui::button(curve_fields, "Blend Left", "Move selected values to their previous unselected neighbor.",
            callable_mp(this, &CrimsonAnimationTrackEditor::blend_neighbors).bind(-1.0), ui::ButtonStyle::QUIET);
    ui::button(curve_fields, "Blend Right", "Move selected values to their following unselected neighbor.",
            callable_mp(this, &CrimsonAnimationTrackEditor::blend_neighbors).bind(1.0), ui::ButtonStyle::QUIET);
    collapse_button = ui::button(curve_fields, "Collapse", "Switch the selected curve between compact and expanded.",
            callable_mp(this, &CrimsonAnimationTrackEditor::toggle_curve), ui::ButtonStyle::QUIET);
    collapse_button->set_name("ToggleCurveGraph");
    preset_save = ui::button(curve_fields, "Save Preset", "Copy the selected curve to the preset catalog.",
            callable_mp(this, &CrimsonAnimationTrackEditor::save_preset));
    preset_save->set_name("SaveCurvePreset");
    preset_confirmation = memnew(ConfirmationDialog);
    preset_confirmation->set_title("Replace Curve Preset");
    preset_confirmation->connect("confirmed", callable_mp(this, &CrimsonAnimationTrackEditor::write_preset));
    add_child(preset_confirmation);
    tangent_fields = memnew(HBoxContainer);
    tangent_fields->set_name("TangentFields");
    add_child(tangent_fields);
    in_slope_field = number(tangent_fields, "In Slope", {}, -1000000, 1000000,
            callable_mp(this, &CrimsonAnimationTrackEditor::commit_number).bind(static_cast<int>(Field::IN_SLOPE)));
    out_slope_field = number(tangent_fields, "Out Slope", {}, -1000000, 1000000,
            callable_mp(this, &CrimsonAnimationTrackEditor::commit_number).bind(static_cast<int>(Field::OUT_SLOPE)));
    in_weight_field = number(tangent_fields, "In Weight", {}, 0, 1000000,
            callable_mp(this, &CrimsonAnimationTrackEditor::commit_number).bind(static_cast<int>(Field::IN_WEIGHT)));
    out_weight_field = number(tangent_fields, "Out Weight", {}, 0, 1000000,
            callable_mp(this, &CrimsonAnimationTrackEditor::commit_number).bind(static_cast<int>(Field::OUT_WEIGHT)));
    status = ui::label(this, {}, ui::LabelStyle::MUTED);
    status->set_name("TrackStatus");
    refresh_presets();
    refresh();
}

void CrimsonAnimationTrackEditor::set_tracks(const Ref<CrimsonWeaponAnimationTracks> &tracks, double clip_duration) {
    if (draft == tracks && duration == clip_duration) {
        return;
    }
    draft = tracks;
    duration = std::isfinite(clip_duration) && clip_duration > 0 ? clip_duration : 0;
    playhead = std::min(playhead, duration);
    visible_start = 0;
    visible_duration = duration;
    selected = {};
    curve_expanded = true;
    keys_selected.clear();
    refresh();
}

Ref<CrimsonWeaponAnimationTracks> CrimsonAnimationTrackEditor::get_tracks() const {
    return draft;
}

void CrimsonAnimationTrackEditor::set_playhead(double seconds) {
    const double next = std::clamp(seconds, 0.0, duration);
    if (next != playhead) {
        playhead = next;
        if (canvas) canvas->queue_redraw();
    }
}

void CrimsonAnimationTrackEditor::set_time_view(double offset, double visible_seconds) {
    if (!std::isfinite(offset) || !std::isfinite(visible_seconds) || visible_seconds <= 0.0) {
        return;
    }
    if (visible_start != offset || visible_duration != visible_seconds) {
        visible_start = offset;
        visible_duration = visible_seconds;
        if (canvas) canvas->queue_redraw();
    }
}

bool CrimsonAnimationTrackEditor::commit(const TypedArray<Dictionary> &markers,
        const TypedArray<Dictionary> &notifies, const TypedArray<Dictionary> &curves) {
    if (markers == marker_rows && notifies == notify_lanes && curves == curve_lanes) {
        return false;
    }
    Ref<CrimsonWeaponAnimationTracks> next;
    next.instantiate();
    next->set_markers(markers);
    next->set_notify_tracks(notifies);
    next->set_curve_tracks(curves);
    if (!next->is_valid(duration)) {
        refresh_details();
        status->set_text("Choose a unique name or an unused time inside the clip.");
        status->show();
        return false;
    }
    draft = next;
    refresh();
    if (changed.is_valid()) changed.call();
    return true;
}

void CrimsonAnimationTrackEditor::refresh() {
    marker_rows = draft.is_valid() ? draft->get_markers() : TypedArray<Dictionary>();
    notify_lanes = draft.is_valid() ? draft->get_notify_tracks() : TypedArray<Dictionary>();
    curve_lanes = draft.is_valid() ? draft->get_curve_tracks() : TypedArray<Dictionary>();
    evaluator.unref();
    if (draft.is_valid() && duration > 0) {
        // Build a detached clip snapshot once per edit, never write preview metadata to the loaded scene.
        Ref<Animation> snapshot;
        snapshot.instantiate();
        snapshot->set_length(duration);
        snapshot->set_meta("weapon_tweaker_tracks", draft);
        evaluator = CrimsonWeaponAnimationClip::from_animation(snapshot);
    }
    if (!canvas) return;
    status->hide();
    refresh_details();
    canvas->sync_layout();
}

void CrimsonAnimationTrackEditor::refresh_details() {
    if (!canvas) {
        return;
    }
    updating_fields = true;
    const bool active = duration > 0;
    const Dictionary row = selected_item();
    const Dictionary lane = selected_lane();
    const bool marker = selected.kind == Kind::MARKER && !row.is_empty();
    const bool notify = selected.kind == Kind::NOTIFY && !row.is_empty();
    const bool curve = selected.kind == Kind::CURVE && !lane.is_empty();
    const bool key = curve && !row.is_empty();
    const bool state = notify && double(row.get("end_time", -1.0)) >= 0;
    const int64_t mode = key ? int64_t(row["mode"]) : LINEAR;
    const bool cubic_key = key && mode >= AUTO;
    const bool weighted = cubic_key && (bool(row["weighted_in"]) || bool(row["weighted_out"]));
    marker_button->set_disabled(!active);
    notify_button->set_disabled(!active);
    curve_button->set_disabled(!active);
    preset_options->set_disabled(!active || presets.is_empty());
    item_button->set_visible((selected.kind == Kind::NOTIFY && !lane.is_empty()) || curve);
    item_button->set_text(curve ? "Add Key" : "Add Notify");
    state_button->set_visible(selected.kind == Kind::NOTIFY && !lane.is_empty());
    remove_button->set_disabled(row.is_empty() && lane.is_empty());
    remove_button->set_text(row.is_empty() && !lane.is_empty() ? "Remove Lane" : "Remove");
    number_fields->set_visible(!row.is_empty() || !lane.is_empty());
    const Dictionary named = curve || row.is_empty() ? lane : row;
    name_field->set_text(named.get("name", String()));
    color_field->set_visible(marker || notify || curve);
    color_field->set_pick_color(row_color(curve ? lane : row, selected.kind));
    show_number(time_field, marker || notify || key);
    time_field->set_max(duration);
    time_field->set_value(key ? double(row["phase"]) * duration : double(row.get("time", 0.0)));
    show_number(end_field, state);
    end_field->set_max(duration);
    end_field->set_value(row.get("end_time", 0.0));
    show_number(value_field, key);
    value_field->set_value(row.get("value", 0.0));
    kind_field->set_visible(notify);
    kind_field->select(!state ? 0 : StringName(row.get("kind", StringName())) == StringName("MeleeTrace") ? 2 : 1);
    curve_fields->set_visible(curve);
    collapse_button->set_text(curve_expanded ? "Collapse" : "Expand");
    mode_field->set_disabled(!key);
    mode_field->select(mode);
    axis_field->select(static_cast<int>(axis));
    weighted_field->set_disabled(!cubic_key);
    weighted_field->set_pressed_no_signal(weighted);
    const Dictionary effective = key ? row_at(effective_curve_keys(), selected.item) : Dictionary();
    tangent_fields->set_visible(cubic_key);
    in_slope_field->set_value(effective.get("in_slope", 0.0));
    out_slope_field->set_value(effective.get("out_slope", 0.0));
    show_number(in_weight_field, weighted);
    show_number(out_weight_field, weighted);
    in_weight_field->set_value(row.get("in_weight", 0.0));
    out_weight_field->set_value(row.get("out_weight", 0.0));
    updating_fields = false;
}

Dictionary CrimsonAnimationTrackEditor::selected_lane() const {
    if (selected.kind == Kind::NOTIFY) return row_at(notify_lanes, selected.lane);
    if (selected.kind == Kind::CURVE) return row_at(curve_lanes, selected.lane);
    return {};
}

Dictionary CrimsonAnimationTrackEditor::selected_item() const {
    if (selected.kind == Kind::MARKER) return row_at(marker_rows, selected.item);
    if (selected.kind == Kind::NOTIFY) return row_at(row_array(selected_lane(), "notifies"), selected.item);
    if (selected.kind == Kind::CURVE) return row_at(selected_curve_keys(), selected.item);
    return {};
}

Array CrimsonAnimationTrackEditor::selected_curve_keys() const {
    return selected.kind == Kind::CURVE ? row_array(selected_lane(), "curve") : Array();
}

TypedArray<Dictionary> CrimsonAnimationTrackEditor::effective_curve_keys() const {
    if (selected.kind != Kind::CURVE || evaluator.is_null()) return {};
    return evaluator->get_curve_keys(selected_lane().get("name", StringName()));
}

Color CrimsonAnimationTrackEditor::row_color(const Dictionary &row, Kind kind) const {
    const Color fallback = ui::color(kind == Kind::MARKER ? ui::Surface::HIGHLIGHT : ui::Surface::ACCENT);
    return row.get("color", fallback);
}

void CrimsonAnimationTrackEditor::select(const Hit &hit, bool extend) {
    const bool new_lane = hit.kind != selected.kind || hit.lane != selected.lane;
    if (new_lane || !extend) {
        keys_selected.clear();
    }
    selected = hit;
    if (hit.kind == Kind::CURVE && hit.item >= 0) {
        const auto found = std::find(keys_selected.begin(), keys_selected.end(), hit.item);
        if (extend && found != keys_selected.end()) {
            keys_selected.erase(found);
            selected.item = keys_selected.empty() ? -1 : keys_selected.back();
        } else {
            keys_selected.push_back(hit.item);
        }
    }
    if (new_lane && hit.kind == Kind::CURVE) {
        curve_expanded = true;
        fit_values();
    }
    refresh_details();
    canvas->sync_layout();
}

void CrimsonAnimationTrackEditor::select_box(const Rect2 &box) {
    keys_selected = canvas->keys_in_box(box);
    selected.item = keys_selected.empty() ? -1 : keys_selected.back();
    refresh_details();
    canvas->queue_redraw();
}

void CrimsonAnimationTrackEditor::seek(double seconds) {
    if (seek_requested.is_valid()) seek_requested.call(seconds);
}

void CrimsonAnimationTrackEditor::add_marker_at_playhead() {
    if (duration <= 0.0) return;
    TypedArray<Dictionary> rows = marker_rows.duplicate(true);
    Dictionary marker;
    marker["name"] = unique_name(rows, "Marker");
    marker["time"] = playhead;
    rows.push_back(marker);
    selected = {Kind::MARKER, 0, rows.size() - 1};
    keys_selected.clear();
    commit(rows, notify_lanes, curve_lanes);
}

void CrimsonAnimationTrackEditor::add_lane(int lane_kind) {
    const Kind kind = static_cast<Kind>(lane_kind);
    TypedArray<Dictionary> rows = kind == Kind::NOTIFY ? notify_lanes.duplicate(true) : curve_lanes.duplicate(true);
    Dictionary lane;
    lane["name"] = unique_name(rows, kind == Kind::NOTIFY ? "Notify" : "Curve");
    lane[kind == Kind::NOTIFY ? "notifies" : "curve"] = Array();
    rows.push_back(lane);
    selected = {kind, rows.size() - 1};
    curve_expanded = true;
    keys_selected.clear();
    low_value = -1;
    high_value = 1;
    if (kind == Kind::NOTIFY) {
        commit(marker_rows, rows, curve_lanes);
    } else {
        commit(marker_rows, notify_lanes, rows);
    }
}

void CrimsonAnimationTrackEditor::add_item(int mode) {
    if (selected.kind == Kind::CURVE) {
        Array keys = selected_curve_keys().duplicate(true);
        const StringName name = selected_lane()["name"];
        const double value = evaluator.is_valid() ? evaluator->sample_curve(name, playhead) : 0.0;
        const int64_t key_index = insert_key(keys, make_key(playhead / duration, value));
        if (key_index < 0) {
            status->set_text("A key already exists at this time.");
            status->show();
            return;
        }
        selected.item = key_index;
        keys_selected = {key_index};
        update_curve_keys(keys);
        return;
    }
    if (selected.kind != Kind::NOTIFY || !has_index(notify_lanes, selected.lane)) return;
    Dictionary lane = selected_lane().duplicate(true);
    Array entries = lane["notifies"];
    const double time = mode == 0 ? playhead : std::min(playhead, duration - min_state_length);
    Dictionary notify;
    notify["name"] = unique_name(entries, mode == 0 ? "Notify" : "State");
    notify["time"] = time;
    notify["end_time"] = mode == 0 ? -1.0 : std::min(time + 0.15, duration);
    entries.push_back(notify);
    selected.item = entries.size() - 1;
    update_selected(lane, true);
}

void CrimsonAnimationTrackEditor::delete_selection() {
    if (selected.kind == Kind::MARKER && has_index(marker_rows, selected.item)) {
        TypedArray<Dictionary> markers = marker_rows.duplicate(true);
        markers.remove_at(selected.item);
        selected.item = -1;
        commit(markers, notify_lanes, curve_lanes);
    } else if (selected.kind == Kind::NOTIFY && has_index(notify_lanes, selected.lane)) {
        if (selected.item >= 0) {
            Dictionary lane = selected_lane().duplicate(true);
            Array entries = lane["notifies"];
            entries.remove_at(selected.item);
            selected.item = -1;
            update_selected(lane, true);
        } else {
            TypedArray<Dictionary> notifies = notify_lanes.duplicate(true);
            notifies.remove_at(selected.lane);
            selected = {};
            commit(marker_rows, notifies, curve_lanes);
        }
    } else if (selected.kind == Kind::CURVE && has_index(curve_lanes, selected.lane)) {
        if (keys_selected.empty()) {
            TypedArray<Dictionary> curves = curve_lanes.duplicate(true);
            curves.remove_at(selected.lane);
            selected = {};
            commit(marker_rows, notify_lanes, curves);
        } else {
            Array keys = selected_curve_keys().duplicate(true);
            std::sort(keys_selected.begin(), keys_selected.end(), std::greater<>());
            for (const int64_t index : keys_selected) keys.remove_at(index);
            keys_selected.clear();
            selected.item = -1;
            update_curve_keys(keys);
        }
    }
}

bool CrimsonAnimationTrackEditor::update_selected(const Dictionary &row, bool lane) {
    if (selected.kind == Kind::MARKER && has_index(marker_rows, selected.item)) {
        TypedArray<Dictionary> markers = marker_rows.duplicate(true);
        markers[selected.item] = row;
        return commit(markers, notify_lanes, curve_lanes);
    }
    if (selected.kind == Kind::NOTIFY && has_index(notify_lanes, selected.lane)) {
        TypedArray<Dictionary> notifies = notify_lanes.duplicate(true);
        if (lane) {
            notifies[selected.lane] = row;
        } else if (selected.item >= 0) {
            Dictionary parent = notifies[selected.lane];
            Array entries = parent["notifies"];
            entries[selected.item] = row;
        }
        return commit(marker_rows, notifies, curve_lanes);
    }
    if (selected.kind == Kind::CURVE && has_index(curve_lanes, selected.lane)) {
        TypedArray<Dictionary> curves = curve_lanes.duplicate(true);
        curves[selected.lane] = row;
        return commit(marker_rows, notify_lanes, curves);
    }
    return false;
}

bool CrimsonAnimationTrackEditor::update_curve_keys(const Array &keys) {
    Dictionary lane = selected_lane().duplicate();
    lane["curve"] = keys;
    return update_selected(lane, true);
}

void CrimsonAnimationTrackEditor::commit_name(const String &name) {
    if (updating_fields) return;
    const bool lane = selected.kind == Kind::CURVE || selected.item < 0;
    Dictionary row = (lane ? selected_lane() : selected_item()).duplicate();
    if (row.is_empty()) return;
    row["name"] = name.strip_edges();
    update_selected(row, lane);
}

void CrimsonAnimationTrackEditor::commit_number(double next, int numeric_field) {
    if (updating_fields || !std::isfinite(next)) return;
    const Field field = static_cast<Field>(numeric_field);
    Dictionary row = selected_item().duplicate();
    if (row.is_empty()) return;
    if (selected.kind != Kind::CURVE) {
        row[field == Field::END ? "end_time" : "time"] = next;
        update_selected(row, false);
        return;
    }
    Array keys = selected_curve_keys().duplicate(true);
    if (field == Field::TIME) {
        keys.remove_at(selected.item);
        row["phase"] = next / duration;
        const int64_t moved = insert_key(keys, row);
        if (moved < 0) {
            refresh_details();
            status->set_text("A key already exists at this time.");
            status->show();
            return;
        }
        selected.item = moved;
        keys_selected = {moved};
    } else if (field == Field::VALUE) {
        row["value"] = next;
        keys[selected.item] = row;
    } else {
        const Dictionary effective = effective_curve_keys()[selected.item];
        change_key_mode(row, effective, BREAK);
        switch (field) {
            case Field::IN_SLOPE: row["in_slope"] = next; break;
            case Field::OUT_SLOPE: row["out_slope"] = next; break;
            case Field::IN_WEIGHT: row["in_weight"] = next; row["weighted_in"] = true; break;
            case Field::OUT_WEIGHT: row["out_weight"] = next; row["weighted_out"] = true; break;
            default: return;
        }
        keys[selected.item] = row;
    }
    update_curve_keys(keys);
}

void CrimsonAnimationTrackEditor::commit_color() {
    if (updating_fields) return;
    const bool lane = selected.kind == Kind::CURVE;
    Dictionary row = (lane ? selected_lane() : selected_item()).duplicate();
    if (row.is_empty()) return;
    row["color"] = color_field->get_pick_color();
    update_selected(row, lane);
}

void CrimsonAnimationTrackEditor::commit_mode(int index) {
    if (updating_fields || selected.kind != Kind::CURVE || keys_selected.empty() || index < CONSTANT || index > BREAK) return;
    Array keys = selected_curve_keys().duplicate(true);
    const Array effective = effective_curve_keys();
    for (const int64_t key_index : keys_selected) {
        Dictionary row = keys[key_index];
        change_key_mode(row, effective[key_index], index);
    }
    update_curve_keys(keys);
}

void CrimsonAnimationTrackEditor::commit_weighted(bool enabled) {
    if (updating_fields || selected.kind != Kind::CURVE || keys_selected.empty()) return;
    Array keys = selected_curve_keys().duplicate(true);
    const Array effective = effective_curve_keys();
    for (const int64_t index : keys_selected) {
        Dictionary row = keys[index];
        for (const bool incoming : {true, false}) {
            if (!has_tangent(effective, index, incoming)) continue;
            const char *flag = incoming ? "weighted_in" : "weighted_out";
            if (bool(row[flag]) == enabled) continue;
            if (enabled) {
                const double slope = Dictionary(effective[index])[incoming ? "in_slope" : "out_slope"];
                row[incoming ? "in_weight" : "out_weight"] = std::abs(handle_delta(effective, index, incoming)) * std::hypot(1.0, slope);
            }
            row[flag] = enabled;
        }
    }
    update_curve_keys(keys);
}

void CrimsonAnimationTrackEditor::commit_notify_kind(int index) {
    if (updating_fields || selected.kind != Kind::NOTIFY) return;
    Dictionary row = selected_item().duplicate();
    if (row.is_empty()) return;
    if (index == 0) {
        row["end_time"] = -1.0;
        row.erase("kind");
    } else {
        const double start = std::min(double(row["time"]), duration - min_state_length);
        const double old_end = row.get("end_time", -1.0);
        row["time"] = start;
        row["end_time"] = old_end > start ? old_end : std::min(start + 0.15, duration);
        row["kind"] = index == 2 ? StringName("MeleeTrace") : StringName();
    }
    update_selected(row, false);
}

void CrimsonAnimationTrackEditor::select_axis(int index) {
    if (!updating_fields && index >= 0 && index <= static_cast<int>(Axis::VALUE)) {
        axis = static_cast<Axis>(index);
    }
}

void CrimsonAnimationTrackEditor::blend_neighbors(double direction) {
    if (keys_selected.empty() || selected.kind != Kind::CURVE) return;
    const Array keys = selected_curve_keys();
    Array blended = keys.duplicate(true);
    for (const int64_t index : keys_selected) {
        const int64_t step = direction < 0 ? -1 : 1;
        int64_t neighbor = index + step;
        while (has_index(keys, neighbor) && std::find(keys_selected.begin(), keys_selected.end(), neighbor) != keys_selected.end()) {
            neighbor += step;
        }
        if (!has_index(keys, neighbor)) {
            neighbor -= step;
        }
        Dictionary target = blended[index];
        target["value"] = Dictionary(keys[neighbor])["value"];
    }
    update_curve_keys(blended);
}

void CrimsonAnimationTrackEditor::fit_values() {
    const Array keys = selected_curve_keys();
    low_value = keys.is_empty() ? -1.0 : double(Dictionary(keys[0])["value"]);
    high_value = keys.is_empty() ? 1.0 : low_value;
    for (const Variant &entry : keys) {
        const double value = Dictionary(entry)["value"];
        low_value = std::min(low_value, value);
        high_value = std::max(high_value, value);
    }
    const double padding = std::max(0.25, (high_value - low_value) / 6.0);
    low_value -= padding;
    high_value += padding;
    canvas->queue_redraw();
}

void CrimsonAnimationTrackEditor::toggle_curve() {
    if (selected.kind != Kind::CURVE) return;
    curve_expanded = !curve_expanded;
    refresh_details();
    canvas->sync_layout();
}

void CrimsonAnimationTrackEditor::refresh_presets() {
    presets = read_presets(legacy_preset_path, true);
    for (const Variant &entry : read_presets(native_preset_path(), false)) {
        const Dictionary row = entry;
        const int64_t index = find_named_row(presets, row["name"]);
        if (index >= 0) {
            presets[index] = row;
        } else {
            presets.push_back(row);
        }
    }
    preset_options->clear();
    preset_options->add_item("Add Preset");
    for (const Variant &entry : presets) {
        preset_options->add_item(Dictionary(entry)["name"]);
    }
    preset_options->select(0);
    preset_options->set_disabled(duration <= 0 || presets.is_empty());
}

void CrimsonAnimationTrackEditor::add_preset(int index) {
    preset_options->select(0);
    if (!has_index(presets, index - 1)) return;
    Dictionary row = normalize_preset(presets[index - 1]);
    if (row.is_empty()) {
        status->set_text("That preset contains invalid curve keys.");
        status->show();
        return;
    }
    row["name"] = unique_name(curve_lanes, row["name"]);
    TypedArray<Dictionary> curves = curve_lanes.duplicate(true);
    curves.push_back(row);
    selected = {Kind::CURVE, curves.size() - 1};
    keys_selected.clear();
    curve_expanded = true;
    if (commit(marker_rows, notify_lanes, curves)) fit_values();
}

void CrimsonAnimationTrackEditor::save_preset() {
    if (selected.kind != Kind::CURVE) return;
    pending_preset = selected_lane().duplicate(true);
    const String name = pending_preset["name"];
    if (find_named_row(read_presets(native_preset_path(), false), name) >= 0) {
        preset_confirmation->set_text(vformat("Replace the saved curve preset \"%s\"?", name));
        preset_confirmation->popup_centered();
        return;
    }
    write_preset();
}

void CrimsonAnimationTrackEditor::write_preset() {
    if (pending_preset.is_empty()) return;
    const Dictionary row = pending_preset;
    pending_preset = {};
    const String path = native_preset_path();
    if (ResourceLoader::get_singleton()->exists(path)) {
        const Ref<Resource> current = ResourceLoader::get_singleton()->load(path, "", ResourceLoader::CACHE_MODE_IGNORE);
        if (current.is_null() || !current->has_meta(preset_metadata)) {
            status->set_text("The preset path points to a different resource. Choose a native catalog path in Project Settings.");
            status->show();
            return;
        }
    }
    TypedArray<Dictionary> rows = read_presets(path, false);
    const int64_t index = find_named_row(rows, row["name"]);
    if (index >= 0) {
        rows[index] = row;
    } else {
        rows.push_back(row);
    }
    Ref<Resource> catalog;
    catalog.instantiate();
    catalog->set_meta(preset_metadata, rows);
    if (ResourceSaver::get_singleton()->save(catalog, path) != OK) {
        status->set_text(vformat("Could not save presets to %s.", path));
        status->show();
        return;
    }
    EditorInterface::get_singleton()->get_resource_filesystem()->update_file(path);
    refresh_presets();
    status->set_text(vformat("Saved curve preset \"%s\".", row["name"]));
    status->show();
}

void CrimsonAnimationTrackEditor::finish_drag(const Hit &hit, double delta_time, double delta_value, bool dominant_axis) {
    if (hit.item < 0 || hit.kind != selected.kind || hit.lane != selected.lane || duration <= 0) return;
    if (hit.kind != Kind::CURVE) {
        selected.item = hit.item;
        Dictionary row = selected_item().duplicate();
        const double start = row["time"];
        const double end = row.get("end_time", -1.0);
        if (end < 0) {
            row["time"] = std::clamp(start + delta_time, 0.0, duration);
        } else if (hit.handle < 0) {
            row["time"] = std::clamp(start + delta_time, 0.0, std::max(0.0, end - min_state_length));
        } else if (hit.handle > 0) {
            row["end_time"] = std::clamp(end + delta_time, std::min(start + min_state_length, duration), duration);
        } else {
            const double movement = std::clamp(delta_time, -start, duration - end);
            row["time"] = start + movement;
            row["end_time"] = end + movement;
        }
        update_selected(row, false);
        return;
    }

    const Array keys = selected_curve_keys();
    const Array effective = effective_curve_keys();
    if (hit.handle != 0) {
        const bool incoming = hit.handle < 0;
        if (!has_tangent(effective, hit.item, incoming)) return;
        Array adjusted = keys.duplicate(true);
        Dictionary row = adjusted[hit.item];
        const Dictionary effective_item = effective[hit.item];
        const char *slope_field_name = incoming ? "in_slope" : "out_slope";
        const double old_time = handle_delta(effective, hit.item, incoming);
        const double horizontal = old_time + delta_time / duration;
        const double time = incoming ? std::min(-1e-8, horizontal) : std::max(1e-8, horizontal);
        const double value = old_time * double(effective_item[slope_field_name]) + delta_value;
        change_key_mode(row, effective_item, BREAK);
        row[slope_field_name] = value / time;
        if (bool(row[incoming ? "weighted_in" : "weighted_out"])) {
            row[incoming ? "in_weight" : "out_weight"] = std::hypot(time, value);
        }
        update_curve_keys(adjusted);
        return;
    }
    if (keys_selected.empty()) return;
    const bool prefer_time = std::abs(delta_time / duration) >= std::abs(delta_value / (high_value - low_value));
    const bool may_move_time = axis != Axis::VALUE && (!dominant_axis || axis == Axis::TIME || prefer_time);
    const bool may_move_value = axis != Axis::TIME && (!dominant_axis || axis == Axis::VALUE || !prefer_time);
    double minimum_delta = -1.0;
    double maximum_delta = 1.0;
    for (const int64_t index : keys_selected) {
        const double phase = Dictionary(keys[index])["phase"];
        minimum_delta = std::max(minimum_delta, -phase);
        maximum_delta = std::min(maximum_delta, 1.0 - phase);
    }
    const double phase_delta = may_move_time ? std::clamp(delta_time / duration, minimum_delta, maximum_delta) : 0.0;
    std::vector<double> selected_phases;
    Array adjusted;
    double primary_phase = -1.0;
    for (int64_t index = 0; index < keys.size(); ++index) {
        Dictionary row = Dictionary(keys[index]).duplicate();
        if (std::find(keys_selected.begin(), keys_selected.end(), index) != keys_selected.end()) {
            const double phase = std::clamp(double(row["phase"]) + phase_delta, 0.0, 1.0);
            row["phase"] = phase;
            if (may_move_value) row["value"] = double(row["value"]) + delta_value;
            selected_phases.push_back(phase);
            if (index == selected.item) primary_phase = phase;
        }
        if (insert_key(adjusted, row) < 0) {
            status->set_text("Keys must have distinct times.");
            status->show();
            return;
        }
    }
    keys_selected.clear();
    for (int64_t index = 0; index < adjusted.size(); ++index) {
        const double phase = Dictionary(adjusted[index])["phase"];
        if (std::find(selected_phases.begin(), selected_phases.end(), phase) != selected_phases.end()) {
            keys_selected.push_back(index);
        }
        if (phase == primary_phase) selected.item = index;
    }
    update_curve_keys(adjusted);
}

void register_animation_track_editor_types() {
    GDREGISTER_INTERNAL_CLASS(AnimationTrackCanvas);
    GDREGISTER_INTERNAL_CLASS(CrimsonAnimationTrackEditor);
}

} // namespace crimson::weapon_animation

#endif
