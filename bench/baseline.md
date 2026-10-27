# Baseline on a fixed scene

Recorded from the demo in `--bench` mode. This is a reference, not a target.

## Configuration

- Code: `2e61a0c` (`Add fixed-scene benchmark mode`)
- Build: `dub build -b release` in `demo`
- Command: `./demo/demo --bench --frames 300`
- Scene: fixed primitives, spheres, cylinders and 9 tracked glTF samples
- Samples: `AnimatedCube`, `Avocado`, `BarramundiFish`,
  `BoxTexturedNonPowerOfTwo`, `Fox`, `MandarinOrange`, `Palka`,
  `SimpleMeshes`, `SimpleTexture`
- Resolution: 640x640
- Warmup: 30 frames
- Measured: 270 frames
- Validation layers: off (release build)
- Device: `llvmpipe (LLVM 19.1.7, 256 bits)`

The local NVIDIA ICD fails initialization with the installed loader
(`VK_ERROR_INITIALIZATION_FAILED`), so this baseline is software rendered.
CI uses lavapipe too; GPU numbers must be recorded separately.

## Results

| Metric | Value |
|---|---|
| Device-local memory | 142,222,658 bytes (135.6 MiB) |
| Host-visible memory | 132,294,006 bytes (126.2 MiB) |
| Memory allocations | 197 |
| Upload bytes per frame | 2,496 |
| Frame time, average | 7.079 ms |
| Frame time, p50 | 7.207 ms |
| Frame time, p95 | 8.444 ms |
| Entity update, average | 0.023 ms |
| Entity update, p50 | 0.021 ms |
| Entity update, p95 | 0.035 ms |

## Notes

- VRAM is what the engine allocates through `DeviceMemory`. Swapchain images
  and driver-internal allocations are not included.
- Upload bytes are `TransferBuffer` CPU to GPU copies after warmup, mostly
  per-frame joint matrices.
- Entity update is `updateWorldTransformations` plus the drawable
  `refreshBuffers` pass. There is no ECS/archetype implementation yet, so this
  is not comparable to the 1,000,000 entities in 6 ms target; a separate
  synthetic entity benchmark is still needed for that comparison.
- The fixed scene uses only tracked glTF samples, so the result does not depend
  on untracked local assets.
