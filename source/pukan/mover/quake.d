module pukan.mover.quake;

import dlib.math: Vector3f, dot;
import std.algorithm: min;

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
    uint maxSlides = 4;
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

    const accelSpeed = min(airAccelerate * wishSpeed * dt, addSpeed);

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
