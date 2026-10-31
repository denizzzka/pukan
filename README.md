(It's a testing ground now)

The rules are simple:

* The code is D-ideomatic
* No premature optimization
* No backward compatibility
* Games support is important, but Vulkan is used not only for games but also for creating GUI, industry, science graphics and headless computing.
Don't forget about that.
* Ideas, patches, discussions, bugreports are welcome!

## Feature selection

Rendering features are chosen at compile time, not at startup. A build carries
only the passes, pipelines and shader variants the project actually uses, so
there is no unused rendering code and no universal shader branching across
features it never enables.
