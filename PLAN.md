# Plan

Checkboxes track progress: `[ ]` is open, `[x]` is done. Items can be done in any
order; the order below is only a suggested grouping. The one real ordering
constraint is marked in "Mesh rendering merge".

- [x] Value-type RAII wrapper for Vulkan objects (`VkObj` struct)
- [ ] Deal with warnings

## Feature requirements

- [ ] Build a Vulkan feature requirement system: every feature that Vulkan
      requires to be declared before first use is requested once, automatically,
      when application code uses a part that needs it.

Scope: anything requested at device creation time because a driver or GPU may
not provide it: `VkPhysicalDeviceFeatures` members, structures chained through
`VkPhysicalDeviceFeatures2`, device extensions, and version-gated features.

Current state: `LogicalDevice.this` takes a device extension list and hardcodes
`samplerAnisotropy`; `Instance.this` takes an instance extension list;
`PhysicalDevice` can already enumerate extensions and features.

### Already used in the code

Enabled today, with the intended classification:

- `samplerAnisotropy`: hardcoded and enforced in `logical_device.d`, marked with
  a TODO. Must become a requirement declared by the texture/sampler code.
- `VK_KHR_swapchain`: required by the demo, device extension.
- `VK_KHR_surface` plus the platform surface extension from GLFW
  (`VK_KHR_xcb_surface`, `VK_KHR_wayland_surface`, `VK_KHR_win32_surface`):
  optional for the library, required by the window code. The window setup throws
  when a needed extension is unavailable.
- `VK_EXT_debug_utils` and `VK_LAYER_KHRONOS_validation`: optional, debug only.
  The debug setup throws when it asks for them and they are not available.

Used but never enabled:

- `VK_EXT_vertex_input_dynamic_state`: `VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE`
  in `gltf/factory.d`. The extension and its `vertexInputDynamicState` feature
  are not requested anywhere.
- `VK_EXT_layer_settings`: `VkLayerSettingsCreateInfoEXT` is put into
  `VkInstanceCreateInfo.pNext` in `core.d`, even in release builds, while the
  extension name is commented out.
- `vkCmdBindVertexBuffers2` in `gltf/mesh.d` is core 1.3, or
  `VK_EXT_extended_dynamic_state` below 1.3; the physical device API version is
  never checked.

Version dependencies:

- The instance requests Vulkan 1.3.0 (`core.d`), but
  `findSuitablePhysicalDevice` takes device 0 without checking its version.
- `vkGetPhysicalDeviceProperties2` needs Vulkan 1.1.
- Shaders are compiled with `--target-env=vulkan1.2` (SPIR-V 1.5) although the
  GLSL is `#version 460`.

Core capabilities used without an explicit request: graphics queue, dynamic
viewport and scissor, descriptor sets, push constants, storage buffers, compute
pipelines, `VK_FORMAT_D24_UNORM_S8_UINT`, `VK_FORMAT_B8G8R8A8_SRGB`,
`VK_FORMAT_R8G8B8A8_SRGB`, present mode FIFO.

Two separate concerns:

- **Enabling** is decided before `vkCreateDevice` and cannot be changed later.
- **Checking availability** may be repeated freely. `vkGetPhysicalDeviceFeatures`
  fills the whole struct in one call, so checking many features costs one call
  and there is nothing worth caching; a cache would only add storage. What
  matters is that the check happens before the first use.

### Features as compile-time tags

A feature tag is generated from its name, so there is no struct to declare per
feature:

```d
struct Feature(string field)
{
    static assert(__traits(hasMember, VkPhysicalDeviceFeatures, field),
        "unknown feature: " ~ field);
    static assert(is(typeof(__traits(getMember, VkPhysicalDeviceFeatures, field)) == VkBool32),
        "not a VkBool32 feature: " ~ field);
}

struct Extension(string name) { }

alias Anisotropy = Feature!"samplerAnisotropy";
alias Swapchain = Extension!(VK_KHR_SWAPCHAIN_EXTENSION_NAME);
```

The string parameter gives a distinct type per feature, so `NoDuplicates`
removes repeated requests, and nothing is instantiated at runtime. For features
in the `VkPhysicalDeviceFeatures2` chain the owning struct is resolved from a
short compile-time list (`VkPhysicalDeviceVulkan11/12/13Features`, then the
extension feature structs), with a `static assert` when the name is missing or
ambiguous.

The valid names are not hardcoded either: `__traits(allMembers, ...)` yields
every `VkBool32` field at compile time (55 in `VkPhysicalDeviceFeatures` alone),
so a typo fails the `static assert` instead of silently doing nothing. The same
works for extension macros, which are compile-time strings in the bindings.

Subsystem manifests become one-liners:

```d
struct Textures { alias features = AliasSeq!(Anisotropy); }
struct Skinning { alias features = AliasSeq!(); }

alias AppFeatures = NoDuplicates!(flatten!(Textures, Skinning));
```

The application lists the subsystems it uses; the union is computed at compile
time, so `AppFeatures` is the full requirement set with no manual maintenance.

The device enables exactly that list: one `vkGetPhysicalDeviceFeatures2` call
with the pNext chain built from the tags, one device extension enumeration
(count, then fill), then a `static foreach` over the tags that sets the fields by
name through `__traits(getMember, features, name)` and collects the extension
names.

How a component states its requirement, two options:

1. **Template on the device.** `class Texture(F...)` taking
   `LogicalDevice!F` and `static assert(hasFeature!(F, Anisotropy))`. Hard
   compile-time error, but `LogicalDevice` becomes a template and every place
   that passes it (`Scene`, `Mesh`, factories, `SwapChain`) has to be
   parameterized too.
2. **Runtime bitmask on a plain device.** `new LogicalDevice(pd, AppFeatures)`
   stores the compile-time set as an immutable enum bitmask, and components
   `assert(device.has!Anisotropy)`. No type explosion, the guarantee is a debug
   assert instead of a compile error.

Start with (2), move to (1) if the assert proves too weak in practice.

Two-phase init is not needed once the union is compile-time: the full set is
known before the device exists, so there is no ordering problem to solve.

### Vulkan version as a requirement

`vkGetPhysicalDeviceFeatures2` is itself version-gated: it is core in 1.1,
otherwise it needs `VK_KHR_get_physical_device_properties2` (an instance
extension). The code already hardcodes `apiVersion = 1.3.0` in `Instance`, which
is a real requirement, so it belongs in the same system as the features.

- Compile time: `ApiVersion!(1, 3)` is a value in the requirement set, the union
  takes the maximum, and `static assert`s keep the set consistent with what the
  modules use. The baseline is 1.3.0 today, the same value `Instance` hardcodes.
  This validates the declaration, not the driver.
- Runtime: the loader version and the chosen device version are compared with
  that compile-time value, and a lower one throws with both numbers.
- Bootstrap order is version-gated too. `vkEnumerateInstanceVersion` exists since
  1.1, so obtain it through `vkGetInstanceProcAddr(null,
  "vkEnumerateInstanceVersion")`; a null pointer means a 1.0 loader. Request the
  declared minimum and throw `PukanVulkanException` when the loader is older
  instead of relying on `VK_ERROR_INCOMPATIBLE_DRIVER`.
- After picking a physical device, compare `VkPhysicalDeviceProperties.apiVersion`
  with the same minimum and throw naming the device and both versions.
- A subsystem that needs a feature from a newer version declares the dependency
  explicitly: either a higher `ApiVersion` or the extension that backports it.

```d
alias Api = ApiVersion!(1, 3);
static assert(Api >= ApiVersion!(1, 3), "pukan requires Vulkan 1.3");
```

The 1.3 baseline is not arbitrary: `vkCmdBindVertexBuffers2` in `gltf/mesh.d` is
core 1.3 unless the requirement is changed to `VK_EXT_extended_dynamic_state`.

The effective core version is the lower of the two: `min(instance, device)`. A
1.3 loader with a 1.2 GPU gives the 1.1 core instance functions but not core 1.3
device commands; a 1.2 loader with a 1.3 GPU caps the instance at 1.2, so core
1.3 still needs the backporting extension.

The version does not replace extension requirements: some functionality stays
extension-only even on the newest version, for example
`VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE` from
`VK_EXT_vertex_input_dynamic_state`.

### Required and optional features

Two ways to request a feature:

- **Required**: enabled at device creation. If the driver does not provide it,
  `vkCreateDevice` is not attempted and a `PukanVulkanException` naming the
  feature and the physical device is thrown.
- **Optional**: enabled if available, skipped otherwise. The device records what
  actually got enabled.

- [ ] Add the Vulkan-specific exception types: `PukanVulkanException` deriving
      from `PukanException`, and `PukanVulkanExceptionWithCode` holding a
      `VkResult`. Neither exists today; `PukanExceptionWithCode` is the closest
      and only fits where a `VkResult` is already available, while a missing
      feature has none. Existing throws in `pukan.vulkan` move to the new types.

An entity that can work both ways asks the device when it is created, and the
application organizes the fallback itself:

```d
alias AppFeatures = FeatureSet(
    required: AliasSeq!(SwapchainExtension),
    optional: NoDuplicates!(flatten!(Textures, Skinning)),
);

auto device = new LogicalDevice(pd, AppFeatures);

// in a sampler or texture factory:
auto info = device.has!Anisotropy ? anisotropicInfo : plainInfo;
```

`has!X` is a bit test against the immutable mask of enabled features: no Vulkan
calls, no extra storage. A subsystem that needs a feature unconditionally still
asserts `has!X` (or `static assert`s it in the template variant), which catches
a missing entry in `AppFeatures` rather than a missing driver capability.

Instance-level requirements are a hybrid: statically known ones (debug utils,
validation layer) are tags like device features, while the surface extensions
come from the windowing system at runtime (the GLFW list, see the platform case
above). Both parts are merged and checked before `vkCreateInstance`.

### Device selection and creation

- [ ] Return a `Selection!Reqs` value from the device search instead of a bare
      `PhysicalDevice`. It carries the selected device, the requirement types it
      was checked against, and the checked values (enabled features, enabled
      extensions). `createLogicalDevice` accepts only this value, so selection
      and creation cannot use different lists.

Selection and creation take requirement lists in two independent places, and
internal calls (`swapchain`, `findMemoryType`, `findSuitableQueueFamilies`) pass
an empty list. The cached device can therefore be selected against a different
list than the one used at creation, and the repeated check in
`createLogicalDevice` catches only one direction of that mismatch.

- [ ] Find more features that this system does not cover yet, beyond the list
      above.

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
