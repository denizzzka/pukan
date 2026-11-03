module pukan.vulkan.resources.vkobj;

import core.atomic: atomicLoad, atomicOp;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers: vkCheck;
import pukan.vulkan.resources.release: ReleaseQueue;
import pukan.vulkan.stype_list: getCreateInfoStructureType;
import pukan.vulkan.vkname: VkInfoNames;

enum VkParentKind
{
    none,
    instance,
    device,
}

/// Handle kinds the wrapper knows; also indexes the debug live counts
enum VkHandleKind: uint
{
    instance,
    surface,
    semaphore,
    fence,
    commandPool,
    sampler,
    buffer,
    image,
    imageView,
    framebuffer,
    memory,
    descriptorSetLayout,
    descriptorPool,
    pipeline,
    pipelineLayout,

    count,
}

debug private shared size_t[VkHandleKind.count] liveVkCounts;

/// Handles of a kind that are alive; nothing must be left at device teardown
debug size_t liveVkHandles(VkHandleKind kind) in(kind < VkHandleKind.count)
{
    return atomicLoad(liveVkCounts[kind]);
}

template VkHandleInfo(Handle)
{
    enum name = Handle.stringof;

    static if(is(Handle == VkInstance))
    {
        alias CreateInfo = VkInstanceCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.none;
        enum destroyParent = VkParentKind.none;
        enum kind = VkHandleKind.instance;
    }
    else static if(is(Handle == VkSurfaceKHR))
    {
        enum hasCreate = false;
        enum createParent = VkParentKind.none;
        enum destroyParent = VkParentKind.instance;
        enum kind = VkHandleKind.surface;
    }
    else static if(is(Handle == VkSemaphore))
    {
        alias CreateInfo = VkSemaphoreCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.semaphore;
    }
    else static if(is(Handle == VkFence))
    {
        alias CreateInfo = VkFenceCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.fence;
    }
    else static if(is(Handle == VkCommandPool))
    {
        alias CreateInfo = VkCommandPoolCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.commandPool;
    }
    else static if(is(Handle == VkBuffer))
    {
        alias CreateInfo = VkBufferCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.buffer;
    }
    else static if(is(Handle == VkImage))
    {
        alias CreateInfo = VkImageCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.image;
    }
    else static if(is(Handle == VkImageView))
    {
        alias CreateInfo = VkImageViewCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.imageView;
    }
    else static if(is(Handle == VkFramebuffer))
    {
        alias CreateInfo = VkFramebufferCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.framebuffer;
    }
    else static if(is(Handle == VkDeviceMemory))
    {
        alias CreateInfo = VkMemoryAllocateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.memory;
    }
    else static if(is(Handle == VkSampler))
    {
        alias CreateInfo = VkSamplerCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.sampler;
    }
    else static if(is(Handle == VkDescriptorSetLayout))
    {
        alias CreateInfo = VkDescriptorSetLayoutCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.descriptorSetLayout;
    }
    else static if(is(Handle == VkPipeline))
    {
        enum hasCreate = false;
        enum createParent = VkParentKind.none;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.pipeline;
    }
    else static if(is(Handle == VkPipelineLayout))
    {
        alias CreateInfo = VkPipelineLayoutCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.pipelineLayout;
    }
    else static if(is(Handle == VkDescriptorPool))
    {
        alias CreateInfo = VkDescriptorPoolCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
        enum kind = VkHandleKind.descriptorPool;
    }
    else
        static assert(false, "unsupported Vulkan handle: " ~ name);

    static if(hasCreate)
    {
        mixin("alias create = " ~ VkInfoNames!(CreateInfo.stringof).create ~ ";");
        mixin("alias destroy = " ~ VkInfoNames!(CreateInfo.stringof).destroy ~ ";");
    }
    else static if(is(Handle == VkSurfaceKHR))
        alias destroy = vkDestroySurfaceKHR;
    else static if(is(Handle == VkPipeline))
        alias destroy = vkDestroyPipeline;
    else
        static assert(false, "no destroy function for " ~ name);
}

/// Owning RAII wrapper for a single Vulkan handle
struct VkObj(Handle)
{
    alias Info = VkHandleInfo!Handle;

    private Handle handle;
    VkAllocationCallbacks* allocator;

    static if(Info.destroyParent == VkParentKind.instance)
        private VkInstance parentInstance;
    else static if(Info.destroyParent == VkParentKind.device)
    {
        /// Releases the handle once the frames in flight pass
        private ReleaseQueue queue;
    }

    static if(Info.hasCreate && Info.createParent == VkParentKind.none)
    {
        this(VkAllocationCallbacks* allocator, Info.CreateInfo createInfo)
        {
            this.allocator = allocator;

            auto ci = createInfo;
            ci.sType = getCreateInfoStructureType!(Info.CreateInfo*);

            Info.create(&ci, allocator, &handle).vkCheck(Info.name ~ " creation failed");
            noteAlive();
        }
    }

    static if(Info.hasCreate && Info.createParent == VkParentKind.device)
    {
        this(ReleaseQueue queue, Info.CreateInfo createInfo)
        in(queue !is null)
        {
            this.queue = queue;
            this.allocator = queue.allocator;

            auto ci = createInfo;
            ci.sType = getCreateInfoStructureType!(Info.CreateInfo*);

            Info.create(queue.device, &ci, allocator, &handle).vkCheck(Info.name ~ " creation failed");
            noteAlive();
        }
    }

    static if(Info.destroyParent == VkParentKind.none)
    {
        this(Handle existing, VkAllocationCallbacks* allocator)
        {
            handle = existing;
            this.allocator = allocator;
            noteAlive();
        }
    }
    else static if(Info.destroyParent == VkParentKind.instance)
    {
        this(Handle existing, VkInstance instance, VkAllocationCallbacks* allocator)
        {
            handle = existing;
            parentInstance = instance;
            this.allocator = allocator;
            noteAlive();
        }
    }
    else static if(Info.destroyParent == VkParentKind.device)
    {
        this(Handle existing, ReleaseQueue queue)
        in(existing !is Handle.init)
        in(queue !is null)
        {
            handle = existing;
            this.queue = queue;
            this.allocator = queue.allocator;
            noteAlive();
        }
    }

    /// The raw handle; a released wrapper asserts in debug and is null in release
    ref Handle vk()
    {
        debug assert(handle != Handle.init, Info.name ~ " used after release");
        return handle;
    }

    /// Address of the raw handle, for calls that take a pointer
    Handle* vkPtr()
    {
        debug assert(handle != Handle.init, Info.name ~ " used after release");
        return &handle;
    }

    /// Whether the wrapper still owns a handle
    bool isAlive() const @safe pure nothrow => handle != Handle.init;

    /// Frees the handle and empties the wrapper
    void release()
    {
        if(handle == Handle.init)
            return;

        auto releasing = handle;

        handle = Handle.init;
        allocator = null;

        static if(Info.destroyParent == VkParentKind.none)
            Info.destroy(releasing, allocator);
        else static if(Info.destroyParent == VkParentKind.instance)
        {
            Info.destroy(parentInstance, releasing, allocator);
            parentInstance = VkInstance.init;
        }
        else static if(Info.destroyParent == VkParentKind.device)
        {
            queue.retire(&retire, cast(void*) releasing);
            queue = null;
        }

        debug noteReleased();
    }

    /**
        Takes the handle out and empties the slot.

        Returns: the handle, which the caller frees.
    */
    Handle take()
    {
        auto taken = handle;

        handle = Handle.init;
        allocator = null;

        static if(Info.destroyParent == VkParentKind.instance)
            parentInstance = VkInstance.init;
        else static if(Info.destroyParent == VkParentKind.device)
            queue = null;

        debug if(taken !is Handle.init)
            noteReleased();

        return taken;
    }

    /// Frees a handle taken from a wrapper, for an owner's deferred queue
    static void retire(VkDevice device, void* handle, VkAllocationCallbacks* alloc)
    {
        static if(Info.destroyParent == VkParentKind.device)
            Info.destroy(device, cast(Handle) handle, alloc);
        else
            assert(false, "a " ~ Info.name ~ " does not belong to a device");
    }

    ref VkObj opAssign(VkObj rhs)
    {
        if(&this is &rhs)
            return this;

        release();

        handle = rhs.handle;
        allocator = rhs.allocator;

        static if(Info.destroyParent == VkParentKind.instance)
            parentInstance = rhs.parentInstance;
        else static if(Info.destroyParent == VkParentKind.device)
            queue = rhs.queue;

        // The handle moves, so the live count stays the same
        rhs.handle = Handle.init;
        rhs.allocator = null;
        static if(Info.destroyParent == VkParentKind.instance)
            rhs.parentInstance = VkInstance.init;
        else static if(Info.destroyParent == VkParentKind.device)
            rhs.queue = null;

        return this;
    }

    @disable this(this);

    ~this()
    {
        release();
    }

    private void noteAlive()
    {
        debug atomicOp!"+="(liveVkCounts[Info.kind], 1UL);
    }

    private void noteReleased()
    {
        debug atomicOp!"-="(liveVkCounts[Info.kind], 1UL);
    }
}

/// Owns an array of handles and frees the whole array with one delegate call
struct OwnedHandles(Handle)
{
    private Handle[] handles;
    private void delegate(Handle[]) destroyer;

    this(Handle[] handles, void delegate(Handle[]) destroyer)
    {
        this.handles = handles;
        this.destroyer = destroyer;
    }

    @disable this(this);

    ref OwnedHandles opAssign(OwnedHandles rhs)
    {
        if(&this is &rhs)
            return this;

        destroy(this);

        handles = rhs.handles;
        destroyer = rhs.destroyer;

        rhs.handles = null;
        rhs.destroyer = null;

        return this;
    }

    ~this()
    {
        if(handles.length && destroyer !is null)
            destroyer(handles);
    }

    ref Handle opIndex(size_t i) => handles[i];
    size_t length() const => handles.length;
    auto opSlice() => handles[];
}

unittest
{
    static assert(is(VkHandleInfo!VkInstance.CreateInfo == VkInstanceCreateInfo));
    static assert(VkHandleInfo!VkInstance.destroyParent == VkParentKind.none);
    static assert(!VkHandleInfo!VkSurfaceKHR.hasCreate);
    static assert(VkHandleInfo!VkSurfaceKHR.destroyParent == VkParentKind.instance);
    static assert(is(VkHandleInfo!VkSemaphore.CreateInfo == VkSemaphoreCreateInfo));
    static assert(VkHandleInfo!VkCommandPool.destroyParent == VkParentKind.device);

    static assert(VkHandleInfo!VkInstance.kind == VkHandleKind.instance);
    static assert(VkHandleInfo!VkSurfaceKHR.kind == VkHandleKind.surface);
    static assert(VkHandleInfo!VkSemaphore.kind == VkHandleKind.semaphore);
    static assert(VkHandleInfo!VkFence.kind == VkHandleKind.fence);
    static assert(VkHandleInfo!VkCommandPool.kind == VkHandleKind.commandPool);
    static assert(is(VkHandleInfo!VkDescriptorPool.CreateInfo == VkDescriptorPoolCreateInfo));
    static assert(VkHandleInfo!VkDescriptorPool.kind == VkHandleKind.descriptorPool);
    static assert(VkHandleInfo!VkDescriptorSetLayout.kind == VkHandleKind.descriptorSetLayout);
    static assert(is(VkHandleInfo!VkSampler.CreateInfo == VkSamplerCreateInfo));
}
