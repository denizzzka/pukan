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

### Godot 4 scenes

Goal: load Godot 4 3D scenes from source projects and from packed production
builds, a `.pck` or an exported directory. Godot 3 is out of scope. Code lives
in `source/pukan/godot_scene/`; shared PBR pieces move to
`source/pukan/pbr/`.

Formats in scope: `.tscn`, `.tres`, `.escn` (text), `.scn`, `.res` (binary
RSRC 5/6), `.ctex` (CompressedTexture2D), imported `.glb`/`.gltf`/`.obj`
references, and `.pck` archives. `res://` resolves inside the project directory
or the pack.

#### Shared PBR groundwork

- [x] Extract `PbrPipelines`, `PbrMesh`/`MeshGeometry` and the shared
      `PbrFactory`; glTF and Godot both use them.
- [x] Add vertex colors to the PBR path: a color vertex stream with a white
      fallback, `fragColor` in `mesh_pbr*.vert`, `COLOR_0` in glTF and `COLOR`
      in Godot surfaces. glTF allows `COLOR_0`; the loader never implemented
      it. This is a gap in pukan, not a format requirement.
- [x] Add a static `GODOT_MATERIAL` shader variant for Godot's separate
      metallic and roughness maps, channel selectors and UV1 transform. Sample
      the maps directly; do not repack textures on the CPU.
- [x] Extend `Material` with the fields the Godot variant needs and keep the
      glTF layout working.

#### Phase 1: text scenes, static geometry and materials

- [x] Text parser for `gd_scene`/`gd_resource`: tags, ext/sub resources, nodes,
      properties, typed arrays, dictionaries, `SubResource`/`ExtResource`,
      base64 `PackedByteArray` (format 4).
- [x] `res://` resolution from `project.godot` and external text resources and
      textures.
- [x] External `.glb`/`.gltf` `PackedScene` references through the glTF loader.
- [ ] External `.obj` references.
- [x] `ArrayMesh` decoder for uncompressed version 2 surfaces: separate
      position, normal and tangent regions in `vertex_data`, interleaved
      `attribute_data` and `skin_data`, octahedral normals and tangents, RGBA8
      colors, float32 UVs and 16/32-bit indices.
- [x] Attribute-compressed surface decoding: quantized positions, 16-bit UVs
      and a TBN axis-angle pair, which gives both the normal and the tangent.
- [x] Surface format version 1 conversion for files saved by Godot 4.0 and 4.1.
- [x] Primitive meshes: `BoxMesh`, `SphereMesh`, `CylinderMesh`,
      `CapsuleMesh`, `TorusMesh`, `PlaneMesh`, `QuadMesh` and `PrismMesh`.
- [x] Primitive subdivisions, and the exact `CapsuleMesh` and `PrismMesh`
      shapes.
- [x] `MeshInstance3D`: node tree, `transform`, `visible`, mesh and
      per-surface materials.
- [x] `MeshInstance3D`: `cast_shadow` modes and load-time `material_override`
      and `surface_material_override/N`.
- [x] `MeshInstance3D`: shared mesh geometry within a scene.
- [ ] `MeshInstance3D`: material instances.
- [x] `StandardMaterial3D` and `ORMMaterial3D`: albedo, metallic, roughness,
      emission, normal, AO, transparency, alpha scissor, cull mode, unshaded
      and vertex colors.
- [x] Separate metallic and roughness maps, channel selectors and UV1
      scale/offset in the Godot shader variant.
- [x] Textures from `.png`, `.jpg`, `.webp`, `.tga` and `.hdr` through the
      existing image loader; `.ctex` belongs to phase 3.
- [x] Per-material sampler state: read `texture_filter` and `texture_repeat`
      from `BaseMaterial3D` and bind a matching `VkSampler`. One linear repeat
      sampler used to bleed green texels into the platformer cube seams, where
      the material asks for nearest and clamp.
- [x] `GodotScene : DrawableByVulkan`: draw phases, blend sorting, shadow
      phase, AABB and name.
- [x] `GodotScene`: runtime material override.
- [x] First vertical slice: `ArrayMesh`, `StandardMaterial3D`, a PNG texture
      and vertex colors render through `GodotFactory` in `demo_godot`.
- [x] Fixtures and the `demo_godot` app, see below.

#### Demo

- [x] New `demo_godot` subpackage: a minimal window, camera and scene loader,
      separate from the glTF arena in `demo`.
- [x] A `--scene` path option that loads one fixture at startup.
- [x] `--pack` to load a `res://` scene from a PCK; without `--scene` it uses
      `application/run/main_scene` from `project.binary`.
- [x] `--screenshot path` and `--screenshot-frame N` in both demos; the engine
      saves the next rendered frame through `Scene.captureFrame`.
- [ ] A screenshot key (`PrintScreen`) in `demo_godot`: capture the current
      frame and write the loaded scene path, the active render flags and the
      full camera state (position, orientation, `lookAxis`, FOV, near and far
      planes) into the PNG as `tEXt`/`iTXt` metadata, so the view can be
      reproduced exactly and two frames compared later.
- [x] A light render switch for `demo_godot`: draw every surface in the plain
      lit mode, without transmission, transparency or the authored material
      variants. Shadows keep their own switch.

#### Phase 2: lights, cameras and environment

- [x] `DirectionalLight3D`, `OmniLight3D` and `SpotLight3D` to the `Scene`
      light list; add a `Scene.setSun` path for the directional one.
- [x] `Camera3D` exposed on the loaded scene; the demo decides whether to use
      it.
- [x] `WorldEnvironment`, `Environment` and `Sky`: background colour, sky
      gradient, ambient tint, exposure and tonemap modes. Parsed in
      `godot_scene/environment.d`; AgX currently falls back to ACES. IBL
      regenerated from the sky, fog, SDFGI and volumetrics stay unsupported.
- [ ] Layers, visibility ranges and `cast_shadow` modes.
- [x] Size the sun's shadow map to the loaded scene: `demo_godot` fits an
      orthographic frustum to the scene AABB. `SunShadow` owns the pass, the
      per-frame maps, the sampler and the cache. Cascades stay a separate item
      in `## Lighting`.

#### Phase 3: binary resources and packed production projects

The end goal is a game exported by Godot, not only a source project.

- [x] RSRC 5/6 reader: string table, external and internal resource tables, the
      variant encoding and resource properties.
- [x] `PackedScene._bundled` decoder for binary `.scn`.
- [ ] `PackedScene` base scenes and child index ordering.
- [x] `.import` remap, exported `.remap` chains and `project.binary`.
- [ ] Read the glTF import settings next to a source asset: at least
      `nodes/apply_root_scale` and `nodes/root_scale`, which is what makes the
      town tree stand at the right size, plus `nodes/use_name_suffixes` and
      `materials/extract` when a project relies on them.
- [x] `.pck` v2-v4 reader, unencrypted, with a `GodotSource` abstraction shared
      by directory and pack sources.
- [ ] Stream or memory-map pack files instead of loading the whole archive.
- [x] `.ctex` textures: embedded PNG and raw `DATA_FORMAT_IMAGE` for RGBA8,
      RGB8, RG8, R8, LA8 and L8, with mip chains uploaded directly.
- [x] `.ctex` WebP and VRAM-compressed formats (BC, ETC2, ASTC) through
      `pukan.compressed_texture`, with device feature checks and sRGB or linear
      sampling per material slot. Basis Universal stays unsupported.
- [x] Binary `.res` materials and meshes.
- [x] Compressed `RSCC` resources with Zstandard blocks, `StringName`
      variants and `PackedScene` parent-path flags.
- [x] Text scenes and binary resources both store `Basis` rows; the loader
      used to read text rows as columns and so produced the transpose rotation.
- [x] Godot content renders upright: both apps project through
      `vulkanPerspectiveMatrix` and the front face comes from the source winding
      and the mirrored flag of the transform chain.
- [x] Shared parsed glTF content and GPU buffers across instances of one file;
      node trees, animation state and joint buffers stay per instance.
- [ ] Resource deduplication across a scene.
- [x] Packed project fixture exported with Godot 4.7 and checked in.

#### Phase 4: instances, skinned meshes and animation

- [x] Nested text and binary `PackedScene` instances, including packs.
- [ ] Instance property overrides and editable children.
  - [x] Properties on the instanced root, which is how the platformer stage
        replaces the `data` of its `GridMap`.
  - [ ] Children addressed by `parent_id_path` and `index`.
- [ ] `MultiMeshInstance3D` and `MultiMesh`.
- [ ] Native Godot skinning, broken down:
  - [x] Fixture reconnaissance: export `platformer/` as a PCK and confirm the
        importer output (`Skeleton3D`, `Skin`, `ArrayMesh` skin data).
  - [x] Read `Skin`: `bind_count`, `bind/{i}/bone`, `bind/{i}/name`,
        `bind/{i}/pose`; fall back to name lookup for named skins.
  - [x] Read `Skeleton3D`: `bones/{i}/name`, `parent`, `rest`, `enabled`,
        `position`, `rotation`, `scale` and `bone_meta`; ignore metadata.
  - [x] Resolve `MeshInstance3D.skin` and `MeshInstance3D.skeleton` NodePaths and
        default an empty `skeleton` to the parent `Skeleton3D`.
  - [x] Compute rest and pose bone transforms through the bone hierarchy,
        honoring `enabled`; derive joint matrices from the skin's `pose` and
        `bone`.
  - [ ] CPU skinning fallback for devices without the GPU path.
  - [x] GPU path: one joint matrix buffer per skin, bound through
        `MATERIAL_JOINTS`; the imported enemy renders in its bind pose, upright
        and oriented like Godot's own render.
  - [ ] `BoneAttachment3D`: resolve `bone_name`/`bone_idx` and apply the bone's
        global pose to the node and its children.
  - [ ] `AnimationPlayer` and `Animation`: decode `AnimationLibrary`,
        `AnimationPlayer` and `Animation`; sample transform tracks, `autoplay`
        and looping, and drive skeleton poses per frame.
  - [ ] Verify the walk animation against the glTF path.
  - Note: `enemy.tscn` overrides `bones/N/...` on an instanced child, so native
    skinning needs instance property overrides to reach feature parity.
- [ ] Animation of material and node properties.

#### Coordinate system

Both apps project through `vulkanPerspectiveMatrix`, which flips the Y row that
dlib's OpenGL projection leaves alone, so the image is upright and models keep
their authored orientation. The glTF path no longer mirrors models, and
`flipWinding`/`setFlipWinding` are gone, so a nested instance needs no special
case.

Winding follows the data instead of a flag. Godot's glTF importer stores
clockwise triangles while a raw glTF file keeps counter-clockwise ones, and
Vulkan's Y-down clip space adds one more flip, so `Mesh.applyFrontFace` takes
both the source winding and whether the transform chain mirrors. The draw paths
assert that a mesh is never shared between two different handedness values.

- [x] One projection helper for `demo`, `demo_godot` and the shadow pass.
- [x] Drop the glTF model mirror together with `flipWinding`, and derive the
      front face from the transform chain.
- [x] Put both camera defaults in the same Y-up world; window size and far plane
      still differ.
- [x] Verify `demo`, `orientation.tscn`, `lights_and_shadows`, `enemy_twins` and
      the exported enemy, from both camera sides.
- [x] Replace `lookAtMatrix` with a camera transform whose inverse is the view
      matrix, the way Dagon uses `invAbsoluteTransformation`:
      https://github.com/gecko0307/dlib/pull/192#issuecomment-2835001161
      `demo`, `demo_godot`, the stereo pair and the shadow light all build a
      view from eye, target and up and assert when that view is parallel to the
      up vector. A `Camera3D` node and a directional light already carry a
      transform to invert, so the eye and target pair only has to exist for the
      command line.

#### GridMap

- [x] Spike: evaluate Godot GridMap support. It stores a 3D tile map as cells on
      an integer grid with a mesh library per cell; the packed cells and the
      `MeshLibrary` are read as they are.
- [x] Add `platformer/stage/stage.tscn` as the GridMap landscape fixture: the
      ready-made stage of the same demo project, with its `grid_map.scn`, the
      `MeshLibrary` and the tile meshes. Only the floor renders so far, and the
      report names `GridMap` and `MeshLibrary`.
- [x] Render the landscape from cells: decode the packed cell triples, the
      `cell_size` and centre flags, the 24 orthogonal rotations and the
      `MeshLibrary` items, and draw one node per occupied cell with the item
      mesh shared. The stage renders 2921 cells; collision shapes and navigation
      data stay out.
- [ ] The stage's sky, reflection probes and script stay unsupported and
      counted.

#### Compatibility policy

- [ ] Unknown nodes and resources: count and report them for now, never crash.
      Before production support is called done, enumerate every type used by
      the supported projects and either implement it or record why it is
      dropped. Remove the silent skip at that point.
- [ ] `ShaderMaterial`, CSG, particles, decals, GI probes, fog volumes,
      SkeletonIK and custom scripts stay out until a project needs them.
- [ ] Encrypted `.pck` archives stay out.

#### Fixtures

Fixtures live in `demo_godot/godot_samples/`.

- [x] `lights_and_shadows/test.tscn` from the Godot demo projects: text scene,
      primitives, `StandardMaterial3D`, textures and lights.
- [x] `platformer/enemy/enemy.tscn` plus `enemy.glb`: external `PackedScene`,
      skeleton and animation.
- [x] `platformer/enemy/enemy_twins.tscn`: two instances of `enemy.tscn` with
      one shared glTF asset and independent node and joint state.
- [x] `platformer/platformer.pck`: a Godot 4.7 export with the RSCC imported
      `enemy.glb`, `Skeleton3D` and `Skin`.
- [x] `platformer/stage/stage.tscn`: the ready-made GridMap landscape with its
      `grid_map.scn`, 20 tile meshes and textures; counted until cells render.
- [x] Generated `procedural.tscn`, `.scn` and `.res` with two uncompressed
      `ArrayMesh` surfaces, built by Godot 4.7 headless.
- [x] Generated `binary.tscn` referencing the binary `.res` mesh, and a binary
      `.scn` scene loaded through `demo_godot`.
- [x] Generated `fixtures.pck` with a text scene and texture, loaded through
      `GodotSource` and `--pack`.
- [x] Generated `ctex.tscn` and `raw.tscn` covering embedded PNG and raw RGBA8
      `.ctex` textures.
- [x] Generated `compressed_*.tscn` from the lights-demo checker and the
      platformer particle: BC1, BC7, ETC2, ASTC, BC5 normals and lossless WebP.
      ETC2 and ASTC need device support.
- [x] Generated `nested.tscn` and `nested_binary.tscn` instancing text and
      binary PackedScenes, checked through a PCK as well.
- [x] Generated `primitives.tscn` with subdivided box and plane, a capsule and
      a prism.
- [x] Generated `shared_mesh.tscn`, where five nodes share two geometries.
- [x] Generated `orientation.tscn`, a labelled cube whose faces name their own
      axis and carry an up arrow, for checking the coordinate system.
- [x] `exported/exported.pck`, a Godot 4.7 `--export-pack` build with `.remap`
      chains, an imported `.ctex`, binary resources and `project.binary`.
- [x] Generated `external.tscn` with an external `.tres` mesh, an external
      material and both override forms.
- [x] `compressed_array_mesh.tres` and `compressed_mesh.tscn`, produced by the
      glTF importer from the AnimatedCube sample with mesh compression enabled.
- [x] `truck_town/town_view.tscn`, a 2048 unit landscape with terrain, roads,
      houses, trees, street lamps and a sky. It ships the `.scn` that Godot 4.7
      imports from the upstream `.gltf`, because a game runs the imported
      scene; only the textures stay as source files.
- [ ] Interior fixture: a room assembled from CC0 Kenney furniture with omni
      lights and a camera, to test many small glTF instances and indoor light
      falloff.
- [ ] `combined.tscn` instancing `lights_and_shadows/test.tscn`,
      `platformer/enemy/enemy.tscn` and `generated/procedural.tscn` in one
      scene, for composition checks. Godot cannot reference resources across
      projects, and each fixture is its own project today, so this needs:
  - [ ] one Godot project for the combined scene: either promote
        `godot_samples/` to a single project and prefix every fixture `res://`
        path, or add a `combined/` project that owns rewritten copies;
  - [ ] rewrite the fixture-internal `res://` references and re-check their
        `.import` and `.pck` fixtures;
  - [ ] one camera and a far plane that covers the placed instances, and a
        decision about the lights demo's 20 lights against `maxLights = 16`;
  - [ ] verify that each part renders, that shared geometry and glTF assets are
        counted once, and that the skipped counters aggregate;
  - [ ] README and fixture list.
- [x] README with source URLs, commit, licenses and the regeneration script.

## Mover

Goal: a modular movement system built on Unreal Engine Mover, with the feature
completeness of CMC's default character set and the API clarity of Godot's
`CharacterBody3D`. The core is actor-type and shape agnostic: any root scene component,
any up axis, a capsule, box, sphere, cylinder or no collision at all. A capsule belongs
only to the optional default character set, which is the first target. Mover replaces the
CMC monolith with composable modes, transitions and modifiers; CMC only supplies the
features to match. Networking is a separate, later backend, see `## Networking`.

From Godot:

- a kinematic body and a `moveAndSlide()` collision utility that resolves the slide; the
  active mode chooses when to call it and with which shape and velocity;
- explicit `isOnFloor`/`isOnWall`/`isOnCeiling`, floor normal and angle, `upDirection`,
  `floorSnapLength`, `floorMaxAngle`, `maxSlides`, `safeMargin`, `motionMode`;
- moving platform velocity, floor locking and last-collision results.

From Unreal CMC (feature reference):

- movement modes: walking, falling, flying, swimming, custom;
- acceleration, braking, ground friction, air control and gravity scale;
- jump velocity, jump hold time and multiple jumps;
- step-up height, floor sweep distance and walkable floor angle;
- orient rotation to movement, crouch with a height change;
- root motion for dashes, knockbacks and scripted moves;
- per-hit blocking results and debug visualization.

From Unreal Mover (architecture):

- modular movement modes with explicit hooks instead of one large update function;
- transitions between modes as first-class rules;
- layered moves and movement modifiers, so flight, vehicles, ladders and custom movement
  compose instead of branching;
- data-driven mode configuration, so a game adds a mode without editing the controller;
- input command structs owned by the project, with no built-in keyboard, mouse or gamepad
  handling;
- actor-type and shape agnostic: any root scene component, optional collision and any up
  axis.

Expect more project-side code than CMC: the engine supplies the simulation and the
command contract, not a binding system.

### Shape and the default character set

Mover is actor-type and shape agnostic. CMC requires an `ACharacter` and a capsule; the
core here does not. A capsule is the default for the character preset, not a rule of the
Mover core.

- [ ] `MoverComponent` works with any root scene component, including a non-primitive
      one, and with no collision at all.
- [ ] `BodyShape` covers capsule, box, sphere and cylinder, plus `none`. Modes declare
      which shapes they support, so a car or a projectile uses the same core.
- [ ] The up axis is configurable per body; the default character set assumes Z up and a
      vertical capsule, like CMC.
- [ ] The default character set is an optional preset: capsule plus walking, falling,
      flying and swimming, matching CMC behavior for humanoids.
- [ ] Other presets (vehicle, projectile, quadruped, flying pawn) assemble modes without
      the character set and without a capsule.

### Movement modes as modules

- [ ] `MovementMode` is an interface with hooks such as `onGenerateMove` and
      `onSimulationTick`, not a switch inside one update function. Walking, falling,
      flying, swimming and custom are separate modules.
- [ ] Modes declare the shared settings they need (walkable slope, gravity, speeds);
      `MoverComponent` deduplicates them, so walking and falling read one instance.
- [ ] `walking`: ground friction and gravity maintain floor contact; vertical velocity
      is clamped while grounded, so the body cannot launch itself from a slope. Step-up,
      floor snap and walkable floor angle apply. Leaving the floor switches to `falling`.
- [ ] `falling`: gravity plus air control; horizontal input is scaled by `airControl`.
      Landing switches back to `walking`, and a jump leaves the ground without an
      intermediate falling frame.
- [ ] `flying`: no gravity by default, free 3D acceleration and braking, optional
      vertical input and no floor state. Useful for noclip, spectating and jetpacks.
- [ ] `swimming`: reduced gravity, fluid friction and buoyancy, with an optional surface
      transition; floor snap and step-up are disabled.
- [ ] `custom`: bypasses the built-in motor entirely: no gravity, friction, floor checks
      or automatic collision response. A `CustomMovement` hook receives the body, input
      and `dt` and drives the motion, and may call `moveAndSlide` explicitly, for
      vehicles, ladders, climbing and jetpacks.
- [ ] `MovementTransition` objects, owned by a mode or global, evaluate state and return
      the next mode; they are optional. `queueNextMode` handles explicit requests such as
      scripted changes. Both preserve the body unless the target mode says otherwise, and
      a custom mode can return control to a built-in one.
- [ ] Layered moves and `MovementModifier`s apply on top of a mode, so a platform,
      impulse or stance changes motion without editing the mode.
- [ ] Per-mode unit tests and a test that cycles through every mode and back.

### Input

Mover does not own device input. It consumes a command struct that the project fills
from keyboard, mouse, gamepad, touch, AI or a replay. The default CMC character setup
reads devices for you, which is convenient but rigid; here the mapping stays with the
game.

- [ ] `MoveInput` is whatever command struct the project chooses; the core only requires
      a minimal contract (move axis, look delta, jump, crouch, sprint and action
      triggers). The default character preset ships `CharacterInput` as an example;
      games add their own fields.
- [ ] `pukan.mover` never reads GLFW or gamepads. `demo_godot` provides a
      `CharacterControls` mapper from GLFW keys and mouse to `CharacterInput`.
- [ ] Optional reference mapper with rebindable actions, dead zones and sensitivity,
      shipped as a demo utility, not baked into the controller.
- [ ] Input commands are tick-stamped, fixed-step and serializable; the same struct feeds
      local play, replay and the network backend.
- [ ] Support synthetic input for tests, AI and cutscenes without a window.
- [ ] Document the contract and show a gamepad and touch binding as examples, not as
      requirements.

### Root motion

Unreal lets an animation own movement for the duration of an action: a dash, a
knockback hit or a scripted move. The movement step still resolves collision, but the
animation delta replaces the usual input and physics velocity for that step.

- [ ] Extract the root bone delta per animation step from glTF and Godot animation
      tracks; sample it on the CPU for movement while skinning stays on the GPU.
- [ ] `RootMotionMode`: `ignore`, `additive` and `override`. `additive` adds the delta
      to the motor velocity; `override` replaces it for the action duration.
- [ ] Apply the delta through the same shape sweep and `moveAndSlide`, so a dash cannot
      pass through a wall; optionally project onto the floor and keep step-up and floor
      snap.
- [ ] A root-motion action is a layered move above `MovementMode`:
      `Action { animation, rootMotionMode, duration, cancelWindow, targetMode }`. While
      active it suspends the mode's acceleration, friction and gravity as the policy
      says, then returns control to the mode at its velocity.
- [ ] Actions: dash, dodge, attack with knockback, vault and mantle. Knockback can also
      come from an external impulse through the same override path.
- [ ] Blend in and out over a short window, keep the body aligned to its up axis, and
      handle interrupted actions and mode changes without teleporting.
- [ ] Replay records the active action, animation time and root-motion mode, so a
      scripted move can be reproduced from the screenshot metadata.

### Design

- [ ] `pukan.mover`: `MoverComponent` owns a `BodyShape` and a `MoveState`; `MoveInput` is
      the project-filled command contract; `MoverComponent` runs one fixed-step update and
      hands each move to a `MoverBackend`.
- [ ] `pukan.character`: optional default preset. It configures `MoverComponent` with a
      capsule and supplies `CharacterInput`, `CharacterMovementConfig` and the walking,
      falling, flying and swimming modes for CMC parity.
- [ ] `MoverComponent` selects the mode, runs transitions and modifiers, and delegates the
      step to them, with no per-mode branching.
- [ ] `MoveState` splits sync state (position, velocity, orientation, floor/wall/ceiling
      flags, ground body) from auxiliary state (movement mode, action, root motion), so
      local replay can copy a whole state; the later network backend can reuse the same
      split.
- [ ] `MoverBackend` interface: a local backend runs a move immediately, and a replay
      backend can rerun recorded moves. The core never talks to sockets; the network
      implementation belongs to `## Networking`.
- [ ] The default character preset places the capsule origin at the feet, so scene
      transforms and camera offsets match Godot.
- [ ] `CollisionWorld`: BVH over mesh triangles and primitive colliders (box, sphere,
      capsule, cylinder, plane), with collision layers and masks.
- [ ] Queries: ray, sphere and shape sweeps for capsule, box, sphere and cylinder; a
      swept shape returns time of impact, point, normal, penetration depth, shape and
      node. Reuse `dlib.geometry` where it fits; add the missing narrowphase.
- [ ] `CharacterControls` is a demo-side mapper from GLFW keys and mouse to the default
      preset's `CharacterInput`; the motor consumes the command and never opens a device.
      The camera rigs read the same command.
- [ ] Camera rigs: camera-relative move axes, collision-aware spring arm for the third
      person, smooth follow and interpolation; switch view without touching the motor.

### Phases

#### Phase 1: collision world

- [ ] Build `CollisionWorld` from `GodotScene` mesh triangles and from decoded collision
      shapes.
- [ ] Decode `StaticBody3D`, `AnimatableBody3D`, `RigidBody3D` and `Area3D`, their
      `CollisionShape3D` children, and `BoxShape3D`, `SphereShape3D`, `CapsuleShape3D`,
      `CylinderShape3D`, `ConvexPolygonShape3D`, `ConcavePolygonShape3D` and
      `WorldBoundaryShape3D`.
- [ ] `GridMap` cell collision and `collision_layer`/`collision_mask` filtering.
- [ ] Fall back to mesh triangles for `MeshInstance3D` without collision shapes, behind
      a switch for fixtures that have none.

#### Phase 2: kinematic motor

- [ ] Movement mode modules and `MovementTransition`s with per-mode gravity, friction,
      acceleration and floor rules.
- [ ] Acceleration, braking, ground friction and air control; sprint and walk speeds.
- [ ] `moveAndSlide`: iterative collide-and-slide with contact planes, `safeMargin`,
      `maxSlides`, floor/wall/ceiling classification and blocking-hit results.
- [ ] Step-up over `maxStepHeight`, floor snap after leaving the ground, walkable floor
      angle and slope sliding.
- [ ] Jump with velocity, hold time, multiple jumps, jump buffer and coyote time.
- [ ] Crouch changes the body shape height (the capsule in the default character set)
      and checks the ceiling before standing up.
- [ ] Moving platform velocity, floor locking and platform rotation.

#### Phase 3: input, camera and demo

- [ ] First-person camera with eye height and third-person camera with a spring arm.
- [ ] `demo_godot`: `--character` and `--third-person`, spawn the default character
      preset on the platformer stage, show its shape and contacts in a debug mode.
- [ ] The same `CharacterInput` drives the default character preset and both camera
      rigs; the demo mapper switches control between them without built-in input maps. A
      mode switch returns control to the free camera without losing the character state.

#### Phase 4: animation, root motion, replay and verification

- [ ] Root-motion extraction and the layered actions from `### Root motion`; blend
      trees receive speed and floor state; attach the skeleton to the body root.
- [ ] Unit tests for every shape pair, sweep, slide, step-up and snap; also test
      root-motion modes and action cancellation. Golden traces from a fixed input
      sequence.
- [ ] Fixed timestep with render interpolation. Record input, body state, active action
      and camera in the PNG metadata planned for the demo, so a run can be replayed
      exactly.
- [ ] Debug draw: body shape, contacts, normals, velocity, floor state, movement mode,
      active action and root-motion delta; OSD counters once the 2D overlay exists.

Questions:

- Own narrowphase and solver, or a physics library? Start with shape-specific sweeps and
  a small kinematic solver; the body needs queries, not a rigid-body island solver.
- Which shapes must the first version support: is a capsule enough for the default
  character set, or should box and cylinder land with it?
- Are moving platforms in the first version, and does root motion land before or after
  them?
- Should collision come only from `GodotScene`, or also from glTF instances in the
  same `CollisionWorld`?
- Which non-character preset proves the core is shape-agnostic: a vehicle, a projectile
  or a flying pawn?

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
with a normal offset and one filtered comparison; it is fitted to the loaded
scene when the app supplies its bounds. Only the sun casts; there are no
cascades and no local-light shadows. Missing:

- [ ] Cascaded directional maps; the sun keeps one fitted orthographic map until
      then.
- [ ] Local-light shadows on top of `SunShadow`: an atlas of spot tiles first,
      then point lights as a cubemap or six tiles, with per-light matrices,
      tile metadata in the frame data and per-tile cache validity.
- [x] Cache the sun's shadow map while the casters and the sun stay put, so a
      static level does not redraw an unchanged map every frame.
- [x] Caster coverage: masked cutouts cast through an alpha-tested shadow
      variant.
- [ ] Caster coverage: the non-glTF primitives do not cast yet.
- [ ] A wider filter and cascade blending; the comparison is one bilinear tap today.
- [ ] Light culling by distance and screen size.
- [ ] Calibrate AgX against Godot; `Environment.tonemap_mode = 4` falls back to
      ACES today, and the background bypasses exposure and tonemap entirely.
- [ ] Shadowmasking: baked directional occlusion that dynamic lights sample, so
      a lit surface can stay in a baked shadow.

## Depth buffer

The scene pass and the sun's shadow map share `DepthBuf.format`,
`D24_UNORM_S8_UINT`. The stencil bits are unused: every attachment is created
with `DONT_CARE` and the pipelines keep stencil testing off. Depth precision is
what makes the truck town windows flicker at distance, and both steps below are
long-term work.

- [ ] Switch the depth attachment to `D32_SFLOAT` on its own, keeping the
      current Z convention. It costs the same 32 bits per sample as the 24-bit
      format with stencil and drops a stencil the engine never uses. Alone it
      buys little: float depth keeps its relative precision near 1.0 with a
      normal projection, so this is groundwork for the next item rather than a
      fix. Measure the change on the truck town window flicker before keeping
      it.
- [ ] Make reverse Z a compile-time choice of the swapchain, or of whichever
      object owns the presented frame, rather than a project-wide switch: the
      depth target and the projection rendered into it share one convention,
      and every pass that reads that target follows it. Keep the current
      convention as the default and as the fallback for hardware without
      usable float depth. Flip the projection, the clear depth, every depth
      compare, the OIT sorting and the `min`/`max` in the resolve, and retune
      the shadow bias; decide separately whether the sun's shadow map follows
      or stays conventional. Ship one build per convention rather than a
      runtime switch, with no two conventions on one target. Check it on the
      truck town house windows at distance and while the camera turns: the
      wall and the window decals must stop flickering.
- [ ] Test both builds on the fixed scene: the truck town windows must stop
      flickering at distance, and the OIT, transmission and shadow results must
      match the normal-Z build apart from precision.

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

- **Mixed winding in one batch**
  - [x] Enable `VK_DYNAMIC_STATE_FRONT_FACE` on the PBR and primitive
        pipelines; `Mesh` carries a `VkFrontFace` per draw and sets it before
        drawing. glTF and Godot keep their native index order, and a batch
        switches state instead of re-encoding indices. Requires the Vulkan 1.3
        `extendedDynamicState` feature.

- **Frustum culling**
  - [x] Conservative local-AABB test against the draw matrix in the Godot and
        glTF paths, in the colour and shadow passes, so an off-screen mesh
        costs no draw.
  - [ ] Skinned meshes: derive the bounds from the posed skeleton instead of
        skipping them.
  - [ ] Cull whole instances and subtrees before walking their children.

- **Instanced static primitives**
  - [x] Batch static meshes that share vertex and index buffers, pipeline
        variant and descriptor set into one instanced draw, not glTF primitives
        only: the loader is the first producer, not the boundary. The transform
        moves from the push constant into a per-frame instance buffer read as
        vertex attributes. One batch carries one descriptor set, so meshes with
        different materials split it. The sphere and cylinder renderers already
        issue instanced draws from compute-built commands and stay as they are.
  - [ ] Skinned meshes join the same batch while they share a pose, which is one
        joint matrix buffer: the shader applies the instance transform after
        skinning, so a crowd in lockstep costs one draw. Different poses split
        into batches, each still instanced.
  - [ ] Drop the descriptor set from the batch key: index textures from the
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

- **Vertex color attribute**
  - [ ] Measure the always-bound color stream: 4 bytes per vertex for colored
        meshes, a stride-0 fallback for the rest, and one attribute fetch in
        every PBR and shadow pipeline. Run the fixed scene with the same
        geometry, once with colors and once without.
  - [ ] Choose from the numbers between the single path and a static
        `VERTEX_COLOR` shader and pipeline variant for colored materials. The
        variant removes the fetch and the fallback but multiplies every
        existing PBR pipeline; the shadow vertex input can drop color on its own
        without that multiplication.

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

## User directories

`FilePipelineCacheStore.defaultDirectory` reads `XDG_CACHE_HOME` or `HOME` on
POSIX and `LOCALAPPDATA` on Windows. Config, data, logs and screenshots need
the same answer, and the right one differs per platform and packaging (Flatpak,
Snap, macOS application containers), so it belongs in one place rather than in
each caller.

- [ ] Pick one library, or write the small wrapper, that resolves the cache,
      config, data and log roots per platform; `xdgpaths` covers the XDG case.
- [ ] Route the pipeline cache, config, data, logs and screenshots through it.
- [ ] Keep the roots overridable from the environment and from a command-line
      switch, so a portable build and tests do not share state with an
      installed copy.

## Pipeline libraries

Long term, optional: `VK_KHR_pipeline_library` together with
`VK_EXT_graphics_pipeline_library`, so 10 vertex and 100 fragment variants
become 10 + 100 libraries that link into 1,000 pipelines instead of 1,000
compilations. The first extension alone only lets a finished pipeline be linked
as a library; the split into vertex input, pre-rasterization, fragment shader
and fragment output stages comes from the second. Both stay behind the device
requirements, with the monolithic path as the fallback.

- [ ] Spike: measure linking against compiling on the fixed scene, 10x100
      variants, cold and with the pipeline cache warm. Linking is cheaper than
      compiling, but it is not free, and the count only matters while startup
      still stalls.
- [ ] Split `PipelineKey` along the same four stages and cache the libraries in
      the same store, so the combinatorial explosion shrinks in the cache too.
- [ ] Evaluate `VK_EXT_shader_object` as the other way to the same end, with no
      link at all: bind the shaders and keep the state dynamic.

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

## Build-time feature selection

The README asks for builds assembled from the features a project uses.

- [ ] Compile a second lit fragment pair without `shadowFactor`, selected at
      draw time from `Scene.shadowsEnabled`. Only lit doubles: 4 more SPVs and
      24 pipelines. Duplicating the whole `mesh_pbr` family would add hundreds
      of pipelines for a runtime toggle that already skips the fetch, so it
      waits for the general variant selection.
- [ ] Clarify the shader configuration space. List the axes that now multiply
      `mesh_pbr` (lighting mode, shadows, OIT, transmission, Godot vs glTF,
      core vs extended PBR) and choose for each a separate SPV, a
      specialization constant, or a runtime branch. Explore splitting the
      shader into feature blocks and composing only the needed ones at load
      when a pipeline is created, for better performance: measure whether the
      driver prunes dead branches from specialization constants, and whether
      composing and compiling at load is affordable next to shipping SPVs.
      This is the same shape as Godot's per-variant shader compilation.
- [ ] Make the environment optional in `material.glsl`: compile out `toneMap`
      and the ambient tint when the scene has no environment, and turn the
      tonemap mode into a variant or a specialization constant instead of a
      runtime branch. A build without environments should carry neither.

## Offscreen output

`demo` and `demo_godot` render through a `SwapChain` tied to a GLFW window, so
a run needs a display and a visible window. Debugging wants the same frame
written into images in memory instead.

- [ ] A second window type behind the same interface: an offscreen target that
      owns colour and depth images, a fake surface format and a present that
      does nothing. The scene reads only the target extent and format, so the
      swapchain can treat both kinds alike.
- [ ] An option for both demos, such as `--offscreen`, that selects it with a
      fixed extent and a frame count.
- [ ] Screenshots from the offscreen target through the existing
      `Scene.captureFrame` path, with no window, compositor or present
      dependency.
- [ ] Use it for benchmarks and CI: the fixed scene then measures GPU work
      without present timing or vsync, and the run needs no display server.

## OpenXR

The most distant item: VR owns the frame shape, so it waits until the renderer
and the scene are settled. The stereo path and `Scene.surfaces` (#5) are the
groundwork.

- [ ] Session on the existing Vulkan device, an eye swapchain the compositor
      owns with the window as a mirror, and the per-eye pose and projection from
      `XrView` instead of the demo's fixed stereo views.
- [ ] Fall back to the window path when no runtime is installed.

## Networking

Low priority and later. The Mover core and its default character preset must compile and
run without it. Off by default: a `network` dub configuration sets
`-version=PukanNetwork`; without it the build carries no sockets, replication code,
snapshots or rollback buffers.

This is an optional network backend for the Mover core in `## Mover`, not a second
movement system. `MoverComponent` produces moves from input and state; this layer
buffers, sends, applies and replays them.

- [ ] One shared tick timeline. The server advances authoritative ticks; the client runs
      the same fixed-step simulation slightly ahead of the server in prediction mode.
- [ ] Clients send only input frames, never body state. A frame carries the target tick,
      the project's input command, the active action and root-motion input.
- [ ] The server buffers inputs until their tick, simulates that tick with the same
      `MoverComponent`, and broadcasts the resulting state to every client.
- [ ] State broadcasts are snapshots, not corrections. The server does not decide that a
      client is wrong and does not ask for a rollback.
- [ ] The client records the predicted state per tick. On a received snapshot it compares
      the authoritative state for that tick with its own prediction; if they differ
      beyond tolerance, the client rolls back to the snapshot, replays buffered inputs
      from that tick to the current prediction tick, and continues.
- [ ] Differences below the tolerance are smoothed instead of rolled back; a large or
      repeated mismatch exposes a divergence in the simulation.
- [ ] Keep input history and state history on both sides; redundant input windows cover
      packet loss, and clock sync keeps ticks aligned.
- [ ] Handle jitter, reordering, duplicates and late input; choose full or delta
      snapshots.
- [ ] Fixed timestep, identical tunables and collision data on both sides. Accept small
      floating-point divergence and let the client's rollback reconcile it.
- [ ] Keep simulation separate from rendering: the server runs without Vulkan, and a
      client can replay a body without drawing.
- [ ] Telemetry: prediction error, rollback count, replay depth, RTT and packet loss in
      the debug overlay.
- [ ] Loopback and simulated-link tests, plus golden replays for prediction, rollback and
      replay.

Questions:

- Which transport and serialization: raw UDP with fixed-size frames, ENet, or
  GameNetworkingSockets?
- Does the server need validation beyond movement consistency, such as speed or
  teleport checks?
- How far ahead does the client predict: a fixed tick count or measured RTT?
- What does the server do when an input for a tick has not arrived: stall, extrapolate,
  or skip?
