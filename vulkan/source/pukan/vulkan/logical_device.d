module pukan.vulkan.logical_device;

import core.sync.mutex: Mutex;
import pukan.vulkan.bindings;
import pukan.vulkan.commands: CommandPool;
import pukan.vulkan.core: Instance;
import pukan.vulkan.helpers: vkCall, vkCheck;
import pukan.vulkan.memory: DeviceMemory, MemoryBufferMappedToCPU;
import pukan.vulkan.physical_device: PhysicalDevice;
import pukan.vulkan.pipelines: PipelineCacheManager;
import pukan.vulkan.renderpass: RenderPass;
import pukan.vulkan.resources.ownership: ResourceOwner;
import pukan.vulkan.resources.release: ReleaseQueue;
import pukan.vulkan.requirements: ChainMask, DeviceContext, FeatureChain, ImageFormatRequest, linkDeviceFeatures, requireEnabled;
import pukan.vulkan.shaders: ShaderDecl, ShaderInfo, ShaderVertexInput, createLayoutBinding;
import pukan.vulkan.resources.vkobj: VkObj;

import log = std.logger;
import std.exception: enforce;
import std.conv: to;
import std.string: toStringz;

class LogicalDevice
{
    PhysicalDevice physicalDevice;
    VkDevice device;
    alias this = device;

    const uint familyIdx;

    private VkPhysicalDeviceFeatures enabledFeatures;
    private ChainMask enabledChainMask;
    private VkQueueFlags selectedQueueFlags;
    private const(char)*[] enabledExtensions;
    private bool[ImageFormatRequest] supportedImageFormats;
    private Mutex queueMutex;

    /// Owner of what the device itself holds; every scene owner hangs from it
    ResourceOwner!true rootOwner;

    /// Holds every release that waits for the frames in flight
    ReleaseQueue releaseQueue;

    private Mutex retiredMutex;
    /// Optional persistent caches shared by graphics pipelines and compute kernels
    PipelineCacheManager pipelineCacheManager;

    package this(PhysicalDevice pd, const(char*)[] extension_list, VkPhysicalDeviceFeatures enabledFeatures,
        ChainMask enabledChainMask, FeatureChain chain, VkQueueFlags requiredQueueFlags)
    {
        physicalDevice = pd;
        selectedQueueFlags = requiredQueueFlags;
        queueMutex = new Mutex;

        const fqIdxs = pd.findSuitableQueueFamilies(requiredQueueFlags);
        enforce(fqIdxs.length > 0);
        familyIdx = cast(uint) fqIdxs[0];

        immutable float queuePriority = 1.0f;

        VkDeviceQueueCreateInfo queueCreateInfo = {
            sType: VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex: familyIdx,
            queueCount: 1,
            pQueuePriorities: &queuePriority,
        };

        VkPhysicalDeviceFeatures2 features2 = {
            sType: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            features: enabledFeatures,
        };
        linkDeviceFeatures(chain, features2);

        //~ VkPhysicalDeviceShaderObjectFeaturesEXT shaderObjectFeatures = {
            //~ sType: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
            //~ shaderObject: VK_TRUE,
        //~ };

        VkDeviceCreateInfo createInfo = {
            sType: VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            queueCreateInfoCount: 1,
            pQueueCreateInfos: &queueCreateInfo,
            pNext: &features2,
            // pEnabledFeatures must stay null while VkPhysicalDeviceFeatures2 is in pNext
            ppEnabledExtensionNames: extension_list.ptr,
            enabledExtensionCount: cast(uint) extension_list.length,
        };

        debug
        {
            import std.algorithm;
            import std.array;
            import std.conv: to;

            const avail_on_dflt_layer = pd.extensions
                .map!((e) => e.extensionName.ptr.to!string)
                .array;

            const need = extension_list
                .map!((e) => e.to!string)
                .array;

            foreach(e; need)
            {
                if(!avail_on_dflt_layer.canFind(e))
                    Instance.log_info(">>> Necessary extension "~e~" not supported!");
            }
        }

        vkCreateDevice(pd.physicalDevice, &createInfo, alloc, &device).vkCheck;
        releaseQueue = new ReleaseQueue(device, alloc);
        rootOwner = new ResourceOwner!true("device", releaseQueue);
        this.enabledFeatures = enabledFeatures;
        this.enabledChainMask = enabledChainMask;
        this.enabledExtensions = extension_list.dup;
    }

    /// Device requirements context for optional checks
    DeviceContext deviceContext()
    {
        DeviceContext ctx;
        ctx.device = physicalDevice.physicalDevice;
        ctx.properties = physicalDevice.properties;
        ctx.enabled = enabledFeatures;
        ctx.enabledChainMask = enabledChainMask;
        ctx.selectedQueueFlags = selectedQueueFlags;
        ctx.enabledExtensions = enabledExtensions.dup;
        return ctx;
    }

    /// Returns false and a reason when the device cannot create the requested image
    bool supportsImageFormat(in ImageFormatRequest request, out string reason)
    {
        if(request in supportedImageFormats)
            return true;

        if(!physicalDevice.supportsImageFormat(request, reason))
            return false;

        supportedImageFormats[request] = true;
        return true;
    }

    /// Throws RequirementsNotMetException if any requirement is not enabled
    void ensureEnabled(Reqs...)(string entity, string file = __FILE__, size_t line = __LINE__)
    {
        auto ctx = deviceContext();
        requireEnabled!Reqs(ctx, entity, file, line);
    }

    /// Queues a handle release for the next flush that outlives a frame in flight
    void retire(void function(VkDevice, void*, VkAllocationCallbacks*) release, void* handle)
    {
        releaseQueue.retire(release, handle);
    }

    /// Queues a holder, whose destructor releases what it owns
    void retireHolder(Object holder)
    {
        releaseQueue.retireHolder(holder);
    }

    /// Runs the queued releases no frame in flight can still reference
    void flushRetired(uint framesInFlight)
    {
        releaseQueue.flush(framesInFlight);
    }

    ~this()
    {
        if(device)
        {
            vkDeviceWaitIdle(device);

            if(rootOwner)
                destroy(rootOwner);

            // A queued holder releases more, so drain until nothing is left
            while(releaseQueue.hasRetired())
                releaseQueue.flush(0);

            // A later finalizer must not call into a device that is gone
            releaseQueue.close();


            debug
            {
                import pukan.vulkan.resources.vkobj: VkHandleKind, liveVkHandles;

                // The instance and its surface outlive their device
                foreach(kind; [
                    VkHandleKind.semaphore, VkHandleKind.fence,
                    VkHandleKind.commandPool, VkHandleKind.sampler,
                    VkHandleKind.imageView, VkHandleKind.framebuffer,
                    VkHandleKind.descriptorSetLayout, VkHandleKind.descriptorPool,
                    VkHandleKind.pipeline, VkHandleKind.pipelineLayout,
                    VkHandleKind.shaderModule,
                ])
                    assert(liveVkHandles(kind) == 0,
                        "a Vulkan object of kind " ~ kind.to!string ~ " outlived the device");
            }

            vkDestroyDevice(device, alloc);
            // Later finalizers must not touch a device the driver took away
            this.device = VkDevice.init;
        }
    }

    auto alloc() => physicalDevice.instance.allocator;

    /// Host access to a queue must be externally synchronized.
    void submitQueue(ref VkSubmitInfo submitInfo, VkFence fence)
    {
        synchronized(queueMutex)
            vkQueueSubmit(getQueue(), 1, &submitInfo, fence).vkCheck;
    }

    //TODO: remove
    auto getQueue()
    {
        return getQueue(0);
    }

    ///
    auto getQueue(uint queueIdx)
    {
        VkQueue ret;
        vkGetDeviceQueue(device, familyIdx, queueIdx, &ret);

        return ret;
    }

    ///
    auto createSyncQueue()
    {
        import pukan.vulkan.queue: Queue;

        return new Queue(this);
    }

    auto create(alias ClassType, A...)(A a)
    {
        return new ClassType(this, a);
    }

    auto createSemaphore()
    {
        return create!Semaphore;
    }

    auto createFence()
    {
        return create!Fence;
    }

    auto createCommandPool()
    {
        return new CommandPool(this, familyIdx);
    }

    //TODO: This will be moved to a specific objects (where required) to reduce the number of references to the device

    import pukan.vulkan.helpers: ScopedLogicalDeviceTemplateMixin;

    import pukan.vulkan.shaders: Shaders;
    mixin ScopedLogicalDeviceTemplateMixin!Shaders;

    import pukan.vulkan.descriptors: DescriptorPools;
    mixin ScopedLogicalDeviceTemplateMixin!DescriptorPools;

    import pukan.vulkan.pipelines: Pipelines;
    mixin ScopedLogicalDeviceTemplateMixin!Pipelines;


    import pukan.vulkan.memory: Memory;
    mixin ScopedLogicalDeviceTemplateMixin!Memory;
}

class Semaphore
{
    ubyte[70000] FIXME_druntime_issue_REMOVE_ME;
    LogicalDevice device;
    VkObj!VkSemaphore semaphore;

    /// The raw handle; asserts in debug after release
    ref VkSemaphore vk() => semaphore.vk;

    this(LogicalDevice dev)
    {
        device = dev;

        VkSemaphoreCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        semaphore = VkObj!VkSemaphore(device.releaseQueue, cinf);
    }
}

class Fence
{
    //~ ubyte[70000] FIXME_druntime_issue_REMOVE_ME;
    LogicalDevice device;
    VkObj!VkFence fence;

    /// The raw handle; asserts in debug after release
    ref VkFence vk() => fence.vk;

    this(LogicalDevice dev)
    {
        device = dev;

        VkFenceCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            flags: VK_FENCE_CREATE_SIGNALED_BIT,
        };

        fence = VkObj!VkFence(device.releaseQueue, cinf);
    }

    void wait()
    {
        // The timeout is in nanoseconds; a heavy frame on a software driver can
        // take longer than the four seconds a uint counts
        vkWaitForFences(device, 1, fence.vkPtr, VK_TRUE, ulong.max).vkCheck;
    }

    void reset()
    {
        vkResetFences(device, 1, fence.vkPtr).vkCheck;
    }
}
