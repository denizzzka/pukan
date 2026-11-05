# Point shadow

One point light and a cube on a floor. `--no-sun-shadows` leaves the point
light's shadow as the only one:

    ./demo_godot/pukan_demo_godot --scene demo_godot/godot_samples/point_shadow/point_shadow.tscn \
        --eye 0,3,-6 --target 0,0.3,0 --no-sun-shadows --screenshot point.png

Without `--no-local-shadows` the floor is lit through the cube.
