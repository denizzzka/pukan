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
| off | near | 12.0 | 347.0 | 2,162 | 14.32 ms | 14 | 15 |
| proxy 32, cards 64 | proxy | 2.0 | 2.0 | 10,187 | 14.12 ms | 14 | 15 |
| proxy 32, cards 64 | cards | 1.0 | 1.0 | 2 | 14.12 ms | 14 | 15 |
| proxy 1 | proxy | 3.0 | 3.0 | 10,403 | 14.25 ms | 14 | 16 |

The proxy ring cuts the draws twelvefold and raises the triangles fivefold:
347 small instances become three merged meshes that carry every tile of their
cell, including what per-instance culling dropped. At 800x600 on a software
raster the frame is not geometry bound, so the time does not move.

## Truck town

`truck_town/town_view.tscn`, 143 cells.

| Rings | Ring | Draws | Instances | Triangles | Frame mean | p50 | p95 |
|---|---|---|---|---|---|---|---|
| off | near | 32.0 | 32.0 | 23,267 | 18.23 ms | 18 | 21 |
| proxy 32, cards 96 | proxy | 29.0 | 29.0 | 19,956 | 20.36 ms | 20 | 22 |
| proxy 32, cards 96 | cards | 34.1 | 34.1 | 68 | 20.36 ms | 20 | 22 |

The sample merges each material over the whole map at import: the grass mesh
alone has bounds of 2048 metres a side and is placed once, so every cell asks
for it. Cells therefore cannot cut what the town draws, and the proxy ring only
adds draws and clips of the same geometry.

## What the numbers say

- Per-cell HLOD pays off only when a cell's geometry belongs to it. A scene
  whose meshes span the map leaves nothing to merge away, so `--proxy-distance`
  should stay off for it.
- The platformer is the better ring test, and it wants a measurement that is
  geometry bound: a larger target or a real GPU, not 800x600 on llvmpipe.
- The next scene to record should be authored per object, or the loader should
  split a merged mesh across the cells it touches.
