// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#include "editor_controls.hpp"

#ifdef DEBUG_ENABLED

namespace godot {
class Control;
class HSplitContainer;
class MarginContainer;
class PanelContainer;
class VSplitContainer;
}

namespace crimson::editor_ui {

/// Attach a full-bleed panel in the requested visual role.
godot::PanelContainer *surface_panel(godot::Node *owner, Surface role);

/// Attach a content slot with scaled horizontal and vertical padding.
godot::MarginContainer *inset(godot::Node *owner, int horizontal, int vertical);

/// Attach side-by-side panels with the native resizable divider.
godot::HSplitContainer *split_pane(godot::Node *owner, godot::Control *left, godot::Control *right);

/// Attach a resizable upper viewport and lower editing pane.
godot::VSplitContainer *split_pane_vertical(godot::Node *owner, godot::Control *top, godot::Control *bottom);

} // namespace crimson::editor_ui

#endif
