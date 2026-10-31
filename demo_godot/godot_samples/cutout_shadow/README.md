# Cutout shadow fixture

A small scene written for this repository, not an upstream Godot demo. It
shows alpha-tested geometry in the sun's shadow map.

The vertical quad uses `cutout.png`, a checker texture with transparent holes,
as an alpha-scissor material (`transparency = 2`). The box next to it is
opaque. Both stand on the same plane, so the box casts a solid rectangle while
the quad casts the checker pattern. Before masked cutouts were supported, the
quad was skipped by the shadow pass and left no shadow at all.

Run it from the repository root:

```sh
./demo_godot/demo_godot --scene demo_godot/godot_samples/cutout_shadow/cutout_shadow.tscn --scene-camera --frames 30 --screenshot /tmp/cutout-shadow.png
```

Add `--no-shadows` to compare: the plane stays clean. `--screenshot` is only
needed to save the frame; without it the scene runs in a normal window.

The quad is drawn in the shadow pass through the `Godot mask shadow` pipeline.
Its fragment shader (`mesh_shadow_mask.frag`, built as
`mesh_shadow_mask_frag_godot.spv`) samples the base color texture and discards
texels below the material's alpha cutoff, using the same formula as the forward
masked pass. The glTF loader uses the same shader without `GODOT_MATERIAL`.
