module pukan.vulkan.vkobj;

import pukan.vulkan.bindings;
import pukan.vulkan.helpers: vkCheck;
import pukan.vulkan.stype_list: getCreateInfoStructureType;
import pukan.vulkan.vkname: VkInfoNames;

enum VkParentKind
{
    none,
    instance,
    device,
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
    }
    else static if(is(Handle == VkSurfaceKHR))
    {
        enum hasCreate = false;
        enum createParent = VkParentKind.none;
        enum destroyParent = VkParentKind.instance;
    }
    else static if(is(Handle == VkSemaphore))
    {
        alias CreateInfo = VkSemaphoreCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
    }
    else static if(is(Handle == VkFence))
    {
        alias CreateInfo = VkFenceCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
    }
    else static if(is(Handle == VkCommandPool))
    {
        alias CreateInfo = VkCommandPoolCreateInfo;
        enum hasCreate = true;
        enum createParent = VkParentKind.device;
        enum destroyParent = VkParentKind.device;
    }
    else
        static assert(false, "unsupported Vulkan handle: " ~ name);

    static if(hasCreate)
    {
        mixin("alias create = " ~ VkInfoNames!(CreateInfo.stringof).create ~ ";");
        mixin("alias destroy = " ~ VkInfoNames!(CreateInfo.stringof).destroy ~ ";");
    }
    else
    {
        static assert(is(Handle == VkSurfaceKHR));
        alias destroy = vkDestroySurfaceKHR;
    }
}

/// Owning RAII wrapper for a single Vulkan handle
struct VkObj(Handle)
{
    alias Info = VkHandleInfo!Handle;

    Handle handle;
    VkAllocationCallbacks* allocator;

    static if(Info.destroyParent == VkParentKind.instance)
        private VkInstance parentInstance;
    else static if(Info.destroyParent == VkParentKind.device)
        private VkDevice parentDevice;

    alias this = handle;

    static if(Info.hasCreate && Info.createParent == VkParentKind.none)
    {
        this(VkAllocationCallbacks* allocator, Info.CreateInfo createInfo)
        {
            this.allocator = allocator;

            auto ci = createInfo;
            ci.sType = getCreateInfoStructureType!(Info.CreateInfo*);

            Info.create(&ci, allocator, &handle).vkCheck(Info.name ~ " creation failed");
        }
    }

    static if(Info.hasCreate && Info.createParent == VkParentKind.device)
    {
        this(VkDevice device, VkAllocationCallbacks* allocator, Info.CreateInfo createInfo)
        {
            this.parentDevice = device;
            this.allocator = allocator;

            auto ci = createInfo;
            ci.sType = getCreateInfoStructureType!(Info.CreateInfo*);

            Info.create(device, &ci, allocator, &handle).vkCheck(Info.name ~ " creation failed");
        }
    }

    static if(Info.destroyParent == VkParentKind.none)
    {
        this(Handle existing, VkAllocationCallbacks* allocator)
        {
            handle = existing;
            this.allocator = allocator;
        }
    }
    else static if(Info.destroyParent == VkParentKind.instance)
    {
        this(Handle existing, VkInstance instance, VkAllocationCallbacks* allocator)
        {
            handle = existing;
            parentInstance = instance;
            this.allocator = allocator;
        }
    }
    else static if(Info.destroyParent == VkParentKind.device)
    {
        this(Handle existing, VkDevice device, VkAllocationCallbacks* allocator)
        {
            handle = existing;
            parentDevice = device;
            this.allocator = allocator;
        }
    }

    ref VkObj opAssign(VkObj rhs)
    {
        destroy(this);

        handle = rhs.handle;
        allocator = rhs.allocator;

        static if(Info.destroyParent == VkParentKind.instance)
            parentInstance = rhs.parentInstance;
        else static if(Info.destroyParent == VkParentKind.device)
            parentDevice = rhs.parentDevice;

        rhs.handle = Handle.init;
        rhs.allocator = null;
        static if(Info.destroyParent == VkParentKind.instance)
            rhs.parentInstance = VkInstance.init;
        else static if(Info.destroyParent == VkParentKind.device)
            rhs.parentDevice = VkDevice.init;

        return this;
    }

    @disable this(this);

    ~this()
    {
        if(handle == Handle.init)
            return;

        static if(Info.destroyParent == VkParentKind.none)
            Info.destroy(handle, allocator);
        else static if(Info.destroyParent == VkParentKind.instance)
            Info.destroy(parentInstance, handle, allocator);
        else static if(Info.destroyParent == VkParentKind.device)
            Info.destroy(parentDevice, handle, allocator);
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
}
