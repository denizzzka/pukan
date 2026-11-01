module pukan.physics.simulation;

import pukan.physics.world: CollisionWorld;

/// Fixed-step accumulator over a collision world
final class Simulation
{
    CollisionWorld world;
    float tickRate = 60.0f;
    uint maxStepsPerFrame = 8;

    private double accumulator = 0.0;
    private double tickDuration = 1.0 / 60.0;

    private enum accumulatorEpsilon = 1e-9;

    this(CollisionWorld world = null)
    {
        this.world = world;
    }

    void setTickRate(float rate)
    {
        tickRate = rate;
        tickDuration = 1.0 / rate;
    }

    /// Runs whole ticks for `frameSeconds`; the rest waits for the next frame
    void step(double frameSeconds, scope void delegate(float dt) tick)
    {
        if(frameSeconds < 0.0)
            frameSeconds = 0.0;

        accumulator += frameSeconds;

        uint steps;

        while(accumulator + accumulatorEpsilon >= tickDuration && steps < maxStepsPerFrame)
        {
            tick(cast(float) tickDuration);
            accumulator -= tickDuration;

            if(accumulator < 0.0)
                accumulator = 0.0;

            ++steps;
        }

        if(steps == maxStepsPerFrame && accumulator >= tickDuration)
            accumulator = 0.0;
    }

    /// Fraction of a tick left for render interpolation
    float interpolationAlpha() const
    {
        return cast(float) (accumulator / tickDuration);
    }
}

unittest
{
    auto simulation = new Simulation;
    uint ticks;

    foreach(i; 0 .. 60)
        simulation.step(1.0 / 60.0, (dt) { ++ticks; });

    assert(ticks == 60);
    assert(simulation.interpolationAlpha() < 1e-5f);

    ticks = 0;
    simulation.step(10.0, (dt) { ++ticks; });

    assert(ticks == 8);
    assert(simulation.interpolationAlpha() == 0.0f);

    simulation.setTickRate(120.0f);
    ticks = 0;

    foreach(i; 0 .. 120)
        simulation.step(1.0 / 120.0, (dt) { ++ticks; });

    assert(ticks == 120);
}
