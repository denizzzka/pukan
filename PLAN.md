# Plan

Checkboxes track progress: `[ ]` is open, `[x]` is done. Items can be done in any
order; the order below is only a suggested grouping. The one real ordering
constraint is marked in "Mesh rendering merge".

- [ ] Deal with warnings
- [ ] Move `pukan/vulkan/` to a separate subpackage so `pukan.vulkan` can be
      used independently of the rest of `pukan`. Keep module names unchanged.

## VkObj coverage

Needs thinking first.

- [ ] Extend `VkObj` to all Vulkan objects automatically: locate the argument
      holding the created or destroyed handle by its type rather than by its
      position in the argument list, and call the matching destructor on
      destruction.
- [ ] Cover handles that come as a static or dynamic array.
- [ ] Check whether such or similar functionality already exists in the code.

## Warnings

- [ ] Collect the Vulkan validation layer warnings and fix them.

  The debug messenger in `FlightRecorder` already prints them; group the
  messages by type (object lifetime, synchronization, descriptor usage, shader
  interfaces) and fix them one group at a time. The `fix/vulkan-warnings`
  branch touches debug messenger logging and RAII cleanup and can be merged
  first.

  - [ ] `BestPractices-SpirvDeprecated_WorkgroupSize` from `demo_compute`: the
        compute shaders use the SPIR-V `Workgroup` built-in, deprecated in
        SPIR-V 1.6. Recompile with `--target-env=vulkan1.3` in
        `compile_shaders.sh` so `LocalSizeId` is emitted. Affects `gemm.comp`
        and `skin_matrices.comp`.

## Entity rendering and shaders

- [ ] Generalize rendering of different entities so each entity loads its own
      shaders.
- [ ] Make pipeline setup automatic from the same declaration.
- [ ] Remove hardcoded shader arrays from `Scene` (`vertShader`,
      `coloredFragShader`, `texturedFragShader`, ...).

Ideas:

- `ShaderInfo` already carries stage, descriptor layout bindings and push
  constants. Add a value type per drawable, for example `RenderTechnique`:
  shader modules, vertex layout (`getBindingDescriptions` /
  `getAttributeDescriptions`), descriptor set layouts, blend and depth state,
  push constant size.
- Introduce a `PipelineKey` (shader ids, vertex layout, attachment formats,
  blend/depth state) and a `PipelineFactory` that creates a pipeline once and
  returns it from a cache. Drawables ask the factory, they do not own creation
  code.
- Add a shader cache in `uploadShaderToGPU`: today every call inserts a new
  module. Key by SPIR-V binary plus stage, return the existing `ShaderInfo`.
- Keep `Scene` passive: it holds drawables and factories, not shader lists.

## Primitive rendering

Needed soon.

- [ ] 3D lines with a thickness in pixels, for debug output.
- [ ] Cylinders: surface quality, length, radius, color.
- [ ] Spheres: surface quality, radius, color.

## Geometric algebra: PGA and CGA

- [ ] Spike: evaluate adding PGA (Projective Geometric Algebra) and CGA
      (Conformal Geometric Algebra).

A seed entry: its presence should be taken into account when the other engine
components are designed and developed. PGA suits graphics better, but CGA is
sometimes needed: fractals, spheres, complex smooth surfaces (signed distance
fields).

## Mesh rendering merge

- [ ] Unify `Mesh` rendering paths after the steps above are validated.
- [ ] Validate the generalized rendering and automatic pipelines first.

This is the last step on purpose: merging mesh paths before the new
technique/pipeline machinery is proven would hide its defects.

## 2D

- [ ] 2D overlay on top of 3D: sprite/quad batch, alpha blending, orthographic
      projection, drawn after the 3D pass.
- [ ] OSD: debug text and small overlays (FPS, counters, flags).
- [ ] Menu: prefer a ready-made solution (dimgui, bindbc-imgui, GTK, ...) and
      evaluate how it integrates with the existing frame loop.
- [ ] 2D graphics under 3D: a background layer drawn before the scene.
      Evaluate whether it can be done cheaply: one fullscreen quad pass with
      depth write disabled, then the 3D pass on top.

Questions:

- Overlay via an immediate-mode library or a custom sprite batch?
- How is text rendered: font atlas, signed distance field, or the UI library?

## Automatic composition: pipelines into render passes, passes into a frame

Goal: drawables declare what they write, and the composer groups compatible
pipelines into render passes/subpasses and records one frame.

Current state: one `DefaultRenderPass`, one pipeline per factory (`GltfFactory`,
`PrimitivesFactory`), command recording done by hand in `Frame`/`FrameBuilder`.

Ideas:

1. **Dynamic rendering.** The instance already requests Vulkan 1.3
   (`makeApiVersion(0, 1, 3, 0)`). With `dynamicRendering` enabled, pipelines
   declare color/depth formats directly and a pass is just
   `vkCmdBeginRendering` / `vkCmdEndRendering`, so `VkRenderPass`,
   `VkFramebuffer` and subpass dependencies disappear. This removes most of the
   "pipeline into render pass" problem. The feature itself fits the feature
   requirement system above.
2. **Frame graph.** Passes declare reads and writes of resources; the frame is
   ordered by a topological sort; barriers are derived from those declarations;
   transient resources can alias. Stronger and more work.
3. **Simple grouping rule.** Group consecutive drawables that target the same
   attachment set; split a pass when attachments or load/store ops differ;
   insert subpass dependencies for read-after-write.
4. **Pipeline cache** keyed by `PipelineKey`, shared by all factories.

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

## Data layout and throughput

Thesis: the remaining speed is in reducing the entropy of the data that moves
through the pipeline, not in macros and not in rewriting CPU loops as compute
shaders. Fewer bytes on the bus and in the caches mean fewer misses and fewer
stalled stages; every item below is a way of sending less, or sending it in a
more predictable order.

Each item earns its place only with numbers: VRAM occupied, bytes per instance
uploaded per frame, cache misses, frame time on a fixed scene. The baseline
comes before any of them, and the quantization item is the only near-term one;
it touches the vertex layout that the pipeline work rewrites anyway. The rest
are long-term spikes, each judged against the plain version it replaces.

- [ ] Record a baseline on a fixed scene: VRAM, per-frame upload bytes, frame
      time, and the entity update time used against the archetype target.

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
