# Plan

Checkboxes track progress: `[ ]` is open, `[x]` is done. Items can be done in any
order; the order below is only a suggested grouping. The one real ordering
constraint is marked in "Mesh rendering merge".

- [ ] Move `pukan/vulkan/` to a separate subpackage so `pukan.vulkan` can be
      used independently of the rest of `pukan`. Keep module names unchanged.
- [ ] Set up CI on GitHub: build the library and both demos and run them with
      the validation layers enabled.

## VkObj coverage

Needs thinking first.

- [ ] Extend `VkObj` to all Vulkan objects automatically: locate the argument
      holding the created or destroyed handle by its type rather than by its
      position in the argument list, and call the matching destructor on
      destruction.
- [ ] Cover handles that come as a static or dynamic array.
- [ ] Check whether such or similar functionality already exists in the code.

## Entity rendering and shaders

Goal: each entity declares its own technique, the pipeline is derived from that
declaration, and `Scene` stays passive. The design and the implementation steps
are below in "Render techniques and pipelines".

## Render techniques and pipelines

A technique describes what to draw; a pipeline key identifies it for a render
target. Both are values, so a drawable holds a technique id instead of a raw
`VkPipeline`. This is the machinery the "Mesh rendering merge" section needs.

### RenderTechnique

A technique is everything that determines one pipeline family, excluding the
render target:

```d
struct ShaderStage
{
    string spv;                                  // import("mesh_skinned.spv")
    VkShaderStageFlagBits stage;
    VkDescriptorSetLayoutBinding[] bindings;
    VkPushConstantRange pushConstants;
}

struct VertexStream { uint binding; uint stride; VkVertexInputRate rate = VK_VERTEX_INPUT_RATE_VERTEX; }
struct VertexAttr   { uint binding; uint location; VkFormat format; uint offset; }

struct FixedState
{
    VkPrimitiveTopology topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkCullModeFlags cull = VK_CULL_MODE_BACK_BIT;
    VkFrontFace frontFace = VK_FRONT_FACE_CLOCKWISE;
    bool depthTest = true;
    bool depthWrite = true;
    VkCompareOp depthCompare = VK_COMPARE_OP_LESS;
    bool blend = false;
}

struct RenderTechnique
{
    string name;
    ShaderStage[] stages;
    VertexStream[] streams;
    VertexAttr[] attrs;
    FixedState state;
    VkDynamicState[] dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR];
}
```

Rules:

- Store semantic values, not `Vk*CreateInfo`. Those embed pointers and `pNext`,
  so they cannot be copied into a cache or hashed. `defaults.d` also points
  `colorBlending.pAttachments` at a shared global, so copying it into techniques
  would make every technique share one mutable attachment. Build the Vulkan
  structs inside the factory, on the stack.
- Derive the descriptor set layout from `stages[].bindings` instead of storing
  it. Merge equal binding numbers and OR their `stageFlags`; reject one binding
  number with different descriptor types; aggregate pool sizes per descriptor
  type, not per binding.
- A technique is already a concrete variant: static and skinned meshes are two
  techniques. Different vertex interfaces need different SPIR-V (compile with a
  `SKINNED` define); a specialization constant does not remove a vertex input
  from the interface, and a declared binding that the pipeline does not provide
  means an extra vertex fetch at best. Use dynamic state (`frontFace`, vertex
  input) only where the difference is pure state.
- Pipeline layout is cached separately from pipelines: techniques that share
  set layouts and push constants share it.

### PipelineKey

```d
struct TechniqueId    { uint value; }
struct RenderTargetId { uint value; }   // render pass + subpass, or attachment formats

struct PipelineKey
{
    TechniqueId technique;
    RenderTargetId target;
}
```

- The key contains interned ids only, so it works as an associative array key
  without custom `toHash`/`opEquals`. Adding arrays, such as specialization
  values, would need both.
- Never hash `VkGraphicsPipelineCreateInfo`: its pointers and `pNext` chain are
  not part of the pipeline identity.
- The render target is part of the identity. Keying by attachment formats and
  subpass survives render pass recreation; keying by `VkRenderPass` requires
  clearing the cache then.
- Do not confuse this with `VkPipelineCache`, which is a driver-side binary
  cache. The factory can still pass one when creating pipelines.
- Keep specialization values in the technique, not in the key: a technique is a
  fully specified variant, so the key stays `(technique, target)`.

### PipelineFactory

```d
final class PipelineFactory
{
    private LogicalDevice device;
    private RenderTechnique[] techniques;        // id -> description
    private VkDescriptorSetLayout[] setLayouts;  // id -> derived layout
    private VkPipelineLayout[] layouts;          // id -> pipeline layout
    private GraphicsPipelineCfg[PipelineKey] cache;

    TechniqueId declare(RenderTechnique t);
    ref const(GraphicsPipelineCfg) acquire(TechniqueId id, RenderPass pass, uint subpass = 0);
}
```

`declare` merges bindings, creates the descriptor set layout and the pipeline
layout. `acquire` returns a stable reference from the cache and creates the
pipeline on a miss.

Ownership moves into the factory: shader modules, descriptor set layouts,
pipeline layouts and pipelines. Drawables keep a `TechniqueId`, never a raw
handle: a stale `GraphicsPipelineCfg` in a tree payload after cache invalidation
is a dangling handle. Destruction order: pipelines, pipeline layouts, set
layouts, shader modules, pools.

Two helpers that `PoolAndLayoutInfo` currently conflates:

- `ShaderCache` on the logical device, keyed by the SPIR-V hash plus stage.
  Verify the declared bindings and push constant range on a hit, so one module
  cannot be uploaded with two different declarations. This removes
  `initShaders!()` and the global shader variables in `Scene`.
- `DescriptorAllocator`, keyed by `TechniqueId`. A pool grows when it runs out
  instead of the fixed `maxSets` values (10, 20, 1) used today.

### Merging meshes

- `mesh.static` and `mesh.skinned` are two techniques: same fragment, two vertex
  SPIR-V, different vertex layouts, no joints or weights in the static layout.
- Both can share one descriptor set layout and one pipeline layout: binding 2 of
  the static variant points at a shared identity palette. Static draws then cost
  no extra descriptors.
- `Mesh` holds the `TechniqueId`; the instance holds the material and the
  palette. This is what lets the palette stop being baked into the mesh
  constructor.
- `frontFace` becomes a technique field: clockwise for generated geometry,
  counter-clockwise for glTF. A single pipeline would need
  `VK_DYNAMIC_STATE_FRONT_FACE` instead.

### Requirements

`Requirements!(...)` is checked before device creation, so requirements cannot
live on a runtime technique value. Declare them on the technique type or module
and aggregate with `RequirementsFor`. The set of techniques is known statically,
so a `static foreach` over the declarations can generate both the values and the
`alias requirements`.

```d
struct SkinnedMeshTechnique
{
    private alias requirements = AliasSeq!(
        Requirement!(VkPhysicalDeviceFeatures.samplerAnisotropy), // example
    );

    static RenderTechnique make() { ... }
}
```

### Pitfalls

- No `Vk*CreateInfo` or pointers in techniques or keys.
- Merge bindings across stages and reject conflicts.
- Build Vulkan structs at creation time; no shared globals in techniques.
- The factory owns everything it creates; drawables hold ids.
- Invalidate the cache when the render target changes.
- Different vertex interfaces mean different SPIR-V; specialized branches do not
  remove inputs.
- Grow descriptor pools; do not keep fixed `maxSets`.
- Add a debug counter of created pipelines and assert a cache hit on a repeated
  `acquire`.

### Steps

- [x] Add the shader cache: SPIR-V hash plus stage, declaration check, no
      duplicate modules.
- [x] Add `RenderTechnique`, `PipelineKey` and `PipelineFactory`; move glTF, the
      primitive factories and the sphere and cylinder renderers onto them without
      changing the image.
- [x] Add `DescriptorAllocator`; grow pools; move per-mesh material UBOs into one
      buffer with offsets.
- [ ] Remove `PrimitivesFactory` and `GltfFactory` as pipeline owners; make
      `Scene` passive.
- [ ] Merge the mesh paths using static and skinned techniques.
- [ ] Consider instancing and batching, including a palette offset for skinned
      instances.

## Primitive rendering

Needed soon.

- [ ] 3D lines with a thickness in pixels, for debug output.

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
