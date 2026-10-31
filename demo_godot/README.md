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

WASD moves, the right mouse button looks, the middle button pans, the wheel
zooms, Q/E rolls and R resets the roll. `--plain` draws every surface in a
simple lit mode, `--no-shadows` disables shadows, and `--screenshot path` saves
a frame.
