# Godot scene fixtures

Two scenes come from the official Godot demo projects, one is generated here,
and one is a small project exported as a PCK. They cover the text scene format,
the binary RSRC format, ArrayMesh surfaces, primitive meshes,
StandardMaterial3D, external glTF scenes, skeletons and animation.

## Sources

Upstream: https://github.com/godotengine/godot-demo-projects
Commit: `b761b4cd5718a7118f2c95eb55f181d0a5f004f1` (`master`).

- `lights_and_shadows/` is `3d/lights_and_shadows` without the icon, screenshots
  and `default_bus_layout.tres`. The scene keeps its texture and script
  references.
- `platformer/` is the `enemy` part of `3d/platformer`. Audio streams and
  screenshots are omitted, but `enemy.tscn` still declares them, so the loader
  must skip resource types it does not render.

The demo projects are MIT licensed, see `LICENSE.godot-demo-projects.md`.
`lights_and_shadows/checker.png` is CC0 by Kenney, see
`lights_and_shadows/checker.LICENSE.md`.

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

To regenerate:

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

`fixtures.pck` is an unencrypted Godot 4 PCK v2 created by
`generated/pack_fixtures.py`. It contains `res://procedural.tscn`,
`res://procedural_mesh.res` and `res://checker.png`. Load it with:

```sh
./demo_godot/pukan_demo_godot --pack demo/assets/godot_samples/generated/fixtures.pck --scene res://procedural.tscn --frames 2
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
./demo_godot/pukan_demo_godot --pack demo/assets/godot_samples/exported/exported.pck --frames 2
```

To regenerate after changing the source project:

```sh
cd demo/assets/godot_samples/exported
godot --headless --path . --import
godot --headless --path . --export-pack "Linux" exported.pck
```

`export_presets.cfg` only exists so the command above is reproducible. The
`checker.png.import` file is committed; without the local `.godot` cache the
loader falls back to the source PNG.
