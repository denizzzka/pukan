# Godot scene demo

Run from the repository root; a Vulkan driver and a D compiler are required.

## Platformer

```sh
dub run :demo_godot
```

No arguments loads the platformer stage, which is flat, walks a capsule through it and
follows it in third person; that is where locomotion and motion matching are tested. The
capsule starts on the platform under the middle of the stage and the view faces along the
platform. `V` switches between third and first person while it runs, `--first-person`
starts in the character's eyes.

```sh
dub run :demo_godot -- --no-character --scene demo_godot/godot_samples/platformer/stage/stage.tscn --eye 8,8,-12 --target 0,1,0
```

The stage has no scene camera, and the free camera would start inside a wall, so the eye
and target place it outside.

## Truck town

```sh
dub run :demo_godot -- --scene demo_godot/godot_samples/truck_town/town_view.tscn --scene-camera
```

`--no-character` with `--scene-camera` starts the free camera from the `Camera3D` stored in
the scene; the town has no spawn marker, so a character starts on the surface under the
middle of the level, which is a slope.

## Character

Character mode and third person are the defaults: `--no-character` flies the free camera,
`--first-person` starts in the eyes. `--scene` picks another level, and
`--scene demo_godot/godot_samples/character/level.tscn` is the movement gym.

The capsule starts at `--spawn x,y,z` when given, else at the first `Marker3D` or
`CharacterBody3D` of the scene, else on the first surface under the middle of the level. A
start point inside the geometry is lifted out along the up axis, so a marker under the
terrain cannot trap it.

The default model is `demo/assets/motion/UAL1_Standard_RM.glb`, and its `Idle_Loop`,
`Walk_Loop`, `Jog_Fwd_Loop` and `Sprint_Loop` clips drive motion matching: the search picks
the pose that fits the input and the current motion, and the capsule then moves at the speed
of the chosen pose times its play rate, so the feet cannot slide. Collisions stay with the
Mover. A model without those clips, such as the CesiumMan
fixture passed to `--model`, simply plays its own animation.

Movement is camera-relative: W runs where the view looks, A and D to the sides, S back. The
character turns towards where it moves and plays its forward clips, because the library has
no strafing or backwards motion.

In third person the camera pulls in when a wall is behind the character; `--no-spring-arm`
keeps the distance fixed.

`--debug-capsule` draws the collision capsule, `--walk` holds forward, `--move-speed` sets how
fast the character runs (the Quake maximum by default), `--noclip` ignores collisions, and
`--physics-hz` sets the character tick rate.

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
