module pukan.renderer;

public import pukan.renderer.device;

import pukan.vulkan_sdk;
import pukan.exceptions;
import std.string: toStringz;

/// VK_MAKE_API_VERSION macros
uint makeApiVersion(uint variant, uint major, uint minor, uint patch)
{
    return ((((uint)(variant)) << 29U) | (((uint)(major)) << 22U) | (((uint)(minor)) << 12U) | ((uint)(patch)));
}

class Backend(alias Logger)
{
    VkApplicationInfo info = {
         sType: VkStructureType.VK_STRUCTURE_TYPE_APPLICATION_INFO,
         apiVersion: makeApiVersion(0, 1, 2, 0),
         pEngineName: "pukan",
         engineVersion: makeApiVersion(0, 0, 0, 1),
    };

    VkInstance instance;
    VkAllocationCallbacks* allocator = null;

    // non-dispatcheable handles, so placing it here
    VkSurfaceKHR surface;

    static void log_info(A...)(A s)
    {
        Logger.info(s);
    }

    this(string appName, uint appVer)
    {
        info.pApplicationName = appName.toStringz;
        info.applicationVersion = appVer;

        const(char*)[] extension_list = [
            VK_KHR_SURFACE_EXTENSION_NAME.ptr,
        ];

        version(Windows)
            extension_list ~= VK_KHR_WIN32_SURFACE_EXTENSION_NAME.ptr;
        else
            extension_list ~= VK_KHR_XCB_SURFACE_EXTENSION_NAME.ptr; //X11

        debug extension_list ~= VK_EXT_DEBUG_UTILS_EXTENSION_NAME.ptr;

        const(char*)[] validation_layers;
        debug validation_layers ~= "VK_LAYER_KHRONOS_validation";

        VkInstanceCreateInfo createInfo = {
            sType: VkStructureType.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            pApplicationInfo: &info,
            ppEnabledExtensionNames: extension_list.ptr,
            enabledExtensionCount: cast(uint) extension_list.length,
            ppEnabledLayerNames: validation_layers.ptr,
            enabledLayerCount: cast(uint) validation_layers.length,
        };

        vkCreateInstance(&createInfo, allocator, &instance)
            .vkCheck("Vulkan instance creation failed");

        log_info("Vulkan instance created");
    }

    ~this()
    {
        if(surface)
            vkDestroySurfaceKHR(instance, surface, allocator);

        vkDestroyInstance(instance, allocator);
    }

    void useSurface(VkSurfaceKHR s) @live
    {
        surface = s;
    }

    void printAllAvailableLayers()
    {
        auto layers = getArrayFrom!vkEnumerateInstanceLayerProperties();

        foreach(l; layers)
            log_info(l.layerName);
    }

    /// Returns: array of pointers to devices descriptions
    VkPhysicalDevice[] devices()
    {
        return getArrayFrom!vkEnumeratePhysicalDevices(instance);
    }

    void printAllDevices()
    {
        foreach(d; devices)
            printDevice(d);
    }

    static void printDevice(VkPhysicalDevice d)
    {
        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(d, &props);

        VkPhysicalDeviceProperties2 props2 = {
            sType: VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
        };
        vkGetPhysicalDeviceProperties2(d, &props2);

        VkPhysicalDeviceMemoryProperties mem;
        vkGetPhysicalDeviceMemoryProperties(d, &mem);

        VkPhysicalDeviceFeatures features;
        vkGetPhysicalDeviceFeatures(d, &features);

        log_info(props);
        log_info(props2);
        log_info(mem);
        log_info(features);
    }

    debug scope attachFlightRecorder()
    {
        auto d = new FlightRecorder!Backend(this);

        // Extension commands that are not core or WSI have to be loaded
        auto fun = cast(PFN_vkCreateDebugUtilsMessengerEXT) vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");

        fun(instance, &d.createInfo, allocator, &d.messenger)
            .vkCheck(__FUNCTION__);

        return d;
    }

    auto findSuitablePhysicalDevice()
    {
        if(devices.length > 0)
            return devices[0];

        throw new PukanException("appropriate device not found");
    }

    static auto findSuitableQueueFamilies(VkPhysicalDevice dev)
    {
        auto qFamilyProps = getArrayFrom!vkGetPhysicalDeviceQueueFamilyProperties(dev);
        size_t[] apprIndices;

        foreach(i, qfp; qFamilyProps)
        {
            if (qfp.queueFlags & VK_QUEUE_GRAPHICS_BIT)
               apprIndices ~= i;
        }

        return apprIndices;
    }
}

auto vkCheck(VkResult ret, string err_descr = "Vulkan exception")
{
    if(ret != VkResult.VK_SUCCESS)
        throw new PukanExceptionWithCode(err_descr, ret);

    return ret;
}

/// Special helper to fetch values using methods like vkEnumeratePhysicalDevices
auto getArrayFrom(alias func, T...)(T obj)
{
    import std.traits;

    uint count;

    static if(is(ReturnType!func == void))
        func(obj, &count, null);
    else
        func(obj, &count, null).vkCheck;

    enum len = Parameters!func.length;
    alias Tptr = Parameters!func[len-1];

    PointerTarget!Tptr[] ret;

    if(count > 0)
    {
        ret.length = count;

        static if(is(ReturnType!func == void))
            func(obj, &count, ret.ptr);
        else
            func(obj, &count, ret.ptr).vkCheck;
    }

    return ret;
}

class FlightRecorder(TBackend)
{
    TBackend backend;

    VkDebugUtilsMessengerCreateInfoEXT createInfo;
    VkDebugUtilsMessengerEXT messenger;

    this(TBackend b)
    {
        backend = b;

        with(VkDebugUtilsMessageSeverityFlagBitsEXT)
        with(VkDebugUtilsMessageTypeFlagBitsEXT)
        createInfo = VkDebugUtilsMessengerCreateInfoEXT(
            sType: VkStructureType.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            messageSeverity: (VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT),
            messageType: VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
            pfnUserCallback: &messenger_callback
        );
    }

    ~this()
    {
        auto fun = cast(PFN_vkDestroyDebugUtilsMessengerEXT) vkGetInstanceProcAddr(backend.instance, "vkDestroyDebugUtilsMessengerEXT");

        fun(backend.instance, messenger, backend.allocator);
    }

    extern(C) static uint messenger_callback(
        VkDebugUtilsMessageSeverityFlagBitsEXT messageSeverity,
        VkDebugUtilsMessageTypeFlagsEXT messageType,
        const VkDebugUtilsMessengerCallbackDataEXT* pCallbackData,
        void* pUserData
    )
    {
        import std.stdio;
        writeln(pCallbackData.pMessage);

        return VkResult.VK_SUCCESS;
    }
}

class Frame
{
    //~ void resize
    //~ draw(render_packet)
}

struct RenderPacket
{
}
