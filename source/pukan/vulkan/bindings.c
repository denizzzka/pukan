// This trampoline file is need because importC can't import .h files directly

#include <vulkan/vulkan.h>

/* It is not necessary, vulkan.h doeas the same perfeclty */
#if 0
#ifdef _WIN32
    #include <windows.h> // It's important thing for Windows!
    #include <vulkan/vulkan_win32.h>
#else
    // Posix
    #include <xcb/xcb.h>
    #include <vulkan/vulkan_xcb.h>
    #include <vulkan/vulkan_wayland.h>
#endif
#endif
