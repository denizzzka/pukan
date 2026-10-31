# Plan

Checkboxes track open work. Items can be done in any order; the order below is
only a suggested grouping.

- [ ] Move `pukan/vulkan/` to a separate subpackage so `pukan.vulkan` can be
      used independently of the rest of `pukan`. Keep module names unchanged.

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
- Is a depth prepass needed?
- Can the project require Vulkan 1.3 with dynamic rendering, or must it keep
  `VkRenderPass`?
- Should the 2D overlay be a separate pass after the 3D pass, or a subpass of
  the same render pass?
- Are pipelines created at scene setup or on first use?

## Materials

The shared `Material` covers unlit/lit shading, glTF metallic-roughness and the
`KHR_materials_*` extensions. A material that uses no extension takes a smaller
core PBR shader, and only the extended ones pay for the full shader. Skins bind
per node, so a file may use several. Still missing:

- [ ] Texture compression. KTX2/BasisU and other compressed formats with a
      fallback path.

### Transparency

Opaque, mask (through alpha-to-coverage) and blend are covered. Blended draws
store their fragments in per-pixel lists and a resolve pass sorts them by depth
before compositing, so overlapping and self-intersecting transparent meshes no
longer depend on a per-draw order. The resolve runs once before the colour copy
and again after the transmission pass, filtered by the resolved scene depth, so
glass shows blended objects behind it and blended fragments in front of glass
stay in front. Long term:

- [ ] A second bounce for stacked glass. The colour is copied once, so a pane
      behind another samples the background without the first pane. A second
      copy, layered panes with their own samples, or tracing the glass in the
      resolve would fix it.
- [ ] Depth-aware rejection inside the refraction sample. Compare the depth at
      the shifted coordinate with the glass surface and fall back to the
      unshifted one, so a silhouette does not pull in an object in front of it.
- [ ] A cheap glass mode: no refraction, dispersion, thickness or diffuse
      transmission, just a light whitish Fresnel film over the surface colour,
      as the first transmission attempt did. Per material or as a fallback when
      the scene has no colour copy.

## Retro look

Material textures are filtered today: the glTF sampler defaults, the shared
material sampler and the 1x1 fallback all ask for linear filtering and mipmaps,
so an asset authored for a low-resolution look is smoothed before it reaches the
screen.

- [ ] A retro preset that asks the samplers for `VK_FILTER_NEAREST` and
      `VK_SAMPLER_MIPMAP_MODE_NEAREST`: the defaults in `gltfSampler`, the
      material sampler in `scene.d` and `createFakeTexture1x1`, plus nearest
      level generation in the `vkCmdBlitImage` chain. A glTF sampler that names
      a filter keeps it; only the unspecified ones follow the preset.
- [ ] Leave the samplers that are not a style choice alone: IBL, the shadow
      comparison and the resolve copies stay linear, or the image breaks
      instead of turning crisp.

## Lighting

The frame carries a light list in a storage buffer: the sun, then point and spot
lights, sixteen entries in total. The sun casts a single 1024x1024 shadow map
with a normal offset and one filtered comparison; only opaque glTF meshes cast,
there are no cascades and no local-light shadows. Missing:

- [ ] Cascaded directional maps and an atlas for the local lights; the current
      map is one perspective map around the scene centre and only the sun uses it.
- [ ] Caster coverage: masked cutouts and the non-glTF primitives do not cast yet.
- [ ] A wider filter and cascade blending; the comparison is one bilinear tap today.
- [ ] Light culling by distance and screen size.

## Deferred shading

The other way to separate geometry from materials: batch geometry by pipeline
alone and resolve the material in a second pass. A different frame shape, not a
better draw path, and it comes after the forward batch path has been measured.

- [ ] A G-buffer pass: depth, normal, UV, base color and a material id per pixel,
      written by every opaque drawable with the same pipeline.
- [ ] A shading pass that reads the G-buffer and applies the material its id
      points at, sampling textures through the same descriptor array the forward
      path needs.
- [ ] Keep alpha-blended and transmissive materials on a forward path, and
      decide whether masked ones go to the G-buffer.
- [ ] Judge it on the fixed scene against the forward palette and texture
      indexing: the deferred path pays MRT bandwidth and a full-screen pass, and
      on llvmpipe it is expected to lose. It earns its place only if the draws
      or the overdraw it removes outweigh that.

## Temporal antialiasing

Per-pixel shading aliases over time: a specular highlight or a Fresnel rim one
pixel wide jumps between pixels as the camera or the object moves, and MSAA
cannot fix it because MSAA averages coverage, not shading. The black helmet's
ridges show it as white dots that come and go at half a turn. Jittering the
projection and accumulating frames averages those pixels out, which no
per-pixel fix can do. It also smooths edges beyond 4x MSAA, and the history
buffer is what screen-space reflections, temporal shadows and upscaling would
need later.

- [ ] Jitter the projection by a subpixel offset per frame, cycling a fixed
      sample pattern; undo the jitter for picking.
- [ ] Keep a history colour buffer and reproject it with the previous
      view-projection.
- [ ] Reject history where depth or the normal moved, and clamp it to the
      current neighbourhood so moving objects do not ghost.
- [ ] Resolve between the surface pass and the colour copy, so transmission
      still samples an antialiased image.
- [ ] Judge it on the fixed scene against 4x MSAA without TAA: the aliasing it
      removes, the ghosting it adds, and its cost on llvmpipe.

## Data layout and throughput

Thesis: the remaining speed is in reducing the entropy of the data that moves
through the pipeline, not in macros and not in rewriting CPU loops as compute
shaders. Fewer bytes on the bus and in the caches mean fewer misses and fewer
stalled stages; every item below is a way of sending less, or sending it in a
more predictable order.

Each item earns its place only with numbers: VRAM occupied, bytes per instance
uploaded per frame, cache misses, frame time on a fixed scene. The baseline is
recorded in `bench/baseline.md`, and the quantization and instancing items are
the near-term ones; the first touches the vertex layout that the mesh merge now
owns, the second the draw path. The rest are long-term spikes, each judged
against the plain version it replaces.

- **Instanced static primitives**
  - [ ] Batch any mesh that shares vertex and index buffers, pipeline variant
        and texture set into one instanced draw, not glTF primitives only: the
        loader is the first producer, not the boundary. The transform moves from
        the push constant into an instance buffer, and the material becomes a
        palette the fragment shader indexes by the instance instead of a
        descriptor set per mesh. One batch carries one texture set, so materials
        with different textures split it. The sphere and cylinder renderers
        already issue instanced draws from compute-built commands and stay as
        they are.
  - [ ] Skinned meshes join the same batch while they share a pose, which is one
        joint matrix buffer: the shader applies the instance transform after
        skinning, so a crowd in lockstep costs one draw. Different poses split
        into batches, each still instanced.
  - [ ] Drop the texture set from the batch key: index textures from the
        material through one descriptor array sampled with
        `descriptorIndexing`, and store image and sampler indices in the
        material. Bounded by the after-bind descriptor limits and by the
        per-material sampler state; do it after the palette, when batches still
        split on textures.
  - [ ] Measure on the iridescence grid: 346 primitives over two geometry sets,
        343 nodes differing only in translation and material. One llvmpipe draw
        costs about 0.11 ms whatever the triangle count, so the grid spends
        29 ms of its 32 ms there; with one draw the target is the shader and
        setup that remain, about 14 ms.

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

## Pipeline cache

A run recompiles every pipeline: `createGraphicsPipelines` and
`createComputePipelines` pass a null `VkPipelineCache`, and `PipelineFactory`
keeps its own map only for the lifetime of the process. Persisting the driver
cache is what turns a warm start into a few milliseconds per variant.

- [ ] An abstract store of the cache blob, so the backend is a choice:
      `load(identity)`, `save(identity, data)` and a manifest of the variants it
      holds, which the caller walks to drive a progress bar. The implementation
      writes files under the user's cache directory; the file system page cache
      already keeps a warm read in RAM, so no separate in-process copy is
      planned.
- [ ] The header stores the `pipelineCacheUUID` from
      `VkPhysicalDeviceProperties` and compares it on load. The driver blob
      carries the same UUID in `VkPipelineCacheHeaderVersionOne` and the
      implementation must ignore a blob that does not match, but it does so
      silently with `VK_SUCCESS`: `VK_ERROR_INVALID_PIPELINE_CACHE_DATA` is only
      a reserved slot of a disabled extension, so the check has to be ours.
      Vendor and device ids are not duplicated, because the UUID implies both.
      Progress counts variants from the manifest, whatever the store keeps on
      disk.
- [ ] The manifest keys a variant by what `PipelineKey` already holds
      (technique and render target) plus the creation state around it:
      specialization constants, vertex input, dynamic state and formats. Shader
      bytes stay out of the key, because the driver keys its own entries by the
      SPIR-V it is handed: a recompiled shader becomes a driver miss and a
      compile. Hashing shaders here would start a shader cache, and none is
      planned.
- [ ] Every pipeline variant carries a `needsRecompilation` flag, set when the
      variant has to be compiled instead of taken from the cache: its record is
      missing or loading the record threw. Nothing clears it: a variant is
      created once per run, so the flag stays as the mark that this run compiled
      it.
- [ ] A load exception is caught where the variant is requested: its record is
      invalidated, the flag is set, and the pipeline is created again, which
      compiles it and writes a fresh record. If the flag is already set when the
      exception arrives again, the one retry has already happened, so the
      exception is rethrown instead of looping. A driver blob has no operation
      that removes a single entry, so invalidating one variant means one cache
      per variant rather than one per device; the spike prices the driver-side
      sharing that costs.
- [ ] A cached file is accepted only when four values agree: the container
      format version, the `pipelineCacheUUID`, pukan's version and the payload
      length. The header starts with a magic and the format version, and only
      then the UUID, pukan's version and the length, so a future layout change
      is recognized before any other field is read; the format version has to
      come first precisely because the rest of the layout depends on it. A file
      that fails any of the four is not used silently: loading a cached pipeline
      throws `PipelineCacheLoadException`, so the caller sees a stale or
      half-written file instead of a cold start that looks normal. The length is
      only a cheap way to notice that something is off, not a guarantee: it
      catches an obviously truncated file and nothing subtler.
- [ ] pukan's version and the container format version are part of the file
      name as well, so an upgrade starts a fresh directory instead of reading a
      blob an older library wrote. The variant key records what a pipeline is,
      not how this library assembles the creation info, so a change in that code
      would otherwise stay invisible.
- [ ] Files hold the driver blob and the header as raw bytes, with no portable
      encoding: they are only read back on the machine that wrote them and
      executed by the same driver. A different byte order or struct layout
      breaks the fields themselves, and the four checks then reject the file,
      which forces a recompile instead of letting a wrong pipeline through.
- [ ] Create each `VkPipelineCache` when its variant is first requested, seed it
      through `VkPipelineCacheCreateInfo.initialData` from that variant's file,
      and write it back with `vkGetPipelineCacheData` once the pipeline is
      created, on a worker, never inside the frame.
- [ ] Assert in the test build that a cached variant loads with no error from
      the driver: every `VkResult` is checked along the way. The assertion is
      only insurance, because the algorithm is meant to be reliable by itself;
      nothing after it may run on a wrongly loaded or missing pipeline, so the
      variant either yields a valid handle or trips the assert.
- [ ] Measure cold and warm starts of the fixed scene: the warm run's time in
      `vkCreateGraphicsPipelines` against the whole startup.

## Shader preloading

Long term: every glTF pipeline variant is built when the factory is created,
whether the loaded scene draws it or not, while a streaming scene needs the
opposite. The scene should be able to name the shaders and pipeline variants it
will use before the first frame, so a loader can warm them while the scene loads
and no first draw stalls on a compile.

- [ ] A scene query that collects the shader and pipeline variants the loaded
      materials, lighting modes and passes need, without creating them.
- [ ] Preload the reported set on a worker and make the first use wait on a
      fence instead of compiling inside the frame.
- [ ] Keep the on-demand path as a fallback for materials that appear after the
      query.

## OpenXR

The most distant item: VR owns the frame shape, so it waits until the renderer
and the scene are settled. The stereo path and `Scene.surfaces` (#5) are the
groundwork.

- [ ] Session on the existing Vulkan device, an eye swapchain the compositor
      owns with the window as a mirror, and the per-eye pose and projection from
      `XrView` instead of the demo's fixed stereo views.
- [ ] Fall back to the window path when no runtime is installed.
