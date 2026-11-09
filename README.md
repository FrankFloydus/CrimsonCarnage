# untitled

A first-person movement playground configured for Godot 4.7, Forward Plus, and Jolt Physics. Import `project.godot` and press **F5** to run the saved [Playground scene](levels/playground/playground.tscn). The course includes a walled arena, parkour blocks, two staircases, and crouch tunnels.

| Control | Action |
| --- | --- |
| WASD | Move |
| Mouse | Look |
| Space | Jump |
| C | Toggle crouch |
| Hold Shift | Sprint |
| Hold Ctrl | Walk |
| Escape | Release the mouse |
| Left click | Recapture the mouse |

The game captures the mouse on startup. Press **Escape** or switch focus to release it. Click inside the viewport to resume input. Walk and crouch take precedence over sprint. Release **Shift** before jumping from a sprint.

## Tune the controller

| Change | Open in the editor |
| --- | --- |
| Default controls | **Project → Project Settings → Input Map** |
| Run speed, gait multipliers, jump height, acceleration, and stair limits | **Player → Movement → Settings** |
| Crouch mode, capsule height, and eye-height transition | **Player → Crouch → Settings** |
| Mouse sensitivity, pitch, camera tilt, and stair smoothing | **Player → Look → Settings** |

Open the [Player scene](player/player.tscn) to access those components. See the [movement architecture](docs/architecture.md) for the configured values and how each component works.
