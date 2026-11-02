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

## Look at the dependencies first

Before writing an algorithm, search for it by hand. The local Dub cache under
`~/.dub/packages` already holds dlib, dagon, gamut and ae; the Dub registry and
the maintained D repositories come next, then the demos and the code this
project already carries. A second implementation is the fallback, and the item
or the commit says what was searched and why nothing fit.

What is there today:

- `dlib.geometry`: `Frustum` with `intersectsAABB` and `intersectsSphere`,
  `AABB`, `OBB`, `MPR`, `TriMesh`, ray and triangle intersection. Borrow the
  tests and the formulas, not the types: dlib's `AABB` is a center and a
  half-size with cached `pmin`/`pmax`, while `pukan.physics.shapes.Aabb` and
  `pukan.misc.Boxf` keep min and max and need union, sweep and surface area.
- `dlib.math`: matrix decomposition, dual quaternions, SSE helpers.
- `dlib.concurrency`: thread pool, task queue, worker threads and an SPSC
  queue, the pieces a streaming path needs for upload and build workers.
- `dlib.container`, `dlib.core`: arrays, BST, dict, buffers, arenas and
  ownership.
- `dagon.collision.bvh`: a generic SAH BVH with box, sphere and ray traversal
  queries.
- `dagon.openworld`: `OpenWorldManager` and `WorldChunk`, a chunk grid with
  activation, an update loop and a traveler wrap hook.
- `dagon.graphics.lod`: `LODDrawable` with distance bands and fade.
- `dagon.graphics.csm`, `psm`, `dpsm`, `shadowmap`: cascaded, perspective and
  dual-paraboloid shadow map boilerplate.
- `dagon.render.deferred`: a G-buffer renderer with geometry, light, shadow,
  SSAO and volumetric passes. Its occlusion pass is SSAO, not occlusion
  culling, so it is no answer to the hidden-geometry item.
- `dagon.graphics.terrain`, `heightmap`, `billboard`: terrain and camera-facing
  quads.
- `ae.sys.paths`, `ae.sys.config`, `ae.sys.benchmark`: user directories,
  configuration and timing.
- `gamut`: image codecs and texture formats.

None of it is dropped in whole: dagon targets OpenGL and owns its own scene
graph, and dlib's containers predate ranges. The gain is the algorithm, its
tests and the corner cases already paid for.

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

Collision bodies and shape resources are decoded for the Mover, see
`#### Colliders from Godot` under `## Mover`. They are not visual content and
stay out of the draw tree.

#### Phase 1: text scenes, static geometry and materials

- [ ] External `.obj` references.
- [ ] `MeshInstance3D`: material instances.

#### Demo

- [ ] A screenshot key (`PrintScreen`) in `demo_godot`: capture the current
      frame and write the loaded scene path, the active render flags and the
      full camera state (position, orientation, `lookAxis`, FOV, near and far
      planes) into the PNG as `tEXt`/`iTXt` metadata, so the view can be
      reproduced exactly and two frames compared later.

#### Phase 2: lights, cameras and environment

- [ ] Layers, visibility ranges and `cast_shadow` modes.

#### Phase 3: binary resources and packed production projects

The end goal is a game exported by Godot, not only a source project.

- [ ] `PackedScene` base scenes and child index ordering.
- [ ] Read the glTF import settings next to a source asset: at least
      `nodes/apply_root_scale` and `nodes/root_scale`, which is what makes the
      town tree stand at the right size, plus `nodes/use_name_suffixes` and
      `materials/extract` when a project relies on them.
- [ ] Stream or memory-map pack files instead of loading the whole archive.
- [ ] Resource deduplication across a scene.

#### Phase 4: instances, skinned meshes and animation

- [ ] Instance property overrides and editable children.
  - [ ] Children addressed by `parent_id_path` and `index`.
- [ ] `MultiMeshInstance3D` and `MultiMesh`.
- [ ] Native Godot skinning, broken down:
  - [ ] CPU skinning fallback for devices without the GPU path.
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

#### GridMap

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

- [ ] Interior fixture: a room assembled from CC0 Kenney furniture with omni
      lights and a camera, to test many small glTF instances and indoor light
      falloff.
- [ ] `character/`: a movement gym with a `StaticBody3D` floor, ramp, stairs, a
      0.45 m step, a 45-degree slope, a narrow ledge, a wall, crates and a water
      volume, plus a `CharacterBody3D` spawn marker and a `Camera3D`. The
      platformer stage stays the `GridMap` case.
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

## Mover

Goal: a modular movement system whose first motor is Quake-style, with the API
clarity of Godot's `CharacterBody3D` and the modularity of Unreal Mover. The core
is actor-type and shape agnostic: any root scene component, any up axis, a
capsule, box, sphere, cylinder or no collision at all. The first preset is a
humanoid capsule on Godot levels. CMC-style acceleration and Godot-style
`moveAndSlide` parity are later movement models, not the first target. Networking
is a separate, later backend, see `## Networking`.

From Quake:

- a fixed `pmove` tick and `usercmd` input: wish direction, wish speed, jump, crouch and
  attack;
- ground friction, acceleration, air acceleration, stop speed, gravity and max velocity;
- `PM_ClipVelocity` with overbounce and `PM_StepSlideMove` with an up-forward-down pass;
- water move, noclip and spectator, and no coyote time or jump buffer by default;
- client prediction and server reconciliation over the same move, see `## Networking`.

From Godot:

- a kinematic body and `moveAndSlide()` behavior that resolves the slide; the active mode
  chooses when to call it and with which shape and velocity;
- explicit `isOnFloor`/`isOnWall`/`isOnCeiling`, floor normal and angle, `upDirection`,
  `floorSnapLength`, `floorMaxAngle`, `maxSlides`, `safeMargin`, `motionMode`;
- moving platform velocity, floor locking and last-collision results.

Behavior parity with Godot, not numeric parity: the same visible outcomes, our own
deterministic math and step-up.

From Unreal CMC (later movement model):

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

Expect more project-side code than CMC or Quake: the engine supplies the simulation
and the command contract, not a binding system.

### First playable slice

The slice is a kinematic capsule on a loaded Godot level with a Quake-style
motor: ground friction and acceleration, air acceleration, step-slide, instant
jump, water and noclip. Only static and kinematic colliders react. Rigid-body
dynamics, joints, ragdolls and vehicles stay out until the capsule is solid.

Current state: the physics core, the Godot collision decode and the Quake
ground/air motor are in. `pukan.physics` has shapes, a BVH, ray and capsule
sweeps, layer filtering and a fixed-step `Simulation`; `godot_scene` decodes
`StaticBody3D`, `AnimatableBody3D`, `RigidBody3D`, the shape resources and
`GridMap` item shapes; `pukan.mover.quake` has `pmMove`, friction,
acceleration, air acceleration, clip velocity and step-slide; `demo_godot
--character` walks a capsule on the platformer stage and on the `character/`
movement gym, up its stairs and ramp, in first or third person. Missing: water,
crouch, moving platforms, mesh fallback and debug draw.

Decided for the slice:

- own narrowphase and BVH, with no physics engine dependency; `dlib.geometry`
  supplies support functions but has no sweep;
- static and kinematic colliders only, no rigid-body island solver;
- Y up and a capsule preset, while the core stays shape and actor agnostic;
- level collision comes from Godot body nodes and `GridMap` items, mesh
  fallback is opt-in;
- the character is a separate drawable driven by the body transform, not a
  mutable node of the loaded scene;
- the first motor is Quake-style; CMC and Godot `moveAndSlide` models come later;
- behavior parity with Godot's collision semantics, not numeric parity;
- the player body is a capsule; `BoxShape3D` stays a level collider, and a box
  body is a later preset that only needs a unit test now;
- no second preset in the slice; a box-body test proves the core is shape
  agnostic;
- moving platforms follow jump and slide in Phase 2, root motion stays later.

Done when `demo_godot --character` spawns on the platformer stage and on the
`character/` fixture, walks up and down the ramp, jumps onto a crate, slides
along walls, steps onto a 0.45 m ledge, gains speed with a strafe jump, and
keeps a stable fixed tick while the frame rate changes.

### Shape and the default character set

Mover is actor-type and shape agnostic. CMC requires an `ACharacter` and a capsule; the
core here does not. A capsule is the default for the character preset, not a rule of the
Mover core.

- [ ] `MoverComponent` works with any root scene component, including a non-primitive
      one, and with no collision at all.
- [ ] `BodyShape` covers capsule, box, sphere and cylinder, plus `none`. Modes declare
      which shapes they support, so a car or a projectile uses the same core.
- [x] The up axis is configurable per body; the default character set uses Y up, like
      Godot, and a vertical capsule.
- [x] Godot shape semantics: the capsule stores a radius and a total height including
      both hemispheres, the box stores full extents, matching `CapsuleShape3D` and
      `BoxShape3D`.
- [x] The default character preset is a 0.4 m radius, 1.8 m capsule with a 1.6 m eye
      height and collision layer 1, matching the scale of the Godot fixtures.
- [x] The Quake motor uses the capsule in the first slice; an AABB body is a later
      Quake preset for exact `mins`/`maxs` feel.
- [x] Box is a level collider (`GridMap`, crates, walls) and a later body shape; the
      first slice does not need a box body.
- [ ] The default character set is an optional preset: capsule plus ground, air, water
      and noclip modes.
- [ ] Other presets (vehicle, projectile, quadruped, flying pawn) assemble modes without
      the character set and without a capsule.

### Collision world

`pukan.physics` owns shapes, the broadphase and the queries. It knows nothing
about Godot, rendering or the motor. `godot_scene` decodes collision nodes and
shape resources and adds them with world transforms. `mover` consumes queries
only and never walks the scene tree.

- [x] `CollisionShape` covers sphere, capsule, box, cylinder, convex point set,
      triangle mesh, world boundary plane and none.
- [x] `Collider` stores the world transform, the shape, the collision layer and mask,
      the owning node and whether it is static or kinematic.
- [x] `CollisionWorld` keeps one static BVH over primitive AABBs and mesh triangles,
      built after the level loads.
- [ ] A moved kinematic collider refits its leaf or rebuilds the tree.
- [ ] `RayHit` and `ShapeCastHit` share time of impact, point, normal, penetration depth,
      collider and node.
- [x] Broadphase: median split on the longest axis, leaf size 4, triangles flattened
      into the same tree with their collider id.
- [ ] Compare `pukan.physics.bvh` with `dagon.collision.bvh` (SAH, generic, with
      box, sphere and ray traversal) before growing it further; keep ours only
      where the Vulkan no-allocation and streaming rebuild demands differ.
- [ ] Narrowphase: analytic plane and sphere, segment-triangle distance for a capsule
      against a mesh, GJK distance for separated convex pairs plus conservative
      advancement; `intrMPR` from `dlib.geometry` supplies the penetration normal when
      they overlap. No SAT fallback until a test demands it.
- [ ] Shape casts for sphere, capsule, box and cylinder; a capsule is a segment plus a
      radius. Each cast advances at most 16 steps and starts from the swept AABB.
- [ ] Triangle meshes weld shared vertices and filter internal edges, so a cast does not
      catch on the seam between coplanar triangles.
- [ ] `PlaneCollider` and convex brush colliders are optional for Quake-style maps; the
      first slice uses Godot triangles and primitives.
- [x] Box colliders are required for `GridMap`, crates and walls; a box body is not.
- [x] Overlap query for triggers, spawn checks and crouch clearance.
- [x] Collision layers are the 32-bit Godot bitmasks; a query takes a mask and matches
      when `layer & mask` is non-zero.
- [x] Contact normals point out of the collider toward the body, like Godot's
      `KinematicCollision3D`.
- [ ] Numeric defaults follow Godot: safe margin 0.001 m, floor max angle 45 degrees,
      floor snap 0.1 m, wall minimum slide angle 15 degrees, at most 4 slides.
- [x] Quake's overbounce, step-slide and air acceleration belong to the motor, not the
      collision world.
- [x] Reuse `dlib.math` types and `dlib.geometry` support functions; dlib's MPR only
      detects overlap and has no sweep, so the swept narrowphase is ours.

#### Colliders from Godot

- [x] `StaticBody3D`, `AnimatableBody3D` and `RigidBody3D` (as a static snapshot) decode
      `collision_layer`, `collision_mask` and their `CollisionShape3D` children.
- [x] Shapes: `BoxShape3D` full extents, `SphereShape3D` radius, `CapsuleShape3D` radius
      and total height, `CylinderShape3D`, `ConvexPolygonShape3D` points,
      `ConcavePolygonShape3D` triangles and `WorldBoundaryShape3D` plane.
- [x] Shape resources resolve from sub-resources and external `.tres`/`.res`, text and
      binary, the same way meshes and materials do.
- [x] `CollisionShape3D` applies its local transform and honors `disabled`.
- [x] `GridMap` adds the `MeshLibrary` `item/N/shapes` pairs at each occupied cell,
      reusing the cell transform and 24-way orientation the visual cells already
      compute.
- [x] Nested `GodotScene` instances are traversed once, with the same instance transform
      the draw path uses, so collision does not depend on how the scene nests.
- [ ] Collision data lives on `GodotNode` and needs no device, so a headless server can
      load a level and build the same world without Vulkan.
- [ ] `GodotLoadOptions.collisionFromMeshes` turns a `MeshInstance3D` without a body into
      a concave collider; off by default because the town would pay for every tree.
- [ ] glTF instances can contribute concave colliders behind their own option, off by
      default for the same reason.
- [ ] `RayCast3D` becomes a ray query for the camera spring arm and debug, not a
      collider.
- [ ] `Area3D` volumes are query-only; they never block the body.
- [x] Rigid bodies stay static snapshots in the slice; moving them, joints and
      body-to-body contacts are a later backend.

### Movement modes as modules

- [ ] `MovementMode` is an interface with hooks such as `onGenerateMove` and
      `onSimulationTick`, not a switch inside one update function. Ground, air, water,
      noclip and custom are separate modules.
- [ ] Modes declare the shared settings they need (gravity, speeds, friction, step
      height); `MoverComponent` deduplicates them, so ground and air read one instance.
- [x] `moveAndSlide` is Quake's `PM_ClipVelocity` plus `PM_StepSlideMove`: up to four
      planes, overbounce 1.001, and a step pass that keeps the farther result.
- [x] `ground`: Quake friction and acceleration, step-slide, floor classification and
      jump. Leaving the floor switches to `air`; water switches to `water`.
- [x] `air`: gravity and air acceleration, no friction; landing switches to `ground`.
      The air acceleration is what makes strafe jumping and bunny hopping work, with no
      special-case code.
- [ ] `water`: reduced gravity, water friction and buoyancy, swim up and down, no
      step-up or floor snap; leaving the volume switches back to `air` or `ground`.
- [x] `noclip`: no collision, free 3D movement and no floor state, for spectating and
      debug.
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
- [x] The Quake preset has no coyote time, jump buffer, jump hold or multiple jumps.
      Those belong to the later CMC model.
- [ ] Per-mode unit tests and a test that cycles through every mode and back.

### Input

Mover does not own device input. It consumes a `usercmd`-style command struct that the
project fills from keyboard, mouse, gamepad, touch, AI or a replay. The engine supplies
the contract, not the binding.

- [ ] `CharacterInput` carries the Quake `usercmd` fields: wish direction, wish speed,
      jump, crouch, attack, use, view angles and tick. The default character preset
      ships it as an example; games add their own fields.
- [x] The Quake preset reads wish direction and wish speed and has no jump hold.
- [x] `pukan.mover` never reads GLFW or gamepads. `demo_godot` provides a
      `CharacterControls` mapper from GLFW keys and mouse to `CharacterInput`.
- [ ] Optional reference mapper with rebindable actions, dead zones and sensitivity,
      shipped as a demo utility, not baked into the controller.
- [ ] Input commands are tick-stamped, fixed-step and serializable; the same struct feeds
      local play, replay and the network backend.
- [ ] Support synthetic input for tests, AI and cutscenes without a window.
- [ ] Document the contract and show a gamepad and touch binding as examples, not as
      requirements.

### Root motion

Not part of the Quake motor. It stays a later layer for animation-driven actions,
after the first slice is solid.

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

- [x] `pukan.physics.shapes`: `CollisionShape`, `ShapeKind`, `Collider`, shape
      construction and bounds.
- [x] `pukan.physics.bvh`: static BVH with median split and primitive or triangle leaves.
- [ ] `pukan.physics.narrowphase`: segment-triangle distance, GJK distance, conservative
      advancement and the plane and sphere fast paths.
- [x] `pukan.physics.world`: `CollisionWorld`, `RayHit`, `ShapeCastHit`, `Contact`, layer
      filtering and queries.
- [x] `pukan.mover`: `MoverComponent` owns a `BodyShape` and a `MoveState`; `MoveInput`
      is the project-filled `usercmd`; one fixed `pmove` runs the selected mode and
      modifiers, then hands the move to a `MoverBackend`.
- [ ] `pukan.mover.quake`: `QuakeMovementConfig`, `pmFriction`, `pmAccelerate`,
      `pmAirAccelerate`, `pmClipVelocity`, `pmStepSlide` and the ground, air, water and
      noclip modes.
- [ ] `pukan.character`: optional default preset. It configures `MoverComponent` with a
      capsule and supplies `CharacterInput`, `QuakeMovementConfig` and the first movement
      modes.
- [ ] `MoverComponent` selects the mode, runs transitions and modifiers, and delegates the
      step to them, with no per-mode branching.
- [ ] `MoveState` splits sync state (position, velocity, orientation, floor/wall/ceiling
      flags, ground body) from auxiliary state (movement mode, action, root motion), so
      local replay can copy a whole state; the later network backend can reuse the same
      split.
- [ ] `MoverBackend` interface: a local backend runs a move immediately, and a replay
      backend can rerun recorded moves. The core never talks to sockets; the network
      implementation belongs to `## Networking`.
- [x] `pukan.physics.simulation`: `Simulation` owns the collision world and the fixed
      tick: a 60 Hz accumulator clamped to 8 steps per frame, the body list and the
      interpolation alpha. `Scene` stays a renderer and does not tick.
- [ ] `pmove` is deterministic and versioned; behavior parity with Godot's
      `moveAndSlide`, not numeric parity.
- [x] Quake defaults live in `QuakeMovementConfig` and stay tunable: max speed 320 ups
      (8.1 m/s), jump 270 ups (6.9 m/s), gravity 800 ups squared (20.3 m/s squared),
      friction 6, stop speed 100 ups (2.5 m/s), acceleration 10, air acceleration 1,
      step 18 units (0.46 m). Quake 3 is the baseline; a QuakeWorld config can change
      air acceleration and friction later.
- [x] The default character preset places the capsule bottom at the body origin, so a
      scene transform is a feet position and camera offsets match Godot. The shape center
      is offset by the radius plus half the cylinder.
- [x] The character is a separate drawable (a glTF model or a debug capsule) drawn with
      the simulated body transform, not a node of the loaded scene. The third-person
      mesh and camera use the current position, so they match the capsule; first-person
      interpolates. Node transform writeback is only needed for moving platforms.
- [x] Model matrices use `trsMatrix`: the MVP path is column-vector, so the order is
      `translation * rotation * scale`, not `scale * rotation * translation`.
- [ ] `demo_godot` builds the collision world from the loaded scene, spawns the preset at
      `--spawn` or at the first `CharacterBody3D`/`Marker3D`, and steps the simulation
      before `drawNextFrame`. `--movement quake` is the default.
- [ ] `CharacterControls` is a demo-side mapper from GLFW keys and mouse to the default
      preset's `CharacterInput`; the motor consumes the command and never opens a device.
      The camera rigs read the same command.
- [ ] Camera rigs: camera-relative move axes, collision-aware spring arm for the third
      person, smooth follow and interpolation; switch view without touching the motor.

### Phases

#### Phase 0: fixed tick and world state

- [x] `Simulation` with the fixed 60 Hz accumulator, a clamp of 8 steps per frame and a
      render interpolation alpha.
- [x] `MoverComponent` runs a fixed `pmove` and stores the previous and current
      position; first-person rendering interpolates it.
- [x] `demo_godot` gets `--physics-hz` and `--fixed-step` and steps
      the simulation before recording the frame.
- [ ] An empty capsule with no collision follows the tick and interpolates in the demo.

#### Phase 1: collision world

- [x] Decode the Godot body nodes and shape resources from `#### Colliders from Godot`.
- [ ] `CollisionWorld` BVH, ray query, shape cast and overlap query.
- [x] Build the world from `GodotScene`, including `GridMap` cells.
- [ ] Weld triangle vertices and filter internal edges.
- [ ] Unit tests for every shape pair, ray hit and cast time of impact; a triangle mesh
      floor, a box wall, a ramp, a capsule body and a box body.
- [ ] Measure the BVH build time on the platformer stage and the town, and the cast cost.
- [ ] `demo_godot --debug-collision` draws every collider and the result of a camera ray.

#### Phase 2: Quake motor

- [ ] `pmove` with ground, air, water and noclip modes and `MovementTransition`s.
- [x] Ground friction, acceleration, stop speed, gravity and max velocity.
- [x] Air acceleration, no friction, and the strafe jump and bunny hop it produces.
- [x] `PM_ClipVelocity` with overbounce 1.001 and `PM_StepSlideMove`: slide, then
      up-forward-down over `maxStepHeight` (0.46 m), keeping the farther result.
- [x] Instant jump, no coyote time, no jump buffer, no hold and no multiple jumps.
- [ ] Crouch changes the capsule height and checks the ceiling before standing up.
- [ ] Water move with reduced gravity, water friction and swim up and down.
- [ ] Moving platform velocity, floor locking and platform rotation with
      `AnimatableBody3D` writeback.
- [ ] Unit tests: walk up a ramp, step onto a 0.45 m ledge, jump and land, slide along a
      wall, strafe jump speed gain, bunny hop, water, noclip, and no tunneling.

#### Phase 3: input, camera and demo

- [ ] `CharacterInput` from GLFW: WASD, mouse look, Space, Ctrl and attack.
- [x] First-person camera at eye height and third-person camera with a collision-aware
      spring arm.
- [x] `demo_godot --character` and `--third-person` spawn the preset on the platformer
      stage and on the movement gym; a mode switch returns to the fly camera without
      losing the body state.
- [ ] Debug draw of the capsule, contacts, normals, velocity, floor state, movement mode
      and active action; OSD counters once the 2D overlay exists.

#### Phase 4: animation, root motion and replay

- [ ] Animated walk, idle, jump and fall for the demo character.
- [ ] Root-motion extraction and the layered actions from `### Root motion`; blend trees
      receive speed and floor state; attach the skeleton to the body root. This is not
      part of the Quake motor and can land after it.
- [ ] Golden traces from a fixed input sequence, plus tests for root-motion modes and
      action cancellation.
- [ ] Record input, body state, active action and camera in the PNG metadata planned for
      the demo, so a run can be replayed exactly.

### Later movement models

- [ ] CMC model: acceleration and braking, air control, jump hold, multiple jumps,
      coyote time, crouch and root motion.
- [ ] Godot model: `moveAndSlide` behavior parity, floor snap and `motionMode`.
- [ ] AABB body for exact Quake `mins`/`maxs` feel.
- [ ] Second preset, starting with a projectile: no input, no camera, gravity, sweep and
      bounce.

## Motion Matching

The target is the pose search system Unreal ships as the `PoseSearch` plugin: animation
segments are sampled into a database of channel vectors, and every search compares a query
built from the current pose, velocity and predicted trajectory against them. It replaces
hand-authored locomotion state machines and blend trees, so it comes after the Mover and
root motion are solid.

Up is not a constant of the animation code: the scene owns it as an `Axis`, because the
ground normal is what lets a heading stay a single angle.

### Skeleton

Features are extracted per bone and the trajectory is expressed in the root's space, so the
rig has to be predictable. glTF 2.0 carries whatever hierarchy the exporter produced.

- [ ] Root bone at ground level (or at the pelvis) and animated. When the glTF root is a
      static `Armature` or scene root, the animation holds no displacement and the database
      gets no usable trajectory or speed.
- [ ] Two characters in `demo_godot`: the biped `CesiumMan` and the quadruped Fox, which runs
      on four legs; the Fox proves nothing in the database or the query assumes two legs. Bone
      names differ per rig, so a schema names its own.
- [ ] Check the rig in debug builds, the way `debugVerifySkinJoints` checks the GPU skinning:
      report a root joint without a translation channel and a bind pose that is neither at
      ground level nor at the pelvis, so a bad export fails at load instead of yielding a
      database that matches nothing.

### Database

Motion matching indexes animation instead of playing it: every clip is sampled ahead of time,
and the samples become points in a feature space. First slice: one skeleton, one database,
locomotion only.

- [x] Sample every clip at 30 Hz. A sample stores the feature vector, the clip, the time inside
      the clip and a cost bias; the vectors of one database form a flat table.
- [x] Describe the layout with a schema: channels with weights, flattened into one float array
      per pose, so the query and the database cannot drift apart.
- [x] Channels: positions and velocities of feet, pelvis, head and hands in the root bone's
      space, derivatives over 1/60 s; trajectory positions, velocities and heading at -0.4, 0,
      +0.35 and +0.7 s.
- [x] The derivative step is an enum with a DDoc comment, shared by the indexing and the query
      path, so the two can never measure velocities differently.
- [ ] No normalization in the first slice: weights carry the units, so a cost is comparable
      only inside one database.
- [x] Build the database at load from the clips the model carries; a serialized cache is a
      later item.
- [x] Whole cycles add up: the root of a looping clip keeps moving past its loop point, so
      the seam does not read as one huge step backwards.

### Query

- [x] Keep the positions of the bones the schema names in a ring buffer, about half a second
      back. A position is stored relative to the root, so the world position at time t is the
      stored one moved by the root transform the trajectory gives for t. Rotations are not
      stored: no feature needs them yet.
- [x] Trajectory: history from the character's own past motion, prediction by extrapolating
      velocity and yaw rate. No floor traces, gravity or landing in the first slice.
- [x] Build the query vector from the same channels, then search.

### Search

- [x] Linear scan over the whole table, `cost = sum(w * (query - pose)^2)` per dimension, and
      the lowest cost wins. A few hundred poses do not need a tree; a query built for another
      up axis than the database was built with is a bug and is caught.
- [x] Evaluate the continuing pose as a candidate too, with a database-level bias in its
      favour, so the character is not interrupted for nothing.
- [x] Search only when the pose cannot be continued or the interval since the last search
      elapsed.
- [x] Play rate from the ratio between the query speed and the speed of the chosen pose,
      clamped to an interval.

### Playback

- [x] Hard switch to the chosen pose: set the clip and its time. Matching picks a near pose, so
      the switch is mostly invisible.
- [ ] Then crossfade over a short window: sample the outgoing and the incoming pose, lerp the
      bone transforms on the CPU and reuse the existing skinning path.

### Later

- [ ] KD-tree or VP-tree over the feature vectors, once a profile shows the scan matters.
- [ ] Normalization over the database, so weights mean the same thing across databases.
- [ ] Notifies, events, mirrored clips, blend spaces and montages, interaction searches.

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

Opaque, mask (through alpha-to-coverage) and blend are covered. Godot's alpha
depth prepass mode decodes as mask: it is an alpha-tested cutout, and blending
a dense crown instead exhausts the fragment pool of the blended resolve.
Blended draws store their fragments in per-pixel lists and a resolve pass sorts
them by depth before compositing, so overlapping and self-intersecting
transparent meshes no longer depend on a per-draw order. The resolve runs once
before the colour copy and again after the transmission pass, filtered by the
resolved scene depth, so glass shows blended objects behind it and blended
fragments in front of glass stay in front. The fragment pool is fixed: 512K
fragments, 8 MB, shared by the whole frame. When it runs out the writer drops
the rest of the fragments without a trace, so a dense surface loses whole
blocks of itself, cut along a straight line where the pool ended. A crown close
to the camera alone asks for 1-4M fragments at 800x600, so the limit needs a
different technique rather than a bigger constant. Long term:

- [ ] Weighted blended OIT: two RGBA16F accumulations, constant memory per
      pixel and no popping. Needs a pass of its own with two attachments, and
      an accumulation cannot be filtered by depth, so the transmission resolve
      needs another way to keep blended fragments in front of glass.
- [ ] A per-pixel cap: bound the layers one pixel may take, so a single dense
      surface cannot starve the rest of the screen, and blend what does not
      fit directly. Order inside the overflow stays approximate.
- [ ] A pool sized from the viewport. Simple, but this content needs 64 MB per
      frame at 800x600, so it only moves the limit.
- [ ] The depth prepass a mode 4 material asks for, so only the front layer
      reaches the queue. Removes this overload at its source, not the limit.
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

## Large worlds

Everything the engine draws today comes from one loaded scene: the tree is
walked in full, one 1024x1024 sun map is fitted to the whole world, collision is
one static BVH, lights are a single 16-entry frame list, and positions are
single precision. A world that cannot be loaded at once needs all of these to
change together, so the slices below share the cell grid as their unit.

Order: coordinates and the cell partition first, because everything else
addresses cells; then loading and unloading under a per-frame budget; then the
spatial index and GPU-driven draws; then LOD, occlusion, shadows and collision
streaming on top. Every slice is measured at cell borders, where its cost shows
up. Before each slice, read the matching reference named in
`## Look at the dependencies first`: `dagon.openworld` for the cell grid,
`dagon.collision.bvh` for the index and `dagon.graphics.lod` for LOD.

- **Cells and coordinates**
  - [ ] A cell grid owned by `Scene`: a fixed cell size, a level origin and the
        world bounds of each cell. The glTF and Godot loaders assign nodes to
        cells by their bounds, and a node that spans cells duplicates into each.
  - [ ] The loaded set around the camera: a radius of resident cells plus a
        prefetch ring ordered by distance, with one budget per frame for mesh
        upload and pipeline warmup. A cell is released only when no recorded
        frame still draws it.
  - [ ] Floating origin: keep the camera at the origin and shift cell
        transforms, so single-precision positions stay precise far from the
        start.
  - [ ] Decide whether `Matrix4x4f` becomes double precision or only the cell
        offsets do, and measure the vertex cost of the second on the fixed
        scene.

- **Spatial index and GPU-driven draws**
  - [ ] One index over the loaded cells: a BVH or octree per cell with a flat
        top index over cell bounds, shared by frustum, shadow and picking
        queries.
  - [ ] GPU culling: keep the instance list in a storage buffer, cull in a
        compute shader and draw with `vkCmdDrawIndexedIndirectCount`, so the CPU
        uploads only the camera and the cell list.
  - [ ] Keep the CPU path as the fallback and as the reference for the GPU
        results; judge it on 10k, 100k and 1M instances.

- **LOD and HLOD**
  - [ ] Mesh LOD from authored levels first, then generated ones; pick the level
        by screen-space error and keep skinned meshes posed at every level.
  - [ ] HLOD: merge distant groups into one proxy per cell, with an impostor for
        the far ring. Build the merged geometry once per cell, not per frame.
  - [ ] Cluster LOD or virtual geometry (Nanite-style cluster grouping and
        software raster) as the long-term replacement, only after the merged
        HLOD has numbers.

- **Occlusion**
  - [ ] Depth-pyramid (HiZ) occlusion from the previous frame, or a software
        raster of the large occluders on the CPU, and skip hidden cells and
        instances before the draw.
  - [ ] Portals and PVS for closed interiors: a room graph with portal frustums,
        so rooms behind walls never enter the list. Judge it against HiZ inside
        the truck town interiors.

- **Shadows and lights**
  - [ ] Cascaded shadow maps around the camera, each cascade with its own culled
        set instead of one map fitted to the world.
  - [ ] Local-light shadows from the atlas plan under `## Lighting`, culled per
        cell.
  - [ ] Tiled or clustered light culling, so a cell carries its own light list
        and the 16-entry frame limit stops bounding the world.

- **Collision**
  - [ ] One collision BVH per cell, built and released with the cell, and a top
        index over cells for queries that cross their bounds.
  - [ ] Stream colliders one cell ahead of the camera, so the player never
        reaches a cell that has no collision yet.
  - [ ] Keep queries in world space with the floating origin applied.

- **Resources**
  - [ ] Async texture and mesh loading with a per-frame byte budget, replacing
        the immediate upload the loaders do today.
  - [ ] Virtual texturing or mip streaming for textures that exceed memory, with
        residency bounded by the same cell policy.
  - [ ] Share one GPU resource between cells, so an asset placed in two cells
        loads and uploads once.

- **Debug and budgets**
  - [ ] A streaming overlay: loaded and pending cells, bytes per cell, drawables
        per cell, and the frame cost of the load and unload step.
  - [ ] Mark every cell border crossing with the frame time around it, so a
        hitch is attributed to the load rather than to the next draw.
  - [ ] Acceptance is the absence of hitches at cell borders, not an average
        frame rate: a steady 10 to 20 ms drop at a crossing means the budget is
        exceeded or a synchronous step (a physics scene build, a pipeline
        compile) landed on the main thread.
  - [ ] Prefetch seconds before the border, spread actor and collider creation
        over frames, and move mesh loading and physics builds to worker threads.

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

- **Frustum culling**
  - [ ] Skinned meshes: derive the bounds from the posed skeleton instead of
        skipping them.
  - [ ] Cull whole instances and subtrees before walking their children.

- **Instanced static primitives**
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
- [ ] Split `PipelineInstance` along the same four stages and cache the libraries
      in the same store, so the combinatorial explosion shrinks in the cache
      too.
- [ ] Evaluate `VK_EXT_shader_object` as the other way to the same end, with no
      link at all: bind the shaders and keep the state dynamic.

## Shader preloading

Long term: every glTF pipeline variant is built when the factory is created,
whether the loaded scene draws it or not, while a streaming scene needs the
opposite. The scene should be able to name the shaders and pipeline variants it
will use before the first frame, so a loader can warm them while the scene loads
and no first draw stalls on a compile.

### Declaration site

- [ ] Under `PukanEmbedShaders` the bytes stay in the binary; when file loading
      lands, the same declaration reads them from a `ShaderSource` instead.

### Runtime shader loading

Deferred, but required before third-party shaders can be shipped: embedding
every blob in the binary is wrong when each is used once per process, and
`import` cannot cover shaders the library does not know at its own build time.

- [ ] Load SPIR-V from the shader directory at runtime and keep it out of the
      binary by default. Keep `import` as an opt-in build,
      `-version=PukanEmbedShaders`, for self-contained binaries.
- [ ] Add a `ShaderSource` interface with `FileShaderSource` (a list of search
      roots) as the default; a pack or memory source can implement it.
- [ ] Add `uploadShader(string path, ...)` for runtime names and keep
      `uploadShaderToGPU(bytes, ...)` for callers that already hold SPIR-V.
- [ ] Add `shaderBinary(string name)()` to `vulkan/shaders.d`: under
      `PukanEmbedShaders` return `import(name)`, otherwise read the file once
      and cache the bytes.
- [ ] Search roots: an explicit absolute path first, then user roots added with
      `addShaderDirectory`, then `PUKAN_SHADER_DIR`, `<exe dir>/compiled_shaders`
      and `<cwd>/compiled_shaders`. The error lists every path tried.
- [ ] Cache `VkShaderModule` in `loadedShaders` by name and stage, so a second
      request neither reads the file nor creates the module again.
- [ ] Deploy `compiled_shaders/` with the application. The demos run from the
      repository root; an installed app copies the directory next to its
      binary.
- [ ] Do not store `.spv` files in the pipeline cache directory: `trim()`
      evicts records by LRU and the store is tied to `pipelineCacheUUID`.

### Shader set and third-party shaders

- [ ] `Shader!"name"` is a compile-time entity, like `Requirement`: it carries
      `shaderName` and, under `PukanEmbedShaders`, `static immutable ubyte[]
      bytes = import(name)`. The `import` happens in the module that declares
      the entity, so a user module embeds its own shaders at application build
      time, not at library build time.
- [ ] Each entity that owns shaders declares `alias shaders = AliasSeq!(...)`,
      the same way it declares `alias requirements`. `Shaders!(Modules...)`
      unions those aliases with `NoDuplicates`, like `Requirements!(Modules...)`.
      Reuse only the union helper, not the device requirement pipeline.
- [ ] The application writes `alias appShaders = Shaders!(Scene, MyEffects)` and
      installs it before `new Scene`: `device.installShaders!appShaders`.
      `installShaders` fills a `name -> bytes` registry; the resolver looks
      there first and falls back to the file source.
- [ ] A library user can load their own SPIR-V by path or from memory and
      declare a `RenderTechnique` with it. `uploadShaderToGPU` already takes
      bytes; add `uploadShader(path, ...)` and a `ShaderSource` for packs.
- [ ] Keep `ShaderSource` alive for the lifetime of the device; it owns the
      search roots and any pack handles.
- [ ] Use `VK_EXT_pipeline_creation_cache_control` with
      `VK_PIPELINE_CREATE_FAIL_ON_PIPELINE_COMPILE_REQUIRED_BIT` in the
      preloader to tell a cache hit from a compile without paying for it.

## Pipeline lifetime

Loading is now lazy and preloaded per scene, but nothing ever unloads a
`VkPipeline`: `PipelineFactory` keeps every variant in its cache, and
`LogicalDevice.pipelinesDtor` destroys them only with the device. The engine's
own variant space is bounded (2 families x 2 skinning x 4 lighting modes x
3 skies x 6 states, plus shadow), but streamed scenes and third-party shaders
can add techniques without bound. The pipeline cache files are already bounded;
memory is not.

Measure before building eviction: live `VkPipeline` count, process RSS after
cycling material and lighting modes, and the time to rebuild an evicted variant
from the disk cache. If the fixed scene and its worst material set stay small,
an explicit unload at scene teardown may be enough.

- [ ] Track the live variant count and the last frame each variant was drawn.
      Add both to the debug summary next to the compiled and cached counts.
- [ ] Decide the trigger: a variant cap, a memory cap, idle frames, or an
      explicit scene unload. Pick a default only after measuring.
- [ ] Make `LazyPipeline` hold a shared handle instead of a copied
      `GraphicsPipelineCfg`, so eviction can invalidate every copy at once.
- [ ] Add `LogicalDevice.destroyPipeline(VkPipeline)` that removes the handle
      from the device registry before destroying it; `pipelinesDtor` must not
      see a stale handle.
- [ ] Defer destruction until no recorded frame can still reference the
      pipeline: wait for the frame fences or use a retire queue like
      `SwapChain.oldSwapchainFrames`.
- [ ] Keep the pipeline layout, set layout and descriptor pool until their last
      pipeline goes, or decide that techniques are never removed.
- [ ] Drop the `PipelineFactory` cache entry on eviction, so the next `acquire`
      reloads the variant from `PipelineCacheStore` instead of compiling cold.
- [ ] Do not evict a variant that the current preload query still reports.
- [ ] Treat `VK_EXT_shader_object` separately: shader objects have their own
      lifetime and do not remove the need for this policy.

Open questions:

- Is the engine's own set bounded enough that only third-party techniques need
  eviction?
- Should eviction be global LRU or scoped to a scene or loader?
- Does `vkDestroyPipeline` return memory promptly on the target drivers, or is
  the win only visible at scene teardown?
- Keep the disk cache record when a pipeline is evicted, so the rebuild is
  cheap; dropping it would trade memory for compile time.

### Pipeline creation and identity

- [ ] Move the registry out of `pukan.vulkan.pipelines` into a generic
      `pukan.pipelines` module.

### Pipeline warmup policy

- [ ] Include third-party technique variants in `Variants!`. For now only the
      built-in `PbrVariant` descriptors are listed.
- [ ] Add glTF variants to a Godot-only build only when that build actually
      imports glTF; otherwise the first imported instance throws.

### Pipeline cache strategies

The store is currently one file per instance slot, with the shader digest in
the header, seeded into a fresh `VkPipelineCache` for each creation, and
bounded by an LRU sweep. Other strategies are possible and should be compared
before the format spreads:

- [ ] One cache per instance (current) versus one shared cache for the device
      or scene. A shared cache can merge blobs and create in batches, but makes
      invalidation coarser and the file larger.
- [ ] Per-instance files versus one archive with a manifest. The archive avoids
      thousands of small files but needs compaction.
- [ ] Seed once per run, or merge stored blobs with `vkMergePipelineCaches`
      before creating. Merging costs CPU at startup but may raise hit rates.
- [ ] Store driver blobs only, or store the instance state and rebuild the
      create info from it. The second allows validation and migration, the
      first is smaller.
- [ ] Bound by bytes, record count, age or scene. The current caps are 100 MB
      and 4096 records; measure hit rate against each.
- [ ] Decide whether an evicted pipeline also drops its cache record, or keeps
      it for a cheap rebuild.

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

## Module selection

`pukan/package.d` and `pukan/vulkan/package.d` re-export everything, and 38
library files import the `pukan.vulkan` umbrella themselves, so any entry point
reaches 93 of the 94 modules. Importing one module costs what importing the
whole engine costs.

- [ ] Replace the internal `import pukan.vulkan;` and `import pukan;` with
      explicit imports. That alone drops the closure to 35 modules from
      `pukan.scene`, 28 from `pukan.gltf` and 18 from `pukan.vulkan.core`,
      with no public API change.
- [ ] Then decide whether the two umbrellas stay as an opt-in import or go.
      Deleting them breaks `import pukan;` and makes the module layout part of
      the contract, so it comes after the internal cleanup.
- `public import` and plain `import` compile the same; only deleting a line
  helps. The library build compiles all sources either way, so the gain is on
  the application side: 3.2 s against 0.4 s and 5 MB against 0.6 MB for a
  trivial app.

## Offscreen output

- [ ] Use the offscreen path for benchmarks and CI: the fixed scene then
      measures GPU work without present timing or vsync, and the run needs no
      display server.
- [ ] Put the swapchain and the offscreen target behind one interface instead
      of the `SwapChain` mode flag.

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

The Quake motor is the reference implementation: `usercmd`, fixed `pmove`, snapshots and
prediction. CMC and Godot models must stay deterministic if they are networked later.

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
