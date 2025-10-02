module pukan.vulkan.surface;

import pukan.vulkan.bindings;
import pukan: toPrettyString;

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
