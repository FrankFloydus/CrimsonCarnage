// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#ifdef DEBUG_ENABLED

#include "modules/weapon_animation/animation_clip.hpp"
#include "modules/weapon_animation/animation_tracks.hpp"

#include <godot_cpp/classes/v_box_container.hpp>
#include <godot_cpp/variant/callable.hpp>

#include <vector>

namespace godot {
class Button;
class CheckBox;
class ColorPickerButton;
class ConfirmationDialog;
class HBoxContainer;
class Label;
class LineEdit;
class OptionButton;
class SpinBox;
}

namespace crimson::weapon_animation {

class AnimationTrackCanvas;

/// Edits a detached set of track rows and reports each completed gesture to the workspace.
class CrimsonAnimationTrackEditor final : public godot::VBoxContainer {
    GDCLASS(CrimsonAnimationTrackEditor, godot::VBoxContainer)

public:
    /// Create the control once. Changes report an updated draft, and seeks report clip seconds.
    void build(const godot::Callable &changed, const godot::Callable &seek_requested);
    /// Switch the rows displayed by this control without recording an edit.
    void set_tracks(const godot::Ref<CrimsonWeaponAnimationTracks> &tracks, double duration);
    /// Return the current validated draft for the workspace's persistence and undo paths.
    godot::Ref<CrimsonWeaponAnimationTracks> get_tracks() const;
    /// Set the cursor in clip seconds without seeking the preview.
    void set_playhead(double seconds);
    /// Set the same horizontal window as the workspace's time ruler.
    void set_time_view(double offset, double visible_duration);
    /// Create a marker at the current playhead.
    void add_marker_at_playhead();
    /// Remove the selected items, or remove an itemless selection's lane.
    void delete_selection();

protected:
    /// Register the private control used by the native workbench.
    static void _bind_methods() {}

private:
    friend class AnimationTrackCanvas;

    /// Track types use stable identifiers in the canvas and details fields.
    enum class Kind { NONE, MARKER, NOTIFY, CURVE };
    /// Which component of a time and value curve drag can move.
    enum class Axis { FREE, TIME, VALUE };
    /// Fields that share the same numeric commit implementation.
    enum class Field { TIME, END, VALUE, IN_SLOPE, OUT_SLOPE, IN_WEIGHT, OUT_WEIGHT };
    /// Address of a lane, item, endpoint or tangent inside the detached draft.
    struct Hit {
        Kind kind = Kind::NONE; ///< Type of row under the pointer.
        int64_t lane = -1; ///< Lane index, or zero for markers.
        int64_t item = -1; ///< Item index, or -1 for a lane without a selected item.
        int handle = 0; ///< Zero for the item, -1/1 for a tangent or notify edge.
    };

    /// Replace a draft row set atomically and report validity or rejection.
    bool commit(const godot::TypedArray<godot::Dictionary> &markers,
            const godot::TypedArray<godot::Dictionary> &notifies,
            const godot::TypedArray<godot::Dictionary> &curves);
    /// Update cached rows, curve evaluation and the visible fields.
    void refresh();
    /// Enable and populate fields for the current selection.
    void refresh_details();
    /// Choose one lane or item and select or toggle its key when requested.
    void select(const Hit &hit, bool extend = false);
    /// Select every visible curve key whose point is inside the box.
    void select_box(const godot::Rect2 &box);
    /// Convert a pointer delta into one transactional edit on its selected record or records.
    void finish_drag(const Hit &hit, double seconds_delta, double value_delta, bool dominant_axis);
    /// Request a preview seek without altering any authored track.
    void seek(double seconds);
    /// Return the current authored lane selection or an empty dictionary.
    godot::Dictionary selected_lane() const;
    /// Return the currently selected row item or an empty dictionary.
    godot::Dictionary selected_item() const;
    /// Return the authored keys in the currently selected curve.
    godot::Array selected_curve_keys() const;
    /// Return effective curve key tangent attributes for the selected curve.
    godot::TypedArray<godot::Dictionary> effective_curve_keys() const;
    /// Report the colored presentation for a lane or key.
    godot::Color row_color(const godot::Dictionary &row, Kind kind) const;
    /// Create an empty notify or curve lane.
    void add_lane(int lane_kind);
    /// Add a selected lane's notify, state or float key at the playhead.
    void add_item(int mode);
    /// Commit a lane, marker, or notify label.
    void commit_name(const godot::String &name);
    /// Commit an exact time, value, slope or weight.
    void commit_number(double value, int numeric_field);
    /// Replace one selected marker, notify or lane.
    bool update_selected(const godot::Dictionary &row, bool lane);
    /// Replace the selected curve's key list while preserving lane properties.
    bool update_curve_keys(const godot::Array &keys);
    /// Commit the selected item's authored display color.
    void commit_color();
    /// Set the interpolation mode of selected float keys.
    void commit_mode(int index);
    /// Toggle weighted tangents for selected float keys.
    void commit_weighted(bool enabled);
    /// Change a notify to an instantaneous event, a state or a MeleeTrace state.
    void commit_notify_kind(int index);
    /// Set the curve drag axis restriction.
    void select_axis(int index);
    /// Blend each contiguous selected curve-key range toward the preceding or following key.
    void blend_neighbors(double direction);
    /// Fit the displayed curve values to its authored keys.
    void fit_values();
    /// Toggle expansion of the selected curve graph without editing the key data.
    void toggle_curve();
    /// Re-read the available native and legacy curve presets.
    void refresh_presets();
    /// Insert a detached copy of the specified curve preset.
    void add_preset(int index);
    /// Save the selected curve as a reusable preset, confirming a replacement.
    void save_preset();
    /// Persist the preset selected when the save command was invoked.
    void write_preset();

    /// Detached resource owned by this editor for copy-on-edit.
    godot::Ref<CrimsonWeaponAnimationTracks> draft;
    /// Snapshot used to sample the current set of curves.
    godot::Ref<CrimsonWeaponAnimationClip> evaluator;
    /// Cached authored marker rows for rendering and selecting.
    godot::TypedArray<godot::Dictionary> marker_rows;
    /// Cached authored notify lanes for rendering and selecting.
    godot::TypedArray<godot::Dictionary> notify_lanes;
    /// Cached authored curve lanes for rendering and selecting.
    godot::TypedArray<godot::Dictionary> curve_lanes;
    /// Commit receiver owned by the enclosing workspace.
    godot::Callable changed;
    /// Seek receiver owned by the enclosing workspace.
    godot::Callable seek_requested;
    /// Duration of the displayed clip in seconds.
    double duration = 0;
    /// Current playback cursor in seconds.
    double playhead = 0;
    /// First visible time from the shared ruler.
    double visible_start = 0;
    /// Number of visible seconds from the shared ruler.
    double visible_duration = 0;
    /// Bottom of the displayed curve value range.
    double low_value = -1;
    /// Top of the displayed curve value range.
    double high_value = 1;
    /// Active row and item.
    Hit selected;
    /// Selected keys in the curve identified by selected.lane.
    std::vector<int64_t> keys_selected;
    /// Optional drag restriction for the selected curve.
    Axis axis = Axis::FREE;
    /// Whether the selected curve shows its full graph.
    bool curve_expanded = true;
    /// Whether this control is reflecting a draft instead of committing input.
    bool updating_fields = false;
    /// Graph control responsible for drawing and receiving track gestures.
    AnimationTrackCanvas *canvas = nullptr;
    /// Toolbar command that adds a marker.
    godot::Button *marker_button = nullptr;
    /// Toolbar command that creates a notify lane.
    godot::Button *notify_button = nullptr;
    /// Toolbar command that creates a float curve lane.
    godot::Button *curve_button = nullptr;
    /// Adds a key or one-shot notify to the selection.
    godot::Button *item_button = nullptr;
    /// Adds a state in the selected notify lane.
    godot::Button *state_button = nullptr;
    /// Removes selected keys, an event, marker or lane.
    godot::Button *remove_button = nullptr;
    /// Selected row identity, exact marker/event name and curve name.
    godot::LineEdit *name_field = nullptr;
    /// Selected color for markers, notify entries or curve lanes.
    godot::ColorPickerButton *color_field = nullptr;
    /// Numerical fields with stable callbacks and contextual visibility.
    godot::HBoxContainer *number_fields = nullptr;
    /// Selected start time or key time.
    godot::SpinBox *time_field = nullptr;
    /// Selected state's end time.
    godot::SpinBox *end_field = nullptr;
    /// Selected curve key value.
    godot::SpinBox *value_field = nullptr;
    /// Incoming slope of the selected float key.
    godot::SpinBox *in_slope_field = nullptr;
    /// Outgoing slope of the selected float key.
    godot::SpinBox *out_slope_field = nullptr;
    /// Incoming tangent weight of the selected float key.
    godot::SpinBox *in_weight_field = nullptr;
    /// Outgoing tangent weight of the selected float key.
    godot::SpinBox *out_weight_field = nullptr;
    /// Interpolation mode in the selected float key.
    godot::OptionButton *mode_field = nullptr;
    /// Selected one-shot, state or MeleeTrace authoring type.
    godot::OptionButton *kind_field = nullptr;
    /// Axis restriction while moving selected curve keys.
    godot::OptionButton *axis_field = nullptr;
    /// Toggle for independent stored cubic tangent weights.
    godot::CheckBox *weighted_field = nullptr;
    /// Selected curve controls for tangent and selection operations.
    godot::HBoxContainer *curve_fields = nullptr;
    /// Numeric tangent fields displayed for a cubic key.
    godot::HBoxContainer *tangent_fields = nullptr;
    /// Toggle for showing the selected curve's graph or compact lane.
    godot::Button *collapse_button = nullptr;
    /// Toolbar choice for adding a curve preset.
    godot::OptionButton *preset_options = nullptr;
    /// Saves the selected curve to the current project's native catalog.
    godot::Button *preset_save = nullptr;
    /// Confirmation when a native preset of the same name exists.
    godot::ConfirmationDialog *preset_confirmation = nullptr;
    /// Cached compatible presets indexed by the popup items.
    godot::TypedArray<godot::Dictionary> presets;
    /// Detached row captured for confirmation and subsequent save.
    godot::Dictionary pending_preset;
    /// Selection identity or a rejected-draft explanation.
    godot::Label *status = nullptr;
};

/// Register the internal toolbar, timeline canvas and graph classes for editor use.
void register_animation_track_editor_types();

} // namespace crimson::weapon_animation

#endif
