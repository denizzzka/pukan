module pukan.vulkan.surface;

import pukan.vulkan.bindings;
import pukan.vulkan.requirements: Requirement, getOptionalRequirements;
import pukan: toPrettyString;
import std.meta: AliasSeq;

/// Instance requirements for creating window surfaces
struct WindowSurface
{
    private alias requirements = AliasSeq!(Requirement!(VK_KHR_SURFACE_EXTENSION_NAME));

    private alias optionalRequirements = getOptionalRequirements!(
        Requirement!("VK_KHR_xlib_surface"),
        Requirement!("VK_KHR_xcb_surface"),
        Requirement!("VK_KHR_wayland_surface"),
        Requirement!("VK_KHR_win32_surface"),
        Requirement!("VK_EXT_metal_surface"),
        Requirement!("VK_MVK_macos_surface"),
    );
}

mixin template SurfaceMethods()
{
    void printSurfaceFormats(VkPhysicalDevice pd, VkSurfaceKHR surface)
    {
        auto fmts = getArrayFrom!vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surface);
        log_info(fmts);
    }

    void printPresentModes(VkPhysicalDevice pd, VkSurfaceKHR surface)
    {
        auto modes = getArrayFrom!vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surface);
        //~ log_info(modes.toPrettyString);
    }

    auto getSurfaceCapabilities(VkPhysicalDevice pd, VkSurfaceKHR surface)
    {
        VkSurfaceCapabilitiesKHR c;
        vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surface, &c).vkCheck;

        return c;
    }
}
