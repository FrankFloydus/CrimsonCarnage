// Copyright Francesco Di Blasi 2026 - All Rights Reserved

#pragma once

#ifdef DEBUG_ENABLED

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>

namespace godot {
class AnimationPlayer;
class Camera3D;
class EditorUndoRedoManager;
class Node;
}

namespace crimson::weapon_animation {

/// Validates Viewer clip packs and commits detached animation libraries as one editor action.
class ViewerClipImport {
public:
    /// Read a version 1 Godot-axis pack. The result contains its rig and clips or an error string.
    static godot::Dictionary inspect(const godot::String &path);
    /// Display a source clip's leaf name independently of its source path and extension.
    static godot::String clip_label(const godot::String &source_name);
    /// Suggest a unique destination library based on the weapon sets in the pack.
    static godot::String suggested_library_name(godot::AnimationPlayer *player, const godot::Dictionary &pack);
    /// Confirm that the edited scene owns this player and exposes first-person weapon sockets.
    static bool can_import(godot::Node *edited_scene, godot::AnimationPlayer *player,
            godot::Camera3D *preferred_camera = nullptr);
    /// Explain why a library choice cannot be used. An empty result means it is valid.
    static godot::String destination_error(godot::AnimationPlayer *player, const godot::StringName &library_name,
            bool create_library);
    /// Append the requested pack indexes, or all clips for an empty selection. Return an error or a result message.
    static godot::Dictionary commit(godot::Node *edited_scene, godot::AnimationPlayer *player,
            godot::Camera3D *preferred_camera, godot::EditorUndoRedoManager *undo, const godot::Dictionary &pack,
            const godot::StringName &library_name, bool create_library, const godot::PackedInt32Array &indices = {});
};

} // namespace crimson::weapon_animation

#endif
