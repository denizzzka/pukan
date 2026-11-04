# Plan

Checkboxes track open work. Items can be done in any order; the order below is
only a suggested grouping.

## CI

The workflow in `.github/workflows/ci.yml` fails on GitHub Actions: the run exits
non-zero and the Vulkan library reports an error on the way out, so the job ends
on the exit path rather than on a check it makes.

- [ ] Reproduce the run under Xvfb and lavapipe and find what the Vulkan library
      complains about at exit, then fix the exit or the teardown it reports.
      Keep the job green only when nothing real is behind the message.

## Reported bugs

Symptoms as reported, cause unknown; an item stays open until the fixed scene
shows it gone.

- [ ] `platformer`: the character passes through some corners of vertical walls,
      and through single wall columns, not only through their corners. It rests
      on the narrowphase and sweep work in `#### Phase 1: collision world`.
- [ ] `platformer`: white dots show in the seams of the brown vertical walls
      while the camera turns. Decide which one it is: a crack between coplanar
      triangles, depth precision, or a shading alias.

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
  `pukan.graphics.common.misc.Boxf` keep min and max and need union, sweep and surface area.
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
- [ ] `project.binary`: decode object-typed settings (variant type 24), the
      resource references newer exports carry. `platformer.pck` and
      `generated/fixtures.pck` fail to load until then.
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
- [ ] The default character set is an optional preset: capsule plus ground, air, water
      and noclip modes.
- [ ] Other presets (vehicle, projectile, quadruped, flying pawn) assemble modes without
      the character set and without a capsule.

### Collision world

`pukan.physics` owns shapes, the broadphase and the queries. It knows nothing
about Godot, rendering or the motor. `godot_scene` decodes collision nodes and
shape resources and adds them with world transforms. `mover` consumes queries
only and never walks the scene tree.

- [ ] A moved kinematic collider refits its leaf or rebuilds the tree.
- [ ] `RayHit` and `ShapeCastHit` share time of impact, point, normal, penetration depth,
      collider and node.
- [ ] Compare `pukan.bvh` with `dagon.collision.bvh` (SAH, generic, with box,
      sphere and ray traversal) before growing it further; keep ours only where
      the streaming rebuild and the per-cell trees demand differ.
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
- [ ] Numeric defaults follow Godot: safe margin 0.001 m, floor max angle 45 degrees,
      floor snap 0.1 m, wall minimum slide angle 15 degrees, at most 4 slides.

#### Colliders from Godot

- [ ] Collision data lives on `GodotNode` and needs no device, so a headless server can
      load a level and build the same world without Vulkan.
- [ ] `GodotLoadOptions.collisionFromMeshes` turns a `MeshInstance3D` without a body into
      a concave collider; off by default because the town would pay for every tree.
- [ ] glTF instances can contribute concave colliders behind their own option, off by
      default for the same reason.
- [ ] `RayCast3D` becomes a ray query for the camera spring arm and debug, not a
      collider.
- [ ] `Area3D` volumes are query-only; they never block the body.

### Movement modes as modules

- [ ] `MovementMode` is an interface with hooks such as `onGenerateMove` and
      `onSimulationTick`, not a switch inside one update function. Ground, air, water,
      noclip and custom are separate modules.
- [ ] Modes declare the shared settings they need (gravity, speeds, friction, step
      height); `MoverComponent` deduplicates them, so ground and air read one instance.
- [ ] `water`: reduced gravity, water friction and buoyancy, swim up and down, no
      step-up or floor snap; leaving the volume switches back to `air` or `ground`.
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

Mover does not own device input. It consumes a `usercmd`-style command struct that the
project fills from keyboard, mouse, gamepad, touch, AI or a replay. The engine supplies
the contract, not the binding.

- [ ] `CharacterInput` carries the Quake `usercmd` fields: wish direction, wish speed,
      jump, crouch, attack, use, view angles and tick. The default character preset
      ships it as an example; games add their own fields.
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

- [ ] `isRootMotion`: report whether a clip moves the character in world space,
      using the node `MotionSampler` treats as the root (schema root bone, else
      the first joint of the first skin, else the scene root). Compare the first
      and last keyframes of its translation track; ignore tracks that return to
      the start and net displacements below a small threshold, so body bob and
      constant tracks do not count. Fixtures: `Fox/Walk` (loops back),
      `CesiumMan`, `AnimatedCube` and `platformer/enemy` (constant `MASTER`
      translation) stay in place, while `motion/UAL1_Standard_RM.glb` carries
      both, `Crouch_Fwd_Loop` moves 1.5 m and `Crouch_Idle_Loop` does not.
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

- [ ] `pukan.physics.narrowphase`: segment-triangle distance, GJK distance, conservative
      advancement and the plane and sphere fast paths.
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
- [ ] `pmove` is deterministic and versioned; behavior parity with Godot's
      `moveAndSlide`, not numeric parity.
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

- [ ] An empty capsule with no collision follows the tick and interpolates in the demo.

#### Phase 1: collision world

- [ ] `CollisionWorld` BVH, ray query, shape cast and overlap query.
- [ ] Weld triangle vertices and filter internal edges.
- [ ] Unit tests for every shape pair, ray hit and cast time of impact; a triangle mesh
      floor, a box wall, a ramp, a capsule body and a box body.
- [ ] Measure the BVH build time on the platformer stage and the town, and the cast cost.
- [ ] `demo_godot --debug-collision` draws every collider and the result of a camera ray.

#### Phase 2: Quake motor

- [ ] `pmove` with ground, air, water and noclip modes and `MovementTransition`s.
- [ ] Crouch changes the capsule height and checks the ceiling before standing up.
- [ ] Water move with reduced gravity, water friction and swim up and down.
- [ ] Moving platform velocity, floor locking and platform rotation with
      `AnimatableBody3D` writeback.
- [ ] Unit tests: walk up a ramp, step onto a 0.45 m ledge, jump and land, slide along a
      wall, strafe jump speed gain, bunny hop, water, noclip, and no tunneling.

#### Phase 3: input, camera and demo

- [ ] `CharacterInput` from GLFW: WASD, mouse look, Space, Ctrl and attack.
- [ ] The spring arm only shortens on a ray from the eye, so dropping off a ledge leaves the
      camera on the old line and inside the block behind it; sweep a sphere, or push the
      camera out of the colliders it ended up in.
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

### Rig mapping

- [ ] glTF node names are not unique and a lookup takes the first match, so a
      debug build must check that a name resolves to exactly one node and assert
      otherwise. Write the check in idiomatic D.
- [ ] Map the bones of a glTF model onto a motion matching rig automatically:
      their names almost always carry the usual words, which is enough to pair
      them. Throw an exception when a bone has no counterpart.

### Database

Motion matching indexes animation instead of playing it: every clip is sampled ahead of time,
and the samples become points in a feature space. First slice: one skeleton, one database,
locomotion only.

- [ ] No normalization in the first slice: weights carry the units, so a cost is comparable
      only inside one database.

### Later

- [ ] KD-tree or VP-tree over the feature vectors, once a profile shows the scan matters.
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

Order: the cell partition first, because everything else addresses cells; then
the flat part list a drawable registers once, because both streaming and the
draw list work on parts; then loading and unloading around the camera; then
per-view culling and GPU-driven draws; then LOD, occlusion, shadows and
collision streaming on top. Cells decide what exists, culling decides what is
drawn, so a cell can never be unloaded while a recorded frame still holds one of
its parts. Every slice is measured at cell borders, where its cost shows up.
Before each slice, read the matching reference named in
`## Look at the dependencies first`: `dagon.openworld` for the cell grid,
`dagon.collision.bvh` for the index and `dagon.graphics.lod` for LOD.

- **Cells and coordinates**

  The grid is in: `CellGrid` holds the cell extent per axis and the level
  origin, `Scene.cellGrid` owns it, and `SceneTree.rebuildCells` places every
  part in each cell its transformed bounds touch. Loaded scenes implement
  `PartDrawable` and report each mesh with its own transform, so a level lands in
  cells per object; a drawable that reports nothing stays visible from every
  cell, and a part without bounds contributes its origin. `calcAABB` keeps the
  real extents while `cellBounds` adds the origins. `Residency` keeps cells alive
  around a list of `StreamingSource`s: each carries a range, a priority and a
  state, the angle to a cell stretches its distance, and the retire delay covers
  the frames in flight. `demo_godot` loads, draws and frees the cells around the
  camera by default, on one tall layer of square cells like Unreal's runtime
  hash: it keeps at most 16 cells loading, uploads a byte budget per frame and
  stalls the body while the camera's cell is still arriving. `--cell-range` sets
  the distance and `--no-cells` loads every cell at start.

  Still open:

  - [ ] Floating origin: keep the camera at the origin and shift cell
        transforms, so single-precision positions stay precise far from the
        start.
  - [ ] Decide whether `Matrix4x4f` becomes double precision or only the cell
        offsets do, and measure the vertex cost of the second on the fixed
        scene.

- **Spatial index and GPU-driven draws**

  Cells bound the distance step, each cell's `BoxBvh` answers the frustum and a
  ray, and `demo_godot --pick` reports what a ray hits, so neither a view nor a
  pick walks every part.
  - [ ] Keep the CPU path as the fallback and as the reference for the GPU
        results; judge it on 10k, 100k and 1M instances. The GPU pass keeps a
        mesh's instances in a storage buffer, culls them in a compute kernel and
        draws them with `vkCmdDrawIndexedIndirectCount`; `--no-gpu-cull` keeps
        the CPU path. The dev machine falls back to llvmpipe, where the kernel
        runs on the CPU, so the numbers wait for a working GPU driver.

- **LOD and HLOD**

  A mesh carries a list of index lists, the authored one first, and the draw
  picks one by its screen-space error, on the CPU and in the cull kernel alike.
  Generated cluster levels fill the list today; a skinned mesh keeps the
  authored level, so its pose stays correct.

  Far cells are cheap by two steps. A cell beyond `--impostor-distance` is one
  card captured from the direction it arrived from. A cell beyond
  `--proxy-distance` merges its static parts into one mesh per material, clipped
  to the cell; the merge runs as the cell arrives, on a byte budget per frame,
  from the CPU side of the pieces the cell already holds. A proxy draws the
  merged list alone, because generated levels leave holes where every tile keeps
  its own vertices.
  - [ ] Authored levels: fill the list from glTF `MSFT_lod` and from what the
        Godot importer stores, instead of only from the generated ones.
  - [ ] The generated field's ground tiles do not appear through the cull
        kernel, though `--no-gpu-cull` draws them and one such tile alone draws
        through the kernel: find it before the ring numbers on the field mean
        anything. `bench/hlod.md` has the counts.
  - [ ] A proxy costs a descriptor set and a merge per cell, which the field's
        24,964 cells make heavy: batch the proxies of a cell or share one
        material set across them.
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
  - [ ] Rebind fresh memory to a kept `VkBuffer` instead of destroying it on
        release, so the geometry keeps its handles and no `buildGeometry` pass
        is needed. It needs an allocator that owns memory apart from the buffer.
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
  - [ ] Counters in the spirit of `stat initviews`: parts processed, culled by
        cell, culled by frustum, drawn; cells loaded, pending and retired; the
        time each step took.

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

## Vk object ownership

A Vulkan handle is a value: copying it transfers nothing. Ownership lives in
the objects that hold handles, never in the handle. Two mechanisms cover every
case, and the choice is a property of the slot, not of the resource type:

- `VkObj!Handle` is a move-only struct for a slot that one object owns and
  replaces in place. Its destructor releases the handle, `release()` frees it
  early and keeps the slot, and a struct field is destroyed in reverse
  declaration order, so a view declared after its image goes first.
- `ResourceOwner` is a class for a group created and released together: a
  scene, a frame set, a cell. It keeps its holders alive and calls `destroy` on
  them newest first; `mark` and `releaseTo` unload a cell in one call.
  `ResourceOwner!false` drops the lock and the thread check for a subtree that
  one worker fills before handing it over.

Rules, and the debug nets that hold them:

- A stored handle is borrowed. Only the owning holder frees it, and a borrower
  must live inside that holder's lifetime. `VkObj` zeroes the handle on release
  and asserts on use, so a stale holder cannot pass a dead handle silently.
- `own` means exclusive. A shared mesh or texture stays in the longer-lived
  owner (asset, scene) and cells take counted references, as `meshRefs` and
  `pieceRefs` do today.
- Debug builds count live handles per kind. Every count must be zero at device
  teardown; a non-zero count names a holder that nobody adopted.

Where it stands: `pukan.vulkan.resources.ownership` and
`pukan.vulkan.resources.vkobj` hold the two mechanisms and their unit tests.
Descriptor pools and set layouts belong to the pipeline factory's owner, and a
scene holds its lifetime in one owner plus a screen owner that a swapchain
rebuild replaces. A `VkObj` never calls the driver from a destructor: it hands
the handle to a queue that frees it once the frames in flight pass, and an
owner hands its holders to the same queue.

- [ ] Move the impostor capture targets onto the scene owner once that work
      lands.
- [ ] Split the tree into threaded and per-thread owners once a real
      multi-threaded loader lands. `mark` and `releaseTo` stay a pair on one
      thread either way.

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

`pukan/package.d` re-exports everything, and five library and demo files still
import it, so any entry point reaches 93 of the 94 modules. Importing one module
costs what importing the whole engine costs.

- [ ] Replace the internal `import pukan;` with explicit imports. That alone
      drops the closure to 35 modules from `pukan.graphics.g3d.scene`, 28 from
      `pukan.gltf` and 18 from `pukan.vulkan.core`.
- [ ] Then decide whether `pukan` stays as an opt-in import or goes. Deleting it
      breaks `import pukan;` and makes the module layout part of the contract,
      so it comes after the internal cleanup.
- `public import` and plain `import` compile the same; only deleting a line
  helps. The library build compiles all sources either way, so the gain is on
  the application side: 3.2 s against 0.4 s and 5 MB against 0.6 MB for a
  trivial app.

## Swapchain creation

`SwapChain` hardcodes `minImageCount: 3` and only checks that
`cap.maxImageCount >= 3`, so a surface that requires more images fails
validation and then `vkCreateSwapchainKHR`. Choose the count from the
capabilities range, keeping three when the range allows it.

- [ ] Choose `minImageCount` as `max(3, cap.minImageCount)`, capped by
      `cap.maxImageCount` unless it is zero.

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
