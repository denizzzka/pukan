# Godot scene fixtures

Three scenes come from the official Godot demo projects, one is generated
here, one is a small project exported as a PCK, and `cutout_shadow/` is written
for this repository. They cover the text scene format, the binary RSRC format,
ArrayMesh surfaces, primitive meshes, StandardMaterial3D, external glTF scenes,
skeletons, a landscape and animation.

## Sources

Upstream: https://github.com/godotengine/godot-demo-projects
Commit: `b761b4cd5718a7118f2c95eb55f181d0a5f004f1` (`master`).

- `lights_and_shadows/` is `3d/lights_and_shadows` without the icon, screenshots
  and `default_bus_layout.tres`. The scene keeps its texture and script
  references.
- `platformer/` is the `enemy` and `stage` parts of `3d/platformer`. Audio
  streams and screenshots are omitted, but `enemy.tscn` still declares them,
  so the loader must skip resource types it does not render. `stage/` is the
  ready-made GridMap landscape, with its cells and tile meshes.
- `truck_town/` is `3d/truck_town/town` with the project file and the
  `town_view.tscn` wrapper added here. The model, the trees, the lamps and the
  sky are kept as the `.scn` files Godot 4.7 imports; the raw `.gltf` sources,
  the scripts and the UI are left out.

The demo projects are MIT licensed, see `LICENSE.godot-demo-projects.md`.
`lights_and_shadows/checker.png` is CC0 by Kenney, see
`lights_and_shadows/checker.LICENSE.md`. The truck town tree and lamp models
are CC-BY 4.0 by Ricardo Sanchez and RitiWox; their `license.txt` files carry
the attribution.

## Cutout shadow

`cutout_shadow/` is not upstream: a checkered alpha-scissor quad and an opaque
box stand on one plane, so masked cutouts show up in the shadow map next to a
solid rectangle. See `cutout_shadow/README.md`.

## Generated scene

`generated/` was created with Godot 4.7 stable
(`5b4e0cb0f`) by `generated/generate.gd`. It contains:

- `procedural.tscn`, a text scene (`format=4`) with an `ArrayMesh` sub-resource
  and a non-identity `Transform3D`;
- `procedural.scn`, the same scene saved as a binary `PackedScene` (RSRC 6);
- `binary.tscn`, which references `procedural_mesh.res` to exercise the binary
  resource path;
- `procedural_mesh.res` and `procedural_mesh.tres`, the mesh alone in binary
  and text form;
- `procedural_material.tres`, a `StandardMaterial3D` with a texture and vertex
  colors.

The mesh has two surfaces. The first has positions, normals, tangents, vertex
colors, UVs and indices. The second has positions, normals and UVs only. Both
are uncompressed version 2 surfaces, so `attribute_data` holds RGBA8 colors and
float32 UVs while `vertex_data` holds positions and octahedral normals and
tangents.

`orientation.tscn` is a labelled cube used to check the coordinate system. Each
face names its own axis (`FRONT +Z`, `BACK -Z`, `RIGHT +X`, `LEFT -X`, `TOP +Y`,
`BOTTOM -Y`) and carries an up arrow, so a mirrored or rotated view is obvious at
a glance. The names are drawn into `orientation_*.png`, the labels load from the
committed `orientation_*.ctex` copies.

`orientation.gd` rebuilds the scene, no other fixture is touched:

```sh
godot --headless --path generated --import
godot --headless --path generated --script res://orientation.gd
```

To regenerate the other scenes:

```sh
godot --headless --path generated --import
godot --headless --path generated --script res://generate.gd
```

`checker.png` is copied from the lights demo; remove `generated/.godot` after a
run, it is a local import cache.

`nested.tscn` and `nested_binary.tscn` instance `procedural.tscn` and
`procedural.scn`; the PCK also contains `nested.tscn` for the nested pack test.

`checker.ctex` is an embedded-PNG `CompressedTexture2D`; `raw.ctex` is a 4x4
raw RGBA8 one. The matching `ctex.tscn` and `raw.tscn` scenes reference them
through `.tres` materials.

The compressed variants are Godot 4.7 import outputs of the ready-made lights
demo `checker.png` and `checker_normal.png` and the platformer `particle.webp`:

- `checker.s3tc.ctex` (BC1), `checker.bptc.ctex` (BC7),
  `checker.etc2.ctex` (ETC2 RGB8), `checker.astc.ctex` (ASTC 4x4);
- `checker_normal.s3tc.ctex` (BC5) for the two-channel normal map path;
- `particle.webp.ctex` (lossless WebP inside a ctex).

The `compressed_*.tscn` scenes reference them directly. ETC2 and ASTC load only
when the Vulkan device exposes those formats; otherwise the loader reports the
missing format instead of rendering an untextured mesh. `libwebp` and its development headers are
required when building pukan; the declarations are imported through ImportC.

`compressed_array_mesh.tres` and `compressed_mesh.tscn` use the ready-made
`AnimatedCube` glTF sample from the glTF sample models, imported by Godot 4.7
with mesh compression enabled. The mesh stores quantized positions, 16-bit UVs,
octahedral normals and a tangent angle instead of float attributes.

`fixtures.pck` is an unencrypted Godot 4 PCK v2 created by
`generated/pack_fixtures.py`. It contains `res://procedural.tscn`,
`res://procedural_mesh.res` and `res://checker.png`. Load it with:

```sh
./demo_godot/pukan_demo_godot --pack demo_godot/godot_samples/generated/fixtures.pck --scene res://procedural.tscn --frames 2
```

## Exported project

`exported/` is a small source project plus `exported.pck`, made with Godot 4.7
`--export-pack`. It is the only fixture that uses the production layout:

- `main.tscn`, `nested.tscn`, `panel_material.tres` and
  `procedural_mesh.tres` are customized to binary resources and referenced
  through `*.remap` files;
- `checker.png` is imported to `.godot/imported/*.ctex` and referenced through
  `checker.png.import`;
- `project.binary` supplies `application/run/main_scene`.

The pack also exposes the whole `.godot/exported` and `.godot/imported`
directories, so the loader has to follow the remaps instead of reading the
source paths. Load it without `--scene`:

```sh
./demo_godot/pukan_demo_godot --pack demo_godot/godot_samples/exported/exported.pck --frames 2
```

To regenerate after changing the source project:

```sh
cd demo_godot/godot_samples/exported
godot --headless --path . --import
godot --headless --path . --export-pack "Linux" exported.pck
```

`export_presets.cfg` only exists so the command above is reproducible. The
`checker.png.import` file is committed; without the local `.godot` cache the
loader falls back to the source PNG.

`primitives.tscn` exercises primitive subdivisions and the capsule and prism
shapes: a subdivided `BoxMesh`, a subdivided `PlaneMesh`, a `CapsuleMesh` and a
`PrismMesh` with `left_to_right`.

`shared_mesh.tscn` has five `MeshInstance3D` nodes backed by two sub-resources.
`demo_godot` reports `geometries 2`, so the vertex and index buffers are shared
even though each node keeps its own material and transform.

`enemy_twins.tscn` instances `enemy.tscn` twice. The two enemies share one
parsed `enemy.glb` asset, including its vertex buffers and textures, while each
keeps its own node transforms and joint buffers. `demo_godot` reports
`gltf assets 1`.

`platformer/platformer.pck` is a Godot 4.7 export of the platformer sample. It
contains the compressed `enemy.glb` import with `Skeleton3D` and `Skin`, so it
exercises native Godot skinning and the RSCC/Zstandard resource path:

```sh
./demo_godot/pukan_demo_godot --pack demo_godot/godot_samples/platformer/platformer.pck --scene res://enemy/enemy.tscn --frames 2
```

The enemy currently renders in its bind pose; animation tracks are not applied
yet.

## GridMap landscape

`platformer/stage/stage.tscn` is the stage of the same demo project, the
ready-made GridMap landscape: a `GridMap` scene, 18 tile meshes in a
`MeshLibrary`, a floor, seven reflection probes, a sky and a label. The loader
reads the cell grid, `cell_size`, the cell centre flags and the 24 orthogonal
rotations, then draws one node per occupied cell with the item mesh shared.

The scene places 2921 cells through a property override on the instanced
`GridMap` root; a scene placed as an instance now applies such overrides to its
root. The parts that stay unsupported are counted:

```
nodes not rendered: Label3D x1, ReflectionProbe x7, WorldEnvironment x1
resources not rendered: CompressedCubemap x1, Environment x1, Shader x1, ShaderMaterial x1, Sky x1
```

The files are upstream. `stage/meshes/*`, `stage/meshes/previews/*`, the tile
textures and `stage/collision/*` are kept; collision shapes and navigation data
are ignored for now.

```sh
./demo_godot/pukan_demo_godot --scene demo_godot/godot_samples/platformer/stage/stage.tscn --frames 2
```

Start outside the level with
`--eye 75,55,75 --target 35,5,10 --fov 60 --far 400`, then fly in with WASD.

## Landscape

`truck_town/town_view.tscn` puts the town model with five trees and ten street
lamps under a directional light, the sky of the original scene and a `Camera3D`
that frames the whole terrain. The model is a 2048 unit ground mesh with roads,
houses and a racetrack: 60930 triangles in 75 primitives and 9 materials.

Unlike the other fixtures, this one ships the imported scene rather than the
source asset. `town/model/town_model.scn`, `town/tree/scene.scn` and
`town/lamp/scene.scn` are what Godot 4.7 produces from the upstream `.gltf`
files, and that is what a game runs. The tree's `nodes/root_scale=0.01` from
`scene.gltf.import` is applied at import, so its instances keep the upstream
transforms. Only the textures stay as source `.webp`, `.jpeg` and `.png` files.

```sh
./demo_godot/pukan_demo_godot --scene demo_godot/godot_samples/truck_town/town_view.tscn --scene-camera --frames 2
```

To regenerate the three `.scn` files, copy `town/{model,tree,lamp}` together
with their `.import` files into a Godot 4.7 project, run `--headless --import`
and copy the `.scn` files out of `.godot/imported`.

The sky is kept as far as the fixture goes, but the loader does not render
`WorldEnvironment` yet, and `demo_godot` says so:

```
nodes not rendered: WorldEnvironment x1
resources not rendered: Environment x1, Material x1, Sky x1
```

Shadows are on in `demo_godot`, but the shadow frustum is a fixed 10 units
around the origin, far smaller than this map, so the terrain shows none. The
background is transparent, so the model is lit by the sun only.

## Camera

The demo opens a free camera, seeded from `--eye` and `--target` or, with
`--scene-camera`, from the scene `Camera3D`:

```
WASD         move; Shift four times faster, Alt four times slower
right mouse  look
middle mouse pan in the screen plane
wheel        zoom towards the cursor, the field of view moves between 10 and 120 degrees
Q / E        roll around the view axis
R            reset the roll
H            look axis: horizontal (level horizon) or screen (follows the roll)
```

`--speed` sets the movement speed in units per second. `--near` and `--far` set
the clipping distances; with `--scene-camera` the scene camera supplies them
instead. Runs with `--frames` or `--screenshot` stay static unless input
arrives, so their output is repeatable.
