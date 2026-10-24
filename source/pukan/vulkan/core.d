module pukan.vulkan.core;

import pukan.exceptions;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;
public import pukan.vulkan.helpers; //TODO: remove public
import pukan.vulkan.physical_device: PhysicalDevice, SelectedDevice;
import pukan.vulkan.api_version: loaderVersion, requiredApiVersionEncoded;
import pukan.vulkan.requirements: ApiVersionRequirement, InstanceContext, requirementsSatisfied, requestRequirements;
import pukan: toPrettyString;
import std.conv: to;
import std.exception: enforce;
import std.meta: AliasSeq;
import std.string: toStringz;

///
class Instance
{
    VkApplicationInfo info = {
         sType: VkStructureType.VK_STRUCTURE_TYPE_APPLICATION_INFO,
         apiVersion: requiredApiVersionEncoded,
         pEngineName: "pukan",
         engineVersion: 1,
    };

    alias VkT = VkObj!(VkInstanceCreateInfo*, VkAllocationCallbacks*);
    VkT instance;
    VkAllocationCallbacks* allocator = null;

    // non-dispatcheable handles, so placing it here
    VkSurfaceKHR surface;

    private PhysicalDevice selectedPhysicalDevice;

    static void log_info(A...)(A s)
    {
        debug
        {
            import std.logger;

            stdThreadLocalLog().info(s);
        }
    }

    ///
    this(string appName, uint appVer, const(char*)[] extension_list)
    {
        info.pApplicationName = appName.toStringz;
        info.applicationVersion = appVer;

        InstanceContext ctx = { loaderVersion: loaderVersion() };

        string reason;
        if(!ApiVersionRequirement.isSatisfied(ctx, reason))
            throw new PukanVulkanException("Vulkan requirement " ~ reason);

        debug extension_list ~= [
            VK_EXT_DEBUG_UTILS_EXTENSION_NAME.ptr,
            //~ VK_EXT_LAYER_SETTINGS_EXTENSION_NAME.ptr, //no effect
        ];

        const(char*)[] validation_layers;
        debug validation_layers ~= [
            "VK_LAYER_KHRONOS_validation", //TODO: sType member isn't needed if this validation disabled
        ];

        debug const value = VK_TRUE;

        debug auto settings = [
            VkLayerSettingEXT("VK_LAYER_KHRONOS_validation", "validate_best_practices", VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &value),
            //~ VkLayerSettingEXT("VK_LAYER_KHRONOS_validation", "validate_best_practices_nvidia", VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &value),
            //~ VkLayerSettingEXT("VK_LAYER_KHRONOS_validation", "validate_sync", VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &value),
            //~ VkLayerSettingEXT("VK_LAYER_KHRONOS_validation", "gpuav_enable", VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &value),
            //~ VkLayerSettingEXT("VK_LAYER_KHRONOS_validation", "gpuav_safe_mode", VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &value),
            //~ VkLayerSettingEXT("VK_LAYER_KHRONOS_validation", "gpuav_force_on_robustness", VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &value),
            //~ VkLayerSettingEXT("VK_LAYER_KHRONOS_validation", "gpuav_reserve_binding_slot", VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &value),
            //~ VkLayerSettingEXT("VK_LAYER_KHRONOS_validation", "printf_enable", VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &value),
        ];
        else
            VkLayerSettingEXT[] settings;

        VkLayerSettingsCreateInfoEXT layersSettings = {
                sType: VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT,
                pSettings: settings.ptr,
                settingCount: cast(uint) settings.length,
        };

        VkInstanceCreateInfo createInfo = {
            sType: VkStructureType.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            pApplicationInfo: &info,
            ppEnabledExtensionNames: extension_list.ptr,
            enabledExtensionCount: cast(uint) extension_list.length,
            ppEnabledLayerNames: validation_layers.ptr,
            enabledLayerCount: cast(uint) validation_layers.length,
            pNext: &layersSettings,
        };

        instance = create(&createInfo, allocator);

        log_info("Vulkan instance created");
    }

    ///
    this(VkInstance ins)
    {
        instance = VkT(ins, null);
        log_info("Vulkan instance obtained");
    }

    ~this()
    {
        if(surface)
            vkDestroySurfaceKHR(instance, surface, allocator);
    }

    mixin SurfaceMethods;

    void useSurface(VkSurfaceKHR s) @live
    {
        surface = s;
    }

    void printAllAvailableLayers()
    {
        auto layers = getArrayFrom!vkEnumerateInstanceLayerProperties();

        log_info(layers.toPrettyString);
    }

    /// Returns: array of pointers to devices descriptions
    VkPhysicalDevice[] devices()
    {
        return getArrayFrom!vkEnumeratePhysicalDevices(instance);
    }

    uint findMemoryType(uint memoryTypeBitFilter, VkMemoryPropertyFlags properties)
    {
        return selectedPhysicalDevice.findMemoryType(memoryTypeBitFilter, properties);
    }

    /// Must be called after logical device creation, otherwise mutex deadlock occurs
    debug scope attachFlightRecorder(in LogicalDevice ld)
    {
        assert(ld.physicalDevice.instance == this, "Wrong LogicalDevice provided");

        auto d = new FlightRecorder!Instance(this);

        // Extension commands that are not core or WSI have to be loaded
        auto fun = cast(PFN_vkCreateDebugUtilsMessengerEXT) vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");

        fun(instance, &d.createInfo, allocator, &d.messenger)
            .vkCheck(__FUNCTION__);

        return d;
    }

    /**
        When layerName parameter is null, only extensions provided by the
        Vulkan implementation or by implicitly enabled layers are returned.
        When layerName is the name of a layer, the instance extensions
        provided by that layer are returned.
    */
    VkExtensionProperties[] extensions(const(char*) layerName = null)
    {
        return getArrayFrom!vkEnumerateInstanceExtensionProperties(layerName);
    }

    //TODO: remove or add heuristics
    ///
    auto findSuitablePhysicalDevice()
    {
        return findSuitablePhysicalDevice!()();
    }

    ///
    SelectedDevice!Reqs findSuitablePhysicalDevice(Reqs...)()
    {
        auto suitable = suitablePhysicalDevices!Reqs();

        if(suitable.length == 0)
            throw new PukanVulkanException("no physical device satisfies the requirements");

        selectedPhysicalDevice = suitable[0].device;
        return suitable[0];
    }

    // TODO: may be removed if GPU menu moves to SelectedDevice
    /// Returns every physical device that satisfies the requirements
    SelectedDevice!Reqs[] suitablePhysicalDevices(Reqs...)()
    {
        SelectedDevice!Reqs[] ret;
        alias allRequirements = AliasSeq!(ApiVersionRequirement, Reqs);

        foreach(idx, dev; devices)
        {
            auto pd = new PhysicalDevice(this, dev, idx);
            auto ctx = pd.createLogicalDeviceContext(null);

            string reason;
            if(!requirementsSatisfied!allRequirements(ctx, reason))
                continue;

            requestRequirements!allRequirements(ctx);
            ret ~= SelectedDevice!Reqs(pd, ctx);
        }

        return ret;
    }

    /// Returns: family indices
    auto findSuitableQueueFamilies()
    {
        return selectedPhysicalDevice.findSuitableQueueFamilies();
    }

    /// Throw exception if extension is not supported
    void checkExtensionSupportedEx(in char* extensionName, string file = __FILE__, size_t line = __LINE__)
    {
        import core.stdc.string: strcmp;

        foreach(e; extensions)
        {
            if(strcmp(&e.extensionName[0], extensionName) == 0)
                return;
        }

        throw new PukanVulkanException("Extension "~extensionName.to!string~" is not supported by Vulkan instance", file, line);
    }
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

    extern(C) static VkBool32 messenger_callback(
        VkDebugUtilsMessageSeverityFlagBitsEXT messageSeverity,
        VkDebugUtilsMessageTypeFlagsEXT messageType,
        const VkDebugUtilsMessengerCallbackDataEXT* pCallbackData,
        void* pUserData
    ) //FIXME: nothrow
    {
        //TODO: move out from renderer package
        import std.stdio: writeln;

        writeln("Severity: ", messageSeverity, ", type: ", messageType, ", ", pCallbackData.pMessage.to!string);

        if(messageSeverity == VkDebugUtilsMessageSeverityFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
        {
            printStackTrace();

            import core.stdc.stdlib;

            abort();
        }

        return VK_FALSE;
    }
}
