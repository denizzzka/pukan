# Godot scene demo

Run from the repository root; a Vulkan driver and a D compiler are required.

## Truck town

```sh
dub run --root=demo_godot -- --scene demo_godot/godot_samples/truck_town/town_view.tscn --scene-camera
```

`--scene-camera` starts from the `Camera3D` stored in the scene.

## Platformer

```sh
dub run --root=demo_godot -- --scene demo_godot/godot_samples/platformer/stage/stage.tscn --eye 8,8,-12 --target 0,1,0
```

The stage has no scene camera, and the default view starts inside a wall, so the
eye and target place the free camera outside it.

## Controls

Every demo uses the same free camera. The cursor is captured while the right or
middle mouse button is held and is restored when the button is released.

| Input | Action |
| --- | --- |
| Right mouse drag | Look around |
| Middle mouse drag | Pan the view |
| Mouse wheel | Zoom towards the cursor |
| W / S | Move forward / backward |
| A / D | Strafe left / right |
| Q / E | Roll left / right |
| R | Reset the roll |
| H | Toggle the look axis between horizontal (world up) and screen (camera up) |
| Shift | Move faster |
| Alt | Move slower |

`--speed` sets the base camera speed that Shift and Alt scale. `--plain` draws
every surface in a simple lit mode, `--no-shadows` disables shadows, and
`--screenshot path` saves a frame.
