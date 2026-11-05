# Spot shadow

One downward spot light and a cube on a floor. The cube's shadow is visible
with `--no-sun-shadows`, which leaves the spot's shadow as the only one:

    ./demo_godot/pukan_demo_godot --scene demo_godot/godot_samples/spot_shadow/spot_shadow.tscn \
        --eye 0,3,-6 --target 0,0.3,0 --no-sun-shadows --screenshot spot.png

Without `--no-spot-shadows` the same camera lights the floor through the cube.
