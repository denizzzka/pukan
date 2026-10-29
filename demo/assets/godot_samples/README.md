# Godot scene fixtures

Two scenes come from the official Godot demo projects, and one is generated
here. They cover the text scene format, the binary RSRC format, ArrayMesh
surfaces, primitive meshes, StandardMaterial3D, external glTF scenes, skeletons
and animation.

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

`checker.ctex` is an embedded-PNG `CompressedTexture2D`; `raw.ctex` is a 4x4
raw RGBA8 one. The matching `ctex.tscn` and `raw.tscn` scenes reference them
through `.tres` materials.

`fixtures.pck` is an unencrypted Godot 4 PCK v2 created by
`generated/pack_fixtures.py`. It contains `res://procedural.tscn`,
`res://procedural_mesh.res` and `res://checker.png`. Load it with:

```sh
./demo_godot/pukan_demo_godot --pack demo/assets/godot_samples/generated/fixtures.pck --scene res://procedural.tscn --frames 2
```
