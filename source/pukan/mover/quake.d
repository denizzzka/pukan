module pukan.mover.quake;

import dlib.math: Vector3f, dot;
import pukan.physics.narrowphase: sweepCapsuleBox;
import pukan.physics.world: CollisionWorld;
import std.algorithm: min;
import std.math: cos;

/// Quake 3 movement tunables, in meters and seconds
struct QuakeMovementConfig
{
    float maxSpeed = 320 * 0.0254f;
    float accelerate = 10.0f;
    float airAccelerate = 1.0f;
    float friction = 6.0f;
    float stopSpeed = 100 * 0.0254f;
    float gravity = 800 * 0.0254f;
    float jumpVelocity = 270 * 0.0254f;
    float maxStepHeight = 18 * 0.0254f;
    float overbounce = 1.001f;
    float floorMaxAngle = 0.785398f;
    float safeMargin = 0.001f;
    uint maxSlides = 4;
}

/// Capsule dimensions and collision filter of one body
struct QuakeBody
{
    Vector3f up = Vector3f(0, 1, 0);
    float radius = 0.4f;
    float height = 1.8f;
    float eyeHeight = 1.6f;
    uint mask = 1;
}

/// One movement command, the Quake `usercmd`
struct QuakeCommand
{
    Vector3f wishDir;
    float wishSpeed;
    bool jump;
}

/// Movement state carried between ticks
struct QuakeMoveState
{
    Vector3f position;
    Vector3f velocity;
    bool onGround;
    bool noclip;
    Vector3f groundNormal = Vector3f(0, 1, 0);
}

/// What one `pmMove` produced
struct QuakeMoveResult
{
    Vector3f position;
    Vector3f velocity;
    bool onGround;
    Vector3f groundNormal = Vector3f(0, 1, 0);
    bool hitWall;
    uint slides;
}

/// Ground friction, Quake `PM_Friction`
Vector3f pmFriction(Vector3f velocity, float dt, float friction, float stopSpeed)
{
    const speed = velocity.length;
    if(speed < 1e-6f)
        return Vector3f(0, 0, 0);

    const control = speed < stopSpeed ? stopSpeed : speed;
    const newSpeed = speed - control * friction * dt;

    return newSpeed > 0 ? velocity * (newSpeed / speed) : Vector3f(0, 0, 0);
}

/// Ground acceleration toward `wishDir`, Quake `PM_Accelerate`
Vector3f pmAccelerate(
    Vector3f velocity,
    Vector3f wishDir,
    float wishSpeed,
    float accelerate,
    float dt,
)
{
    const addSpeed = wishSpeed - dot(velocity, wishDir);
    if(addSpeed <= 0)
        return velocity;

    const accelSpeed = min(accelerate * wishSpeed * dt, addSpeed);

    return velocity + wishDir * accelSpeed;
}

/// Air acceleration, Quake `PM_AirAccelerate`
Vector3f pmAirAccelerate(
    Vector3f velocity,
    Vector3f wishDir,
    float wishSpeed,
    float airAccelerate,
    float dt,
)
{
    const addSpeed = wishSpeed - dot(velocity, wishDir);
    if(addSpeed <= 0)
        return velocity;

    enum airAccelCap = 30 * 0.0254f;
    const accelSpeed = min(min(airAccelerate * wishSpeed * dt, addSpeed), airAccelCap);

    return velocity + wishDir * accelSpeed;
}

/// Removes the velocity component into a plane, Quake `PM_ClipVelocity`
Vector3f pmClipVelocity(Vector3f velocity, Vector3f normal, float overbounce)
{
    const backoff = velocity.dot(normal) * overbounce;

    return velocity - normal * backoff;
}

/// Sets the component along `up` to the jump velocity, Quake `PM_Jump`
Vector3f pmJump(Vector3f velocity, Vector3f up, float jumpVelocity)
{
    return velocity + up * (jumpVelocity - dot(velocity, up));
}

/// Applies gravity along `up`, Quake `PM_AddGravity`
Vector3f pmGravity(Vector3f velocity, Vector3f up, float gravity, float dt)
{
    return velocity - up * (gravity * dt);
}

private Vector3f capsuleBottom(in Vector3f feet, in QuakeBody body)
{
    return feet + body.up * body.radius;
}

private Vector3f capsuleTop(in Vector3f feet, in QuakeBody body)
{
    return feet + body.up * (body.height - body.radius);
}

private float horizontalLength(in Vector3f delta, in Vector3f up)
{
    return (delta - up * dot(delta, up)).length;
}

private QuakeMoveResult pmSlideMove(
    CollisionWorld world,
    Vector3f position,
    Vector3f velocity,
    float dt,
    in QuakeBody body,
    in QuakeMovementConfig config,
    bool startsOnGround,
)
{
    QuakeMoveResult result;
    result.position = position;
    result.velocity = velocity;
    result.onGround = startsOnGround;
    result.groundNormal = body.up;

    const floorLimit = cos(config.floorMaxAngle);
    float timeLeft = dt;

    foreach(slide; 0 .. config.maxSlides)
    {
        if(timeLeft <= 1e-6f)
            break;

        const motion = result.velocity * timeLeft;

        if(motion.length < 1e-8f)
            break;

        const hit = world.sweepCapsule(
            capsuleBottom(result.position, body),
            capsuleTop(result.position, body),
            body.radius,
            motion,
            body.mask,
            config.safeMargin,
        );

        if(!hit.hit)
        {
            result.position += motion;
            break;
        }

        // A resting contact must not block motion away from it
        if(hit.fraction <= 1e-6f && dot(motion, hit.normal) >= 0.0f)
        {
            result.position += hit.normal * config.safeMargin;
            continue;
        }

        result.position += motion * hit.fraction;
        result.position += hit.normal * config.safeMargin;
        timeLeft -= timeLeft * hit.fraction;
        ++result.slides;

        const normalDot = dot(hit.normal, body.up);

        if(normalDot > floorLimit)
        {
            result.onGround = true;
            result.groundNormal = hit.normal;
        }
        else if(normalDot > -floorLimit)
            result.hitWall = true;

        result.velocity = pmClipVelocity(result.velocity, hit.normal, config.overbounce);

        if(result.velocity.length < 1e-4f)
            break;
    }

    return result;
}

private QuakeMoveResult pmStepSlideMove(
    CollisionWorld world,
    Vector3f position,
    Vector3f velocity,
    float dt,
    in QuakeBody body,
    in QuakeMovementConfig config,
    bool startsOnGround,
)
{
    auto flat = pmSlideMove(world, position, velocity, dt, body, config, startsOnGround);

    if(!startsOnGround || !flat.hitWall)
        return flat;

    const upHit = world.sweepCapsule(
        capsuleBottom(position, body),
        capsuleTop(position, body),
        body.radius,
        body.up * config.maxStepHeight,
        body.mask,
        config.safeMargin,
    );

    const upBlocked = upHit.hit
        && dot(upHit.normal, body.up) < -cos(config.floorMaxAngle);
    const upFraction = upBlocked ? upHit.fraction : 1.0f;
    const raised = position + body.up * (config.maxStepHeight * upFraction);

    auto stepVelocity = velocity;
    const vertical = dot(stepVelocity, body.up);

    if(vertical < 0.0f)
        stepVelocity -= body.up * vertical;

    auto forward = pmSlideMove(world, raised, stepVelocity, dt, body, config, false);

    const flatDistance = horizontalLength(flat.position - position, body.up);
    const forwardDistance = horizontalLength(forward.position - position, body.up);

    if(forwardDistance <= flatDistance)
        return flat;

    forward.onGround = false;
    forward.hitWall = false;

    const downHit = world.sweepCapsule(
        capsuleBottom(forward.position, body),
        capsuleTop(forward.position, body),
        body.radius,
        -body.up * config.maxStepHeight,
        body.mask,
        config.safeMargin,
    );

    if(downHit.hit && dot(downHit.normal, body.up) > cos(config.floorMaxAngle))
    {
        auto stepped = forward;
        stepped.position = forward.position - body.up * (config.maxStepHeight * downHit.fraction);
        stepped.onGround = true;
        stepped.groundNormal = downHit.normal;

        if(dot(stepped.position - position, body.up) > config.maxStepHeight * 0.5f)
            return stepped;
    }

    return forward;
}

/// One Quake `pmove` tick
QuakeMoveResult pmMove(
    CollisionWorld world,
    QuakeMoveState state,
    in QuakeCommand command,
    float dt,
    in QuakeBody body = QuakeBody(),
    in QuakeMovementConfig config = QuakeMovementConfig(),
)
{
    auto velocity = state.velocity;
    Vector3f wishDir = command.wishDir;

    if(wishDir.length > 1e-6f)
        wishDir = wishDir.normalized;
    else
        wishDir = Vector3f(0, 0, 0);

    const wishSpeed = min(command.wishSpeed, config.maxSpeed);

    if(state.noclip)
    {
        const noclipVelocity = wishDir * wishSpeed;
        QuakeMoveResult result;
        result.position = state.position + noclipVelocity * dt;
        result.velocity = noclipVelocity;
        result.onGround = false;
        result.groundNormal = body.up;

        return result;
    }

    bool onGround = state.onGround;

    if(onGround)
    {
        velocity = pmFriction(velocity, dt, config.friction, config.stopSpeed);
        velocity = pmAccelerate(velocity, wishDir, wishSpeed, config.accelerate, dt);
        velocity = pmGravity(velocity, body.up, config.gravity, dt);

        if(command.jump)
        {
            velocity = pmJump(velocity, body.up, config.jumpVelocity);
            onGround = false;
        }
    }
    else
    {
        velocity = pmGravity(velocity, body.up, config.gravity, dt);
        velocity = pmAirAccelerate(velocity, wishDir, wishSpeed, config.airAccelerate, dt);
    }

    return pmStepSlideMove(world, state.position, velocity, dt, body, config, onGround);
}

unittest
{
    import std.math: abs;

    QuakeMovementConfig cfg;
    assert(abs(cfg.maxSpeed - 8.128f) < 1e-3f);
    assert(abs(cfg.jumpVelocity - 6.858f) < 1e-3f);
    assert(abs(cfg.gravity - 20.32f) < 1e-3f);
    assert(abs(cfg.maxStepHeight - 0.4572f) < 1e-3f);

    const dt = 1.0f / 60.0f;

    auto slow = pmFriction(Vector3f(0.1f, 0, 0), dt, cfg.friction, cfg.stopSpeed);
    assert(slow.length == 0);

    auto decayed = pmFriction(Vector3f(1, 0, 0), dt, cfg.friction, cfg.stopSpeed);
    assert(decayed.x > 0 && decayed.x < 1);

    auto accelerated = pmAccelerate(Vector3f(0, 0, 0), Vector3f(0, 0, 1), cfg.maxSpeed,
        cfg.accelerate, dt);
    assert(accelerated.z > 0 && accelerated.z < cfg.maxSpeed);

    auto air = pmAirAccelerate(Vector3f(1, 0, 0), Vector3f(0, 1, 0), cfg.maxSpeed,
        cfg.airAccelerate, dt);
    assert(air.x == 1 && air.y > 0 && air.y < 0.2f);

    auto clipped = pmClipVelocity(Vector3f(1, -1, 0), Vector3f(0, 1, 0), cfg.overbounce);
    assert(abs(clipped.x - 1) < 1e-5f);
    assert(clipped.y > 0 && clipped.y < 0.01f);
    assert(clipped.z == 0);

    auto jumped = pmJump(Vector3f(5, 1, 0), Vector3f(0, 1, 0), cfg.jumpVelocity);
    assert(jumped.x == 5);
    assert(abs(jumped.y - cfg.jumpVelocity) < 1e-5f);
    assert(jumped.z == 0);

    auto falling = pmGravity(Vector3f(0, 0, 0), Vector3f(0, 1, 0), cfg.gravity, dt);
    assert(falling.y < 0);
    assert(abs(falling.y + cfg.gravity * dt) < 1e-5f);
}

unittest
{
    import dlib.math: translationMatrix;
    import pukan.physics.shapes: Collider, CollisionShape;
    import std.math: abs;

    auto floor = new CollisionWorld;
    floor.add(Collider(
        CollisionShape.box(Vector3f(20, 1, 20)),
        Vector3f(0, -0.5f, 0).translationMatrix,
    ));
    floor.build();

    const body = QuakeBody();
    const config = QuakeMovementConfig();

    QuakeMoveState state;
    state.position = Vector3f(0, 0, 0);
    state.velocity = Vector3f(0, 0, 0);
    state.onGround = true;
    state.groundNormal = Vector3f(0, 1, 0);

    QuakeCommand walk;
    walk.wishDir = Vector3f(1, 0, 0);
    walk.wishSpeed = config.maxSpeed;
    walk.jump = false;

    foreach(i; 0 .. 60)
    {
        const result = pmMove(floor, state, walk, 1.0f / 60.0f, body, config);
        state.position = result.position;
        state.velocity = result.velocity;
        state.onGround = result.onGround;
        state.groundNormal = result.groundNormal;
    }

    assert(state.position.x > 1.0f);
    assert(abs(state.position.y) < 0.02f);
    assert(state.onGround);

    state.position = Vector3f(0, 0, 0);
    state.velocity = Vector3f(0, 0, 0);
    state.onGround = true;
    walk.jump = true;

    const jump = pmMove(floor, state, walk, 1.0f / 60.0f, body, config);

    assert(jump.position.y > 0.05f);
    assert(!jump.onGround);
    walk.jump = false;

    auto wallWorld = new CollisionWorld;
    wallWorld.add(Collider(
        CollisionShape.box(Vector3f(20, 1, 20)),
        Vector3f(0, -0.5f, 0).translationMatrix,
    ));
    wallWorld.add(Collider(
        CollisionShape.box(Vector3f(1, 4, 20)),
        Vector3f(3, 2, 0).translationMatrix,
    ));
    wallWorld.build();

    state.position = Vector3f(0, 0, 0);
    state.velocity = Vector3f(0, 0, 0);
    state.onGround = true;

    foreach(i; 0 .. 120)
    {
        const result = pmMove(wallWorld, state, walk, 1.0f / 60.0f, body, config);
        state.position = result.position;
        state.velocity = result.velocity;
        state.onGround = result.onGround;
        state.groundNormal = result.groundNormal;
    }

    assert(state.position.x < 2.2f);

    state.position = Vector3f(2.2f, 0, 0);
    state.velocity = Vector3f(0, 0, 0);
    state.onGround = false;
    state.noclip = true;
    walk.wishDir = Vector3f(1, 0, 0);
    walk.wishSpeed = 4.0f;

    const noclipMove = pmMove(wallWorld, state, walk, 0.5f, body, config);

    assert(noclipMove.position.x > 3.6f);
    assert(!noclipMove.onGround);
    state.noclip = false;

    auto stepWorld = new CollisionWorld;
    stepWorld.add(Collider(
        CollisionShape.box(Vector3f(20, 1, 20)),
        Vector3f(0, -0.5f, 0).translationMatrix,
    ));
    stepWorld.add(Collider(
        CollisionShape.box(Vector3f(20, 0.45f, 4)),
        Vector3f(12, 0.225f, 0).translationMatrix,
    ));
    stepWorld.build();

    float stepFraction;
    Vector3f stepPoint;
    Vector3f stepNormal;
    const directStep = sweepCapsuleBox(
        Vector3f(2.098f, 0.8565f, 0), Vector3f(2.098f, 1.8565f, 0), 0.4f,
        Vector3f(0, -0.457f, 0), Vector3f(12, 0.225f, 0).translationMatrix,
        Vector3f(10, 0.225f, 2), 0.001f, stepFraction, stepPoint, stepNormal);

    assert(directStep);
    assert(abs(stepFraction - 0.012f) < 0.01f);

    const stepRay = stepWorld.raycast(Vector3f(2.098f, 2, 0), Vector3f(0, -1, 0));

    assert(stepRay.hit);
    assert(abs(stepRay.t - 1.55f) < 0.01f);

    state.position = Vector3f(0, 0, 0);
    state.velocity = Vector3f(0, 0, 0);
    state.onGround = true;

    foreach(i; 0 .. 120)
    {
        const result = pmMove(stepWorld, state, walk, 1.0f / 60.0f, body, config);
        state.position = result.position;
        state.velocity = result.velocity;
        state.onGround = result.onGround;
        state.groundNormal = result.groundNormal;
    }

    assert(state.position.x > 2.5f);
    assert(state.position.y > 0.4f);

    state.position = Vector3f(0, 0, 0);
    state.velocity = Vector3f(5, 0, 0);
    state.onGround = true;
    walk.wishDir = Vector3f(0, 0, 0);
    walk.wishSpeed = 0;

    foreach(i; 0 .. 30)
    {
        const result = pmMove(floor, state, walk, 1.0f / 60.0f, body, config);
        state.position = result.position;
        state.velocity = result.velocity;
        state.onGround = result.onGround;
        state.groundNormal = result.groundNormal;
    }

    assert(state.velocity.length < 3.0f);
}
