// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#include "editor_controls.hpp"

#ifdef DEBUG_ENABLED

#include "editor_compositions.hpp"
#include "editor_spacing.hpp"

#include <godot_cpp/classes/button.hpp>
#include <godot_cpp/classes/check_box.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/font.hpp>
#include <godot_cpp/classes/h_split_container.hpp>
#include <godot_cpp/classes/label.hpp>
#include <godot_cpp/classes/line_edit.hpp>
#include <godot_cpp/classes/margin_container.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/panel_container.hpp>
#include <godot_cpp/classes/style_box_flat.hpp>
#include <godot_cpp/classes/v_split_container.hpp>
#include <godot_cpp/classes/window.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <initializer_list>

namespace crimson::editor_ui {
using namespace godot;

namespace {

constexpr char primary_type[] = "CrimsonTweakerPrimary"; ///< Tool-specific Button variation.
constexpr char quiet_type[] = "CrimsonTweakerQuiet"; ///< Compact secondary Button variation.
constexpr char muted_type[] = "CrimsonTweakerMuted"; ///< Tool-specific secondary label variation.
constexpr char heading_type[] = "CrimsonTweakerHeading"; ///< Tool-specific group heading variation.
constexpr Color transparent(0, 0, 0, 0); ///< Empty surface or transparent focus fill.

/// Decode the palette without allocating strings while the timeline is drawn.
constexpr Color rgb(uint32_t color_code) {
    return Color(((color_code >> 16) & 0xff) / 255.0f, ((color_code >> 8) & 0xff) / 255.0f,
            (color_code & 0xff) / 255.0f);
}

/// Convert a logical length using the supplied Godot editor scale.
int scaled(double logical, double scale) {
    return static_cast<int>(std::lround(logical * scale));
}

/// Build a scoped surface, with optional rim and content insets.
Ref<StyleBoxFlat> frame(Color fill, Color edge, double scale, int inset_x = 0, int inset_y = 0, int radius = 0) {
    Ref<StyleBoxFlat> style;
    style.instantiate();
    style->set_bg_color(fill);
    style->set_border_color(edge);
    style->set_border_width_all(edge.a > 0 ? 1 : 0);
    style->set_corner_radius_all(scaled(radius, scale));
    style->set_anti_aliased(radius > 0);
    for (Side side : {SIDE_LEFT, SIDE_RIGHT}) {
        style->set_content_margin(side, static_cast<float>(scaled(inset_x, scale)));
    }
    for (Side side : {SIDE_TOP, SIDE_BOTTOM}) {
        style->set_content_margin(side, static_cast<float>(scaled(inset_y, scale)));
    }
    return style;
}

/// Theme one of the native command-button variants, including keyboard focus.
void command_styles(const Ref<Theme> &theme, const char *type, double scale, ButtonStyle style) {
    const bool primary = style == ButtonStyle::PRIMARY;
    const bool quiet = style == ButtonStyle::QUIET;
    const Color fill = quiet ? transparent : color(primary ? Surface::ACCENT : Surface::RAISED);
    const Color edge = primary || quiet ? transparent : color(Surface::OUTLINE);
    const int radius = primary ? 14 : 8;
    const int width = quiet ? 5 : 10;
    theme->set_font_size("font_size", type, scaled(12, scale));
    for (const char *state : {"font_color", "font_hover_color", "font_pressed_color",
            "font_hover_pressed_color", "font_focus_color"}) {
        theme->set_color(state, type, color(Surface::TEXT));
    }
    theme->set_color("font_disabled_color", type, color(Surface::DISABLED));
    theme->set_stylebox("normal", type, frame(fill, edge, scale, width, spacing::xs, radius));
    theme->set_stylebox("hover", type, frame(primary ? fill.lightened(0.08f) : color(Surface::HOVER), edge,
            scale, width, spacing::xs, radius));
    const auto pressed = frame(primary ? fill.darkened(0.12f) : color(Surface::SELECTED),
            edge, scale, width, spacing::xs, radius);
    theme->set_stylebox("pressed", type, pressed);
    theme->set_stylebox("hover_pressed", type, pressed);
    theme->set_stylebox("disabled", type, frame(color(Surface::HEADER), color(Surface::RULE),
            scale, width, spacing::xs, radius));
    theme->set_stylebox("focus", type, frame(transparent, color(Surface::HIGHLIGHT), scale, 0, 0, radius));
}

/// Reuse the selected editor font. A default Godot font is provided when the editor has none.
void text_styles(const Ref<Theme> &theme, const Window *owner, double scale) {
    Ref<Font> font;
    if (EditorInterface *editor = EditorInterface::get_singleton()) {
        const Ref<Theme> editor_theme = editor->get_editor_theme();
        if (editor_theme.is_valid()) {
            font = editor_theme->get_default_font();
        }
    }
    if (font.is_null() && owner) {
        font = owner->get_theme_default_font();
    }
    if (font.is_valid()) {
        theme->set_default_font(font);
    }
    theme->set_default_font_size(scaled(13, scale));
    theme->set_color("font_color", "Label", color(Surface::TEXT));
    theme->set_type_variation(muted_type, "Label");
    theme->set_type_variation(heading_type, "Label");
    theme->set_color("font_color", muted_type, color(Surface::MUTED));
    theme->set_color("font_color", heading_type, color(Surface::TEXT));
    theme->set_font_size("font_size", muted_type, scaled(11, scale));
    theme->set_font_size("font_size", heading_type, scaled(13, scale));
}

/// Theme the native editable fields without replacing their subcontrols.
void field_styles(const Ref<Theme> &theme, double scale) {
    const auto active = frame(color(Surface::HEADER), color(Surface::OUTLINE), scale, 8, spacing::xs, 7);
    const auto read_only = frame(color(Surface::SIDEBAR), color(Surface::RULE), scale, 8, spacing::xs, 7);
    const auto focus = frame(transparent, color(Surface::HIGHLIGHT), scale, 0, 0, 7);
    theme->set_stylebox("normal", "LineEdit", active);
    theme->set_stylebox("read_only", "LineEdit", read_only);
    theme->set_stylebox("focus", "LineEdit", focus);
    theme->set_color("font_color", "LineEdit", color(Surface::TEXT));
    theme->set_color("font_uneditable_color", "LineEdit", color(Surface::MUTED));
    theme->set_color("font_placeholder_color", "LineEdit", color(Surface::MUTED));
    theme->set_color("caret_color", "LineEdit", color(Surface::TEXT));
    theme->set_color("selection_color", "LineEdit", color(Surface::ACCENT));
    theme->set_font_size("font_size", "LineEdit", scaled(12, scale));
}

/// Style nested menus, the editor-owned file dialog, and clip selection lists.
void popup_styles(const Ref<Theme> &theme, double scale) {
    const auto popup = frame(color(Surface::RAISED), color(Surface::OUTLINE), scale, 5, 5, 10);
    const auto row = frame(color(Surface::HOVER), transparent, scale, 5, 3, 5);
    const auto selected = frame(color(Surface::SELECTED).lerp(color(Surface::ACCENT), 0.22f), transparent,
            scale, 5, 3, 5);
    theme->set_stylebox("panel", "PopupMenu", popup);
    theme->set_stylebox("hover", "PopupMenu", row);
    theme->set_color("font_color", "PopupMenu", color(Surface::TEXT));
    theme->set_color("font_hover_color", "PopupMenu", color(Surface::TEXT));
    theme->set_color("font_disabled_color", "PopupMenu", color(Surface::DISABLED));
    theme->set_constant("v_separation", "PopupMenu", scaled(spacing::sm, scale));
    theme->set_stylebox("panel", "AcceptDialog", frame(color(Surface::HEADER), color(Surface::OUTLINE),
            scale, spacing::lg, spacing::lg));
    theme->set_stylebox("panel", "TooltipPanel", frame(color(Surface::RAISED), color(Surface::OUTLINE),
            scale, 8, 5, 6));
    theme->set_color("font_color", "TooltipLabel", color(Surface::TEXT));
    theme->set_stylebox("panel", "ItemList", frame(color(Surface::SIDEBAR), color(Surface::RULE), scale, 4, 4, 6));
    theme->set_stylebox("selected", "ItemList", selected);
    theme->set_stylebox("selected_focus", "ItemList", selected);
    theme->set_stylebox("hovered", "ItemList", row);
    theme->set_color("font_color", "ItemList", color(Surface::TEXT));
}

/// Place two panes under a stock splitter and expose its divider to keyboard focus.
template <typename Split>
Split *attach_split(Node *owner, Control *first, Control *second) {
    auto *split = memnew(Split);
    split->set_h_size_flags(Control::SIZE_EXPAND_FILL);
    split->set_v_size_flags(Control::SIZE_EXPAND_FILL);
    split->add_child(first);
    split->add_child(second);
    owner->add_child(split);
    const TypedArray<Control> handles = split->get_drag_area_controls();
    for (int index = 0; index < handles.size(); ++index) {
        if (auto *handle = Object::cast_to<Control>(handles[index])) {
            handle->set_focus_mode(Control::FOCUS_ALL);
            handle->set_accessibility_name("Resize panels");
            handle->set_tooltip_text("Drag or use arrow keys to resize.");
        }
    }
    return split;
}

} // namespace

Color color(Surface role) {
    switch (role) {
        case Surface::CANVAS: return rgb(0x0f0f11);
        case Surface::HEADER: return rgb(0x19191b);
        case Surface::RAISED: return rgb(0x1e1f21);
        case Surface::RULE: return rgb(0x252527);
        case Surface::OUTLINE: return rgb(0x363639);
        case Surface::TEXT: return rgb(0xe8e7ea);
        case Surface::MUTED: return rgb(0xa0a0a6);
        case Surface::HOVER: return rgb(0x232326);
        case Surface::SELECTED: return rgb(0x232325);
        case Surface::HIGHLIGHT: return rgb(0xa89dfa);
        case Surface::SIDEBAR: return rgb(0x121213);
        case Surface::ACCENT: return rgb(0x5e6ad2);
        case Surface::DISABLED: return rgb(0x76767d);
    }
    return {};
}

Ref<Theme> create_theme(const Window *owner, double scale) {
    scale = std::clamp(scale, 0.75, 4.0);
    Ref<Theme> theme;
    theme.instantiate();
    theme->set_default_base_scale(static_cast<float>(scale));
    text_styles(theme, owner, scale);
    theme->set_type_variation(primary_type, "Button");
    theme->set_type_variation(quiet_type, "Button");
    command_styles(theme, "Button", scale, ButtonStyle::SECONDARY);
    command_styles(theme, "OptionButton", scale, ButtonStyle::SECONDARY);
    command_styles(theme, primary_type, scale, ButtonStyle::PRIMARY);
    command_styles(theme, quiet_type, scale, ButtonStyle::QUIET);
    field_styles(theme, scale);
    popup_styles(theme, scale);
    for (const char *type : {"CheckBox", "CheckButton"}) {
        theme->set_color("font_color", type, color(Surface::TEXT));
        theme->set_color("font_disabled_color", type, color(Surface::DISABLED));
        theme->set_constant("h_separation", type, scaled(spacing::sm, scale));
    }
    for (const char *type : {"HBoxContainer", "VBoxContainer", "HSplitContainer", "VSplitContainer"}) {
        theme->set_constant("separation", type, scaled(spacing::sm, scale));
    }
    return theme;
}

void embed_editor_popups(Window *owner) {
    owner->set_embedding_subwindows(true);
}

int pixels(Node *host, double logical) {
    for (Node *node = host; node; node = node->get_parent()) {
        if (auto *control = Object::cast_to<Control>(node)) {
            const double scale = control->get_theme_default_base_scale();
            if (scale > 0.0) {
                return scaled(logical, scale);
            }
        } else if (auto *window = Object::cast_to<Window>(node)) {
            const double scale = window->get_theme_default_base_scale();
            return scaled(logical, scale > 0.0 ? scale : 1.0);
        }
    }
    return scaled(logical, 1.0);
}

Button *button(Node *owner, const String &text, const String &help, const Callable &command, ButtonStyle style,
        Key shortcut) {
    auto *control = memnew(Button);
    control->set_text(text);
    control->set_custom_minimum_size(Vector2(static_cast<real_t>(pixels(owner, 24)), static_cast<real_t>(pixels(owner, 28))));
    control->set_default_cursor_shape(Control::CURSOR_POINTING_HAND);
    control->set_accessibility_name(text);
    control->set_accessibility_description(help);
    String description = help;
    if (shortcut != KEY_NONE) {
        description += (description.is_empty() ? String() : String("\n")) + OS::get_singleton()->get_keycode_string(shortcut);
    }
    control->set_tooltip_text(description);
    if (style == ButtonStyle::PRIMARY) {
        control->set_theme_type_variation(primary_type);
    } else if (style == ButtonStyle::QUIET) {
        control->set_theme_type_variation(quiet_type);
    }
    if (command.is_valid()) {
        control->connect("pressed", command);
    }
    owner->add_child(control);
    return control;
}

LineEdit *text_input(Node *owner, const String &text, const String &help) {
    auto *control = memnew(LineEdit);
    control->set_text(text);
    control->set_custom_minimum_size(Vector2(0, static_cast<real_t>(pixels(owner, 28))));
    control->set_h_size_flags(Control::SIZE_EXPAND_FILL);
    control->set_tooltip_text(help);
    control->set_accessibility_description(help);
    owner->add_child(control);
    return control;
}

CheckBox *checkbox(Node *owner, const String &text, CheckState state, const Callable &toggled) {
    auto *control = memnew(CheckBox);
    control->set_text(text);
    control->set_custom_minimum_size(Vector2(0, static_cast<real_t>(pixels(owner, 28))));
    control->set_pressed_no_signal(state == CheckState::CHECKED);
    if (toggled.is_valid()) {
        control->connect("toggled", toggled);
    }
    owner->add_child(control);
    return control;
}

Label *label(Node *owner, const String &text, LabelStyle style) {
    auto *control = memnew(Label);
    control->set_text(text);
    control->set_mouse_filter(Control::MOUSE_FILTER_IGNORE);
    if (style == LabelStyle::MUTED) {
        control->set_theme_type_variation(muted_type);
    } else if (style == LabelStyle::HEADING) {
        control->set_theme_type_variation(heading_type);
    }
    owner->add_child(control);
    return control;
}

PanelContainer *surface_panel(Node *owner, Surface role) {
    auto *panel = memnew(PanelContainer);
    panel->add_theme_stylebox_override("panel", frame(color(role), transparent, 1.0));
    owner->add_child(panel);
    return panel;
}

MarginContainer *inset(Node *owner, int horizontal, int vertical) {
    auto *content = memnew(MarginContainer);
    content->set_h_size_flags(Control::SIZE_EXPAND_FILL);
    content->add_theme_constant_override("margin_left", pixels(owner, horizontal));
    content->add_theme_constant_override("margin_right", pixels(owner, horizontal));
    content->add_theme_constant_override("margin_top", pixels(owner, vertical));
    content->add_theme_constant_override("margin_bottom", pixels(owner, vertical));
    owner->add_child(content);
    return content;
}

HSplitContainer *split_pane(Node *owner, Control *left, Control *right) {
    return attach_split<HSplitContainer>(owner, left, right);
}

VSplitContainer *split_pane_vertical(Node *owner, Control *top, Control *bottom) {
    return attach_split<VSplitContainer>(owner, top, bottom);
}

} // namespace crimson::editor_ui

#endif
