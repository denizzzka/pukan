# Plan

Checkboxes track open work. Items can be done in any order; the order below is
only a suggested grouping.

- [ ] Move `pukan/vulkan/` to a separate subpackage so `pukan.vulkan` can be
      used independently of the rest of `pukan`. Keep module names unchanged.
- [ ] Check format availability before use. `VK_FORMAT_R32G32B32_SFLOAT` and
      similar are not mandatory: query `vkGetPhysicalDeviceFormatProperties`
      (and `vkGetPhysicalDeviceImageFormatProperties` for images) instead of
      assuming the format is usable.

## Open GitHub issues

- [ ] Resolve the tracker backlog. Discuss each item before starting work.
  - [ ] #5 Add `Scene.surfaces`: support more than one surface for stereo and
        mirrors. `Scene` currently holds one `surface`; stereo uses two
        viewports on it.
  - [ ] #6 Wrap `CommandPool` into `ScopedLogicalDeviceTemplateMixin`.
  - [ ] #7 GPU-stored objects tree: keep node transforms, or at least the
        whole-tree matrices, in a GPU buffer. `Bone.translationBufferIdx` is
        unused, and only skin matrices are uploaded today.
  - [ ] #9 TODO list
    - [ ] Remove `updateDescriptorSetsAndUniformBuffers` and rely on RAII.
  - [ ] #11 glTF animation on GPU: sample and interpolate animation in a
        compute shader. Only joint matrices are computed on the GPU today.
  - [ ] #15 Add USD/USDA/USDC support.
  - [ ] #16 Add terrain support.

## Content formats

- [ ] Spike: evaluate Godot GridMap support. It stores a 3D tile map as cells on
      an integer grid with a mesh library per cell; decide whether to import that
      data as is or to grow the same cell-and-library model on top of #16.

## Geometric algebra: PGA and CGA

- [ ] Spike: evaluate adding PGA (Projective Geometric Algebra) and CGA
      (Conformal Geometric Algebra).

A seed entry: its presence should be taken into account when the other engine
components are designed and developed. PGA suits graphics better, but CGA is
sometimes needed: fractals, spheres, complex smooth surfaces (signed distance
fields).

## 2D

- [ ] 2D overlay on top of 3D: sprite/quad batch, alpha blending, orthographic
      projection, drawn after the 3D pass.
- [ ] OSD: debug text and small overlays (FPS, counters, flags).
- [ ] Object labels once the OSD exists: project an object's origin to the screen
      and draw its name there, glTF nodes and meshes first; overlapping,
      off-screen and behind-the-camera labels need their own handling.
- [ ] Menu: prefer a ready-made solution (dimgui, bindbc-imgui, GTK, ...) and
      evaluate how it integrates with the existing frame loop.

Questions:

- Overlay via an immediate-mode library or a custom sprite batch?
- How is text rendered: font atlas, signed distance field, or the UI library?

## Automatic composition: pipelines into render passes, passes into a frame

Goal: drawables declare what they write, and the composer groups compatible
pipelines into render passes/subpasses and records one frame.

Current state: one `DefaultRenderPass`; pipelines are cached by `PipelineFactory`,
command recording is done by hand in `Frame`/`FrameBuilder`.

Ideas:

1. **Dynamic rendering.** The instance already requests Vulkan 1.3
   (`makeApiVersion(0, 1, 3, 0)`). With `dynamicRendering` enabled, pipelines
   declare color/depth formats directly and a pass is just
   `vkCmdBeginRendering` / `vkCmdEndRendering`, so `VkRenderPass`,
   `VkFramebuffer` and subpass dependencies disappear. This removes most of the
   "pipeline into render pass" problem. The feature itself fits the existing
   device requirement system.
2. **Frame graph.** Passes declare reads and writes of resources; the frame is
   ordered by a topological sort; barriers are derived from those declarations;
   transient resources can alias. Stronger and more work.
3. **Simple grouping rule.** Group consecutive drawables that target the same
   attachment set; split a pass when attachments or load/store ops differ;
   insert subpass dependencies for read-after-write.

Because the goal is vague here, the questions below decide the scope:

- What does "automatic" mean: compile-time generation of passes, or runtime
  sorting of draw calls into passes?
- Which targets are needed: swapchain only, or offscreen (shadow maps, HDR,
  post-processing)?
- Is MSAA needed? A depth prepass? A separate transparent pass?
- Can the project require Vulkan 1.3 with dynamic rendering, or must it keep
  `VkRenderPass`?
- Should the 2D overlay be a separate pass after the 3D pass, or a subpass of
  the same render pass?
- Are pipelines created at scene setup or on first use?

## Materials

The shared `Material` covers simple unlit/lit shading and glTF metallic-roughness.
The following pieces are still missing:

- [ ] glTF material extensions: transmission, iridescence, volume and
      dispersion.
- [ ] Shader tiers for glTF materials. Split the uber shader into core PBR and
      extended (specular/IOR, clearcoat, sheen) variants once the benchmark shows
      register or instruction cache pressure; the branches are uniform today, so
      the gain has to be measured before the pipelines multiply.
- [ ] Alpha handling. Sort blended primitives back to front and offer
      alpha-to-coverage for masked materials.
- [ ] Shared materials. A material table so meshes and primitives can reference
      the same material instead of taking one slot per mesh.
- [ ] Multiple skins per glTF file. Stop hardcoding `skins[0]` and bind the skin
      per node and primitive.
- [ ] Texture compression. KTX2/BasisU and other compressed formats with a
      fallback path.

### Material seams and white dots

Isolated white pixels appear at texture or mesh seams with MSAA disabled. The
method:

- [ ] Reproduce on a fixed sample, camera and distance; record the sample,
      primitive and screen area.
- [ ] Set the clear/background to a distinct colour. Dots that take that colour
      are geometry gaps; dots that stay white are texture or shading.
- [ ] Disable normal maps. Dots that disappear point at the derivative TBN on UV
      seams or a missing tangent attribute.
- [ ] Compare sampler states: CLAMP_TO_EDGE vs MIRRORED_REPEAT, nearest vs
      linear, with and without mipmaps.
- [ ] Check UV islands and texture borders: sampling across an island edge can
      pull the opposite or border texel; use clamped samplers or gutters.
- [ ] Compare culling: back-face culling vs none, and check the front-face
      winding. Holes that vanish indicate reversed or missing triangles.
- [ ] Compare MSAA 1x and 4x. If the dots only blur, they are subpixel coverage
      gaps, not an MSAA defect.
- [ ] Inspect shared edges between primitives for duplicated vertices,
      T-junctions and floating-point differences; overlap or weld them.
- [ ] Check depth precision and z-fighting at coplanar seams.
- [ ] Keep the smallest fix that removes the dots without changing the rest of
      the material path.

## Data layout and throughput

Thesis: the remaining speed is in reducing the entropy of the data that moves
through the pipeline, not in macros and not in rewriting CPU loops as compute
shaders. Fewer bytes on the bus and in the caches mean fewer misses and fewer
stalled stages; every item below is a way of sending less, or sending it in a
more predictable order.

Each item earns its place only with numbers: VRAM occupied, bytes per instance
uploaded per frame, cache misses, frame time on a fixed scene. The baseline is
recorded in `bench/baseline.md`, and the quantization item is the only
near-term one; it touches the vertex layout that the mesh merge now owns. The
rest are long-term spikes, each judged against the plain version it replaces.

- **Quantized static geometry**
  - [ ] Optional extreme quantization for static batches: store positions and
        rotations in as few as 2 bits per component when the drawable is authored
        on a local grid, and decode in the vertex shader. Saves VRAM and removes
        the vertex stage's memory bottleneck; the precision budget is per batch,
        and the unquantized layout stays the default.

- **Motors instead of matrices**
  - [ ] Upload instance transforms as motors (dual quaternions, 8 floats)
        instead of `mat4` (16 floats) in the transform SSBO, which halves the
        traffic for the dynamic path.
  - [ ] Interpolate skinned animation in motor space instead of blending
        matrices, which removes the shear and scale artifacts of linear matrix
        blending.
  - [ ] Measure both against the matrix path on the same scene before making
        motors the only path.
  - Octonions are non-associative, so a chain of transforms has no well-defined
    result; they stay out unless a concrete use turns up.

- **Archetype storage instead of classic ECS**
  - [ ] Replace the classic ECS with archetype storage: one contiguous SoA
        block per archetype over flat memory, walked linearly, with no virtual
        calls.
  - [ ] Target 1,000,000 entities updated in 6 ms in one thread on the FX-9590,
        the figure already observed there, then find the ceiling.
  - The A-infinity and Grothendieck-sheaf framing describes this layout rather
    than prescribing one: a section of a sheaf over flat memory is an
    archetype, and the gluing is the archetype table. What pays off is the
    contiguity and the absent dispatch, so build that and keep the vocabulary
    for the write-up.

- **Adelic storage**
  - [ ] Spike: split one logical array into layers by access frequency and
        locality instead of keeping it contiguous, so the hot part stays in
        cache and the cold part is uploaded once.
  - [ ] Acceptance: no allocation in the frame loop and a zero-copy upload path
        to the GPU, measured against a plain SoA array. If the layered version
        does not beat SoA on the fixed scene, drop it.
  - The p-adic metric names the tiering rule; the gain, if any, comes from the
    tiering and from the upload that does not copy.

- **Closed-form shading instead of loops**
  - [ ] Remove ray marching from the absorption path: evaluate the integral in
        closed form, as a sum of modes, instead of stepping through a 3D
        texture, targeting 15 ALU instructions where 64 steps were needed.
  - [ ] Treat a loop or a branch in a fragment shader as a defect that has to be
        justified; a closed form exists more often than it looks.
  - The holonomic D-module formalism is where such a closed form comes from;
    the shader only needs the result. This item waits until there is a
    volumetric or absorptive effect in the scene to measure it on.

### Frame loop

- [ ] After archetype storage: split update, upload and record into explicit
      stages, flatten the tree into (drawable, world matrix) chunks in draw
      order, and run update and record on `totalCPUs - 1` workers with static
      chunking.
- [ ] Frame model: per-worker command pool and bump arena reset at the frame
      barrier, no allocation in the frame, per-frame fences first, per-slot
      staging for joints. The deferred destruction queue recycles its nodes
      through a shared free list.
- [ ] Keep recording in draw order so blending is unchanged; judge against the
      single-threaded path on 1k / 10k / 100k drawables and keep recording
      single-threaded until those numbers exist.

Not parallelized: present, event polling, swapchain maintenance, pipeline and
shader creation.
