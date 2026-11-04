# HLOD rings on a fixed scene

Recorded from `demo_godot --stats`. A reference, not a target.

## Configuration

- Command: `./demo_godot/pukan_demo_godot --scene <scene> --frames 160 --warmup 40 --offscreen --stats`
- Resolution: 800x600, offscreen: no present and no vsync
- Measured: 120 frames after 40 warm-up frames, the same camera each run
- Device: software raster (`llvmpipe`), as in `baseline.md`
- Counters: what the frame submits, taken where the commands are recorded.
  The cull kernel keeps fewer instances than it receives, and the GPU count it
  writes stays on the GPU, so `instances` is the submitted count.

The demo splits loaded cells into three rings: parts nearer than
`--proxy-distance`, a merged proxy beyond it, and one captured card beyond
`--impostor-distance`.

## Platformer stage

`stage/stage.tscn`, 205 cells.

| Rings | Ring | Draws | Instances | Triangles | Frame mean | p50 | p95 |
|---|---|---|---|---|---|---|---|
| off | near | 12.0 | 347.0 | 2,162 | 14.29 ms | 14 | 15 |
| proxy 32, cards 64 | proxy | 2.0 | 2.0 | 10,187 | 14.39 ms | 14 | 16 |
| proxy 32, cards 64 | cards | 1.0 | 1.0 | 2 | 14.39 ms | 14 | 16 |

The proxy ring cuts the draws sixfold and raises the triangles fivefold: 347
small instances become two merged meshes that carry every tile of their cell,
including what per-instance culling dropped. At 800x600 on a software raster
the frame is not geometry bound, so the time does not move.

A proxy draws its merged triangle list alone: generated cluster levels leave
holes on merged geometry, where every tile keeps its own vertices.

## Truck town

`truck_town/town_view.tscn`, 143 cells.

| Rings | Ring | Draws | Instances | Triangles | Frame mean | p50 | p95 |
|---|---|---|---|---|---|---|---|
| off | near | 32.0 | 32.0 | 23,267 | 18.09 ms | 18 | 19 |
| proxy 32, cards 96 | proxy | 29.0 | 29.0 | 20,819 | 20.61 ms | 21 | 22 |
| proxy 32, cards 96 | cards | 34.1 | 34.1 | 68 | 20.61 ms | 21 | 22 |

The sample merges each material over the whole map at import: the grass mesh
alone has bounds of 2048 metres a side and is placed once, so every cell asks
for it. Cells therefore cannot cut what the town draws, and the proxy ring only
adds draws and clips of the same geometry.

## Occlusion demo, indoors

`occlusion_culling/node_3d.tscn`, 1,024 rooms in a 64 by 64 grid, 539 cells.
Upstream uses this scene to show occlusion culling and mesh LOD.

| Rings | Ring | Draws | Instances | Triangles | Frame mean | p50 | p95 |
|---|---|---|---|---|---|---|---|
| off | near | 990.7 | 990.7 | 3,646,415 | 312.25 ms | 312 | 355 |
| off | shadow | 1,015.7 | 1,015.7 | 3,804,400 | 312.25 ms | 312 | 355 |
| proxy 48, cards 128 | proxy | 1,306.2 | 1,306.2 | 4,777,358 | 447.43 ms | 422 | 576 |
| proxy 48, cards 128 | shadow | 1,253.1 | 1,253.1 | 4,689,146 | 447.43 ms | 422 | 576 |
| proxy 48, cards 128 | cards | 2.7 | 2.7 | 5 | 447.43 ms | 422 | 576 |

The rings lose here. A cell holds a handful of rooms, so merging gives one draw
per cell and material for every room in it, more draws and triangles than the
per-instance path that culling trims room by room. Cards have nothing to do
indoors. What this scene wants is the occlusion pass, not HLOD, so the rings
stay off for it.

Loading it takes about 27 seconds with the validation build, most of it the
1,024 instanced rooms.

## Generated field

`hlod_field/hlod_field.tscn`, 10 km square, 40 villages, 24,964 cells with
`--no-cells`, camera at (120, 20, 160) looking at the origin, 50 measured frames
after 90 warm-up frames.

| Rings | Ring | Draws | Triangles | Frame mean | p50 | p95 |
|---|---|---|---|---|---|---|
| off | near | 2,485.0 | 338,940 | 145.66 ms | 144 | 157 |
| off | shadow | 149.1 | 20,336 | 145.66 ms | 144 | 157 |
| proxy 300, cards 900, min 8 | near | 824.0 | 198,404 | 61.66 ms | 59 | 68 |
| proxy 300, cards 900, min 8 | proxy | 11.0 | 68 | 61.66 ms | 59 | 68 |
| proxy 300, cards 900, min 8 | shadow | 145.0 | 20,440 | 61.66 ms | 59 | 68 |
| proxy 300, cards 900, min 24 | near | 2,349.0 | 327,404 | 140.00 ms | 137 | 160 |

With `--proxy-min-parts 8` the merge takes 162 of the 24,964 cells, the dense
ones, and leaves 24,802 on the parts path. Those 162 cells are where the village
geometry sits: merging them takes the frame from 145.7 ms to 61.7 ms, the draws
from 2,485 to 835 and the submitted triangles from 338,940 to 198,472. At the
old threshold of 24 only seven cells qualify and nothing changes.

Two rules make that work. A cell below the threshold is decided once and never
merged, so the parts path keeps its per-instance culling. A cell beyond the
proxy distance without a proxy joins the near batch and draws through the cull
kernel with the rest; routing it through a draw of its own, one cell at a time,
was what made the earlier ring numbers look so bad.

Cards never trigger on the field: it is a single flat layer and the camera sees
across it.

The field also exposes two engine limits: a proxy costs a descriptor set and a
merge per cell, and the demo's streaming range is measured in metres against a
thin cell layer, so a large range enumerates hundreds of empty vertical cells.

## Occlusion on the field and the town

The coarse CPU depth grid (`--occlusion`) rasterizes the items of the near cells
as boxes and drops a part when every sample of its screen rectangle lies behind
a surface.

| Scene | Parts drawn | With the grid | Frame mean |
|---|---|---|---|
| field, dense cells | 831.8 | 783.4 (50 dropped) | 71.46 ms -> 67.51 ms |
| occlusion_culling | 994.4 | 994.4 (10 dropped) | 2182 ms -> 2205 ms |
| truck_town | 2.0 | 2.0 (none dropped) | 38.88 ms -> 38.58 ms |

A box is a poor occluder: its screen rectangle is larger than the surface it
stands for, so the grid rarely covers a part completely. The field gains 6%,
the indoor sample nothing measurable, and the town has too few near parts to
matter.

## What the numbers say

- Per-cell HLOD pays off only when a cell's geometry belongs to it. A scene
  whose meshes span the map leaves nothing to merge away, so `--proxy-distance`
  should stay off for it.
- The platformer is the better ring test, and it wants a measurement that is
  geometry bound: a larger target or a real GPU, not 800x600 on llvmpipe.
- The next scene to record should be authored per object, or the loader should
  split a merged mesh across the cells it touches.
