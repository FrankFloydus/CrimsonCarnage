// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#ifdef DEBUG_ENABLED

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/theme.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/color.hpp>

namespace godot {
class Button;
class CheckBox;
class Label;
class LineEdit;
class Node;
class Window;
}

namespace crimson::editor_ui {

/// Emphasis for an editor command.
enum class ButtonStyle { SECONDARY, PRIMARY, QUIET };

/// Text role for an editor label.
enum class LabelStyle { BODY, MUTED, HEADING };

/// Initial state of a native on-or-off option.
enum class CheckState { UNCHECKED, CHECKED };

/// Color roles shared by built-in controls and animation timeline drawing.
enum class Surface { CANVAS, HEADER, RAISED, RULE, OUTLINE, TEXT, MUTED, HOVER, SELECTED, HIGHLIGHT,
    SIDEBAR, ACCENT, DISABLED };

/// Return the animation tool's color for a visual role.
godot::Color color(Surface role);

/// Create the window's native control theme using its editor font and logical scale.
godot::Ref<godot::Theme> create_theme(const godot::Window *owner, double scale = 1.0);

/// Keep the tool's child popups inside the native editor window.
void embed_editor_popups(godot::Window *owner);

/// Convert a logical distance using the host control or window's theme scale.
int pixels(godot::Node *host, double logical);

/// Attach a command button. An existing shortcut appears in help; the caller routes it.
godot::Button *button(godot::Node *owner, const godot::String &text, const godot::String &help = {},
        const godot::Callable &command = {}, ButtonStyle style = ButtonStyle::SECONDARY,
        godot::Key shortcut = godot::KEY_NONE);

/// Attach a display label using the requested text role.
godot::Label *label(godot::Node *owner, const godot::String &text, LabelStyle style = LabelStyle::BODY);

/// Attach an editable single-line text field with optional task-specific help.
godot::LineEdit *text_input(godot::Node *owner, const godot::String &text, const godot::String &help = {});

/// Attach a checkbox. The callback receives the user's new state.
godot::CheckBox *checkbox(godot::Node *owner, const godot::String &text, CheckState state = CheckState::UNCHECKED,
        const godot::Callable &toggled = {});

} // namespace crimson::editor_ui

#endif
