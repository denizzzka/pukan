import pukan;
import raylib;
import std.stdio;
import std.string: toStringz;

enum fps = 60;
enum width = 640;
enum height = 640;

//~ struct Clock
//~ {
    //~ float start_time;
    //~ float elapsed;
//~ }

//~ Clock getClock()
//~ {
	//~ Clock r;
	//~ r.el
	//~ GetTime
//~ }

void main() {
	immutable name = "D/pukan3D/Raylib project";

    InitWindow(width, height, name.toStringz);
    SetTargetFPS(fps);
    auto vk = new Backend(name, makeApiVersion(1,2,3,4));
    vk.printAllAvailableLayers();

    while(!WindowShouldClose()) {
        // process events
        // update
        // render
        BeginDrawing();
        ClearBackground(Colors.WHITE);
        
        // draw stuff
        
        EndDrawing();
    }

    CloseWindow();
}
