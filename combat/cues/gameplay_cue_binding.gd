@tool
class_name GameplayCueBinding
extends Resource
## Maps a presentation tag to a saved cue scene on an AbilitySystem.

## GameplayCue tag handled by the scene. A more specific binding takes precedence.
@export var cue_tag: StringName = &""
## Scene whose root implements handle_gameplay_cue(target, tag, event, parameters).
## Retained cues are removed automatically. A scene used for a one-shot must free itself.
@export var cue_scene: PackedScene
