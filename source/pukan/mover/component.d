module pukan.mover.component;

import dlib.math: Vector3f;
import pukan.mover.quake:
    QuakeBody,
    QuakeCommand,
    QuakeMovementConfig,
    QuakeMoveResult,
    QuakeMoveState,
    pmMove;
import pukan.physics.world: CollisionWorld;

/// Owns one body's Quake movement state
final class MoverComponent
{
    CollisionWorld world;
    QuakeBody body;
    QuakeMovementConfig config;
    QuakeMoveState state;
    Vector3f previousPosition;

    this(
        CollisionWorld world,
        QuakeBody body = QuakeBody(),
        QuakeMovementConfig config = QuakeMovementConfig(),
    )
    {
        this.world = world;
        this.body = body;
        this.config = config;
        state.groundNormal = body.up;
    }

    void setNoclip(bool enabled)
    {
        state.noclip = enabled;
    }

    void teleport(in Vector3f position)
    {
        state.position = position;
        state.velocity = Vector3f(0, 0, 0);
        state.onGround = false;
        state.groundNormal = body.up;
        previousPosition = position;
    }

    /// One fixed motor tick; updates `state` and returns what moved
    QuakeMoveResult step(in QuakeCommand command, float dt)
    {
        previousPosition = state.position;

        const result = pmMove(world, state, command, dt, body, config);

        state.position = result.position;
        state.velocity = result.velocity;
        state.onGround = result.onGround;
        state.groundNormal = result.groundNormal;

        return result;
    }

    /// Position between the last and current tick, for rendering
    Vector3f renderPosition(float alpha) const
    {
        return previousPosition + (state.position - previousPosition) * alpha;
    }

    Vector3f eyePosition(float alpha = 1.0f) const
    {
        return renderPosition(alpha) + body.up * body.eyeHeight;
    }
}

unittest
{
    QuakeBody body;
    body.radius = 0.4f;
    body.height = 1.8f;

    auto mover = new MoverComponent(null, body);
    mover.teleport(Vector3f(1, 2, 3));

    assert(mover.state.position == Vector3f(1, 2, 3));
    assert(mover.eyePosition() == Vector3f(1, 3.6f, 3));

    mover.previousPosition = Vector3f(1, 2, 3);
    mover.state.position = Vector3f(2, 2, 3);

    assert(mover.renderPosition(0.5f) == Vector3f(1.5f, 2, 3));
}
