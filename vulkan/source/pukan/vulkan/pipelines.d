module pukan.vulkan.pipelines;

import core.sync.condition: Condition;
import core.sync.mutex: Mutex;
import core.thread: Thread;
import pukan.vulkan.bindings;
import pukan.vulkan.core: Instance;
import pukan.vulkan.exceptions: PukanVulkanException;
import pukan.vulkan.helpers;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.pipeline_cache: PipelineCacheLoadException, PipelineCacheStore, PipelineVariantKey, PipelineVariantKeyBuilder;
import pukan.vulkan.renderpass: RenderPass;
import pukan.vulkan.resources.ownership: ResourceOwner;
import pukan.vulkan.shaders: ShaderDecl, ShaderVertexInput, createLayoutBinding;
import std.conv: to;

debug
{
    import core.time: Duration;
}

package mixin template Pipelines()
{
    VkPipeline[] createGraphicsPipelines(
        VkGraphicsPipelineCreateInfo[] infos,
        VkPipelineCache pipelineCache = null,
    )
    out(r; r.length == infos.length)
    {
        VkPipeline[] created;
        created.length = infos.length;

        vkCreateGraphicsPipelines(
            this.device,
            pipelineCache,
            cast(uint) infos.length,
            infos.ptr,
            this.alloc,
            created.ptr,
        ).vkCheck;

        return created;
    }

    VkPipeline[] createComputePipelines(
        VkComputePipelineCreateInfo[] infos,
        VkPipelineCache pipelineCache = null,
    )
    out(r; r.length == infos.length)
    {
        VkPipeline[] created;
        created.length = infos.length;

        vkCreateComputePipelines(
            this.device,
            pipelineCache,
            cast(uint) infos.length,
            infos.ptr,
            this.alloc,
            created.ptr,
        ).vkCheck;

        return created;
    }

    /// Creates a driver cache, seeded with a stored blob when one is given
    VkPipelineCache createPipelineCache(const(ubyte)[] initialData = null)
    {
        VkPipelineCacheCreateInfo info = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
            initialDataSize: initialData.length,
            pInitialData: initialData.ptr,
        };

        VkPipelineCache cache;
        vkCreatePipelineCache(this.device, &info, this.alloc, &cache).vkCheck;

        return cache;
    }

    /// Reads the driver blob of a cache, for persistence
    ubyte[] pipelineCacheData(VkPipelineCache cache)
    {
        size_t size;
        vkGetPipelineCacheData(this.device, cache, &size, null).vkCheck;

        ubyte[] data;
        data.length = size;

        if(size)
            vkGetPipelineCacheData(this.device, cache, &size, data.ptr).vkCheck;

        return data[0 .. size];
    }

    void destroyPipelineCache(VkPipelineCache cache)
    {
        vkDestroyPipelineCache(this.device, cache, this.alloc);
    }
}

VkPipelineLayout createPipelineLayout(LogicalDevice device, VkDescriptorSetLayout[] descriptorSetLayouts, VkPushConstantRange[] pushConstantRanges)
{
    VkPipelineLayoutCreateInfo pipelineLayoutCreateInfo = {
        setLayoutCount: cast(uint) descriptorSetLayouts.length,
        pSetLayouts: descriptorSetLayouts.ptr,
        pushConstantRangeCount: cast(uint) pushConstantRanges.length,
        pPushConstantRanges: pushConstantRanges.ptr,
    };

    VkPipelineLayout pipelineLayout;
    vkCall(device, &pipelineLayoutCreateInfo, device.alloc, &pipelineLayout);

    return pipelineLayout;
}

struct GraphicsPipelineCfg
{
    VkPipeline graphicsPipeline;
    VkPipelineLayout pipelineLayout;
    /// Set when this run compiled the variant instead of taking a stored record
    bool needsRecompilation;
}

/// One compute pipeline and the layouts it needs
struct ComputePipelineCfg
{
    VkPipeline pipeline;
    VkPipelineLayout pipelineLayout;
    VkDescriptorSetLayout setLayout;
    /// Set when this run compiled the kernel instead of taking a stored record
    bool needsRecompilation;
}

/// Layouts of a declared compute kernel, before its pipeline is compiled
struct ComputeLayoutCfg
{
    PipelineKey key;
    VkPipelineLayout pipelineLayout;
    VkDescriptorSetLayout setLayout;
}

struct TechniqueId
{
    uint value;
}

struct RenderTargetId
{
    uint value;
}

/// Content and state identity of a pipeline, independent of the render target
struct PipelineKey
{
    /// Content with the shader sums
    ubyte[32] digest;

    size_t toHash() const nothrow @safe
    {
        return hashOf(digest);
    }

    bool opEquals(ref const PipelineKey rhs) const nothrow @safe
    {
        return digest[] == rhs.digest[];
    }

    int opCmp(ref const PipelineKey rhs) const nothrow @safe
    {
        return digest[] < rhs.digest[] ? -1 : digest[] > rhs.digest[] ? 1 : 0;
    }
}

/// One pipeline on one render target
struct PipelineInstance
{
    PipelineKey key;
    RenderTargetId target;

    size_t toHash() const nothrow @safe
    {
        return hashOf(key.toHash(), hashOf(target.value));
    }

    bool opEquals(ref const PipelineInstance rhs) const nothrow @safe
    {
        return key == rhs.key && target.value == rhs.target.value;
    }
}

struct FixedState
{
    VkPrimitiveTopology topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkCullModeFlags cullMode = VK_CULL_MODE_BACK_BIT;
    VkFrontFace frontFace = VK_FRONT_FACE_CLOCKWISE;
    VkBool32 depthTestEnable = VK_TRUE;
    VkBool32 depthWriteEnable = VK_TRUE;
    VkCompareOp depthCompareOp = VK_COMPARE_OP_LESS;
    VkBool32 blendEnable = VK_FALSE;
    /// Turns the fragment alpha into sample coverage, needs a multisampled pass
    VkBool32 alphaToCoverage = VK_FALSE;
    /// Zero writes no colour, for passes that only consume the fragments
    VkColorComponentFlags colorWriteMask =
        VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
        VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    /// Zero for a depth-only pass
    uint colorAttachmentCount = 1;
    VkBool32 depthBiasEnable = VK_FALSE;
    float depthBiasConstantFactor = 0.0f;
    float depthBiasSlopeFactor = 0.0f;
}

struct RenderTechnique
{
    string name;
    ShaderDecl[] stages;
    FixedState state;
    VkDynamicState[] dynamicStates;
}

//TODO: move to pukan: pool growth is engine policy, not a Vulkan wrapper
/// Allocates descriptor sets, adding a pool when the current one is full
final class DescriptorAllocator
{
    private LogicalDevice device;
    private VkDescriptorSetLayout layout;
    private VkDescriptorSetLayoutBinding[] bindings;
    private uint setsPerPool;
    private VkDescriptorPool[] pools;
    /// Pool the next set comes from
    private uint currentPool;
    private uint allocatedInCurrentPool;

    this(
        LogicalDevice device,
        VkDescriptorSetLayout layout,
        VkDescriptorSetLayoutBinding[] bindings,
        uint setsPerPool = 16,
    )
    in(setsPerPool > 0)
    {
        this.device = device;
        this.layout = layout;
        this.bindings = bindings;
        this.setsPerPool = setsPerPool;
    }

    /// Frees every set allocated so far; the sets are invalid afterwards
    void reset()
    {
        foreach(pool; pools)
            vkResetDescriptorPool(device.device, pool, 0);

        currentPool = 0;
        allocatedInCurrentPool = 0;
    }

    VkDescriptorSet allocate()
    {
        if(pools.length == 0)
            addPool();
        else if(allocatedInCurrentPool == setsPerPool)
        {
            if(currentPool + 1 < pools.length)
            {
                ++currentPool;
                allocatedInCurrentPool = 0;
            }
            else
                addPool();
        }

        VkDescriptorSetAllocateInfo info = {
            sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool: pools[currentPool],
            descriptorSetCount: 1,
            pSetLayouts: &layout,
        };

        while(true)
        {
            VkDescriptorSet set;
            const result = vkAllocateDescriptorSets(device, &info, &set);

            if(result == VK_SUCCESS)
            {
                ++allocatedInCurrentPool;
                return set;
            }

            if(result != VK_ERROR_OUT_OF_POOL_MEMORY && result != VK_ERROR_FRAGMENTED_POOL)
                result.vkCheck;

            addPool();
            info.descriptorPool = pools[currentPool];
        }
    }

    ~this()
    {
        if(device is null)
            return;

        foreach(pool; pools)
            vkDestroyDescriptorPool(device.device, pool, device.alloc);
    }

    private void addPool()
    {
        pools ~= device.createDescriptorPool(bindings, setsPerPool);
        currentPool = cast(uint)(pools.length - 1);
        allocatedInCurrentPool = 0;
    }
}

/// Writes cache blobs on one background thread, never inside the frame
private final class PipelineCacheWriter
{
    private enum JobKind
    {
        trim,
        save,
    }

    private struct Job
    {
        JobKind kind;
        PipelineVariantKey identity;
        ubyte[] payload;
    }

    private PipelineCacheStore store;
    private Job[] jobs;
    private Mutex mutex;
    private Condition condition;
    private bool stopping;
    private Thread thread;

    this(PipelineCacheStore store)
    {
        this.store = store;
        mutex = new Mutex;
        condition = new Condition(mutex);

        thread = new Thread(&run);
        thread.isDaemon = true;
        thread.start();
    }

    ~this()
    {
        mutex.lock();
        stopping = true;
        condition.notify();
        mutex.unlock();

        thread.join();
    }

    void put(PipelineVariantKey identity, ubyte[] payload)
    {
        mutex.lock();
        jobs ~= Job(JobKind.save, identity, payload);
        condition.notify();
        mutex.unlock();
    }

    /// Drops the least recently used records before any save of this run
    void trim()
    {
        mutex.lock();
        jobs ~= Job(JobKind.trim);
        condition.notify();
        mutex.unlock();
    }

    private void run()
    {
        while(true)
        {
            Job job;

            mutex.lock();

            while(jobs.length == 0 && !stopping)
                condition.wait();

            if(jobs.length == 0)
            {
                mutex.unlock();
                break;
            }

            job = jobs[0];
            jobs = jobs[1 .. $];
            mutex.unlock();

            try
            {
                if(job.kind == JobKind.trim)
                    store.trim();
                else
                    store.save(job.identity, job.payload);
            }
            catch(Exception e)
                Instance.log_info(
                    "pipeline cache: " ~
                    (job.kind == JobKind.trim ? "trim" : job.identity.toString()) ~
                    " failed: " ~ e.msg);
        }
    }
}

//TODO: move to pukan: technique and pipeline caching is engine policy, not a Vulkan wrapper
/// Persistent driver caches shared by graphics pipelines and compute kernels
final class PipelineCacheManager
{
    private LogicalDevice device;
    private PipelineCacheStore store;
    private PipelineCacheWriter writer;

    this(LogicalDevice device, PipelineCacheStore store)
    {
        this.device = device;
        this.store = store;

        if(store)
        {
            writer = new PipelineCacheWriter(store);
            writer.trim();
        }
    }

    ~this()
    {
        if(writer)
            destroy(writer);
    }

    /// Whether variants are persisted at all
    bool enabled() const => store !is null;

    /// Driver cache for one variant, seeded with its stored record
    VkPipelineCache acquire(PipelineVariantKey identity, out bool needsRecompilation)
    {
        ubyte[] payload;
        bool shaderChanged = false;
        needsRecompilation = false;

        if(store)
            while(true)
            {
                bool changed;

                try
                {
                    payload = store.load(identity, changed);
                    shaderChanged = changed;
                    break;
                }
                catch(PipelineCacheLoadException e)
                {
                    // One retry: the bad record is dropped and written again
                    if(needsRecompilation)
                        throw e;

                    store.invalidate(identity);
                    needsRecompilation = true;
                }
            }

        if(shaderChanged)
            Instance.log_info(
                "pipeline cache: " ~ identity.slot.toString() ~
                " was built from older shaders, recompiling");

        if(payload is null)
            needsRecompilation = true;

        return device.createPipelineCache(payload);
    }

    /// Hands the driver blob to the writer, which saves it outside the frame
    void storeResult(PipelineVariantKey identity, VkPipelineCache pipelineCache)
    {
        if(writer is null)
            return;

        auto payload = device.pipelineCacheData(pipelineCache);

        if(payload.length > 0)
            writer.put(identity, payload);
    }
}

//TODO: move to pukan: technique and pipeline caching is engine policy, not a Vulkan wrapper
/// Creates pipelines once per technique and render target
final class PipelineFactory
{
    private struct Technique
    {
        PipelineKey key;
        /// Cache address of the variant, without the shader content
        ubyte[32] slot;
        RenderTechnique description;
        VkPipelineLayout pipelineLayout;
        VkDescriptorSetLayout setLayout;
        VkDescriptorSetLayoutBinding[] bindings;
        DescriptorAllocator allocator;
        uint setsPerPool;
    }

    private struct RenderTarget
    {
        VkRenderPass renderPass;
        uint subpass;
    }

    private struct ComputeTechnique
    {
        PipelineKey key;
        /// Cache address of the kernel, without the shader content
        ubyte[32] slot;
        ShaderDecl shader;
        VkDescriptorSetLayout setLayout;
        VkPipelineLayout pipelineLayout;
        VkSpecializationMapEntry[] specializationEntries;
        ubyte[] specializationData;
        VkSpecializationInfo specialization;
        bool hasSpecialization;
        ComputePipelineCfg cfg;
    }

    private struct PipelineLayoutEntry
    {
        VkDescriptorSetLayout setLayout;
        VkPushConstantRange[] pushConstants;
        VkPipelineLayout layout;
    }

    private struct ComputeLayoutEntry
    {
        VkDescriptorSetLayout setLayout;
        VkPushConstantRange[] pushConstants;
        VkPipelineLayout layout;
    }

    private LogicalDevice device;
    private Technique[] techniques;
    private TechniqueId[PipelineKey] techniqueByKey;
    private ComputeTechnique[] computeTechniques;
    private size_t[PipelineKey] computeByKey;
    private RenderTarget[] targets;
    private GraphicsPipelineCfg[PipelineInstance] cache;
    private PipelineCacheManager cacheManager;

    /// Compiles a compute kernel when it is declared, before its first dispatch
    bool eagerCompute;

    /// Guards the variant cache, the target list and the preload queue
    private Mutex mutex;

    /// Pools and set layouts of every technique, freed with the factory
    private ResourceOwner!true owner;
    private Condition condition;
    private bool stopping;
    private Thread preloadThread;

    private struct Pending
    {
        PipelineInstance instance;
        PipelineKey key;
        RenderPass pass;
        uint subpass;
    }

    private Pending[] pending;
    private bool[PipelineInstance] requested;
    private size_t building;

    debug
    {
        /// Variants this run compiled because no usable record existed
        size_t compiledVariants;
        /// Variants created from a stored record
        size_t cachedVariants;
        /// Time spent loading records and creating pipelines
        Duration pipelineCreationTime;
    }

    /// One interned set layout; the owner frees it after the pools built from it
    private final class SetLayoutHandle
    {
        VkObj!VkDescriptorSetLayout layout;
    }

    private VkDescriptorSetLayout[] setLayouts;
    private VkDescriptorSetLayoutBinding[][] setLayoutBindings;
    private PipelineLayoutEntry[] pipelineLayoutEntries;
    private ComputeLayoutEntry[] computeLayoutEntries;

    private SetLayoutHandle frameSetLayout;
    private VkDescriptorSetLayoutBinding[] frameBindings;

    this(
        LogicalDevice device,
        VkDescriptorSetLayoutBinding[] frameBindings,
        PipelineCacheManager cacheManager = null,
        bool preload = true,
    )
    {
        this.device = device;
        this.cacheManager = cacheManager;
        this.frameBindings = frameBindings;

        mutex = new Mutex;
        condition = new Condition(mutex);
        owner = new ResourceOwner!true("pipeline factory", device.rootOwner.releaseQueue);

        // Taken first, so it goes after every pool built from it
        frameSetLayout = new SetLayoutHandle;
        frameSetLayout.layout = device.createDescriptorSetLayout(frameBindings);
        owner.own(frameSetLayout);

        if(preload)
        {
            preloadThread = new Thread(&preloadRun);
            preloadThread.isDaemon = true;
            preloadThread.start();
        }
    }

    ~this()
    {
        if(preloadThread)
        {
            mutex.lock();
            stopping = true;
            condition.notifyAll();
            mutex.unlock();

            preloadThread.join();
        }

        if(owner)
            destroy(owner);

        debug logCacheSummary();
    }

    debug
    {
        private void logCacheSummary()
        {
            Instance.log_info(
                "pipeline cache: " ~ compiledVariants.to!string ~ " compiled, " ~
                cachedVariants.to!string ~ " cached, " ~
                pipelineCreationTime.total!"msecs".to!string ~ " ms in pipeline creation");
        }
    }

    DescriptorAllocator createFrameAllocator()
    {
        return new DescriptorAllocator(device, frameSetLayout.layout.vk, frameBindings, 16);
    }

    private struct TechniqueIdentity
    {
        PipelineKey key;
        ubyte[32] slot;
    }

    private static TechniqueIdentity techniqueIdentity(RenderTechnique technique)
    {
        PipelineVariantKeyBuilder builder;
        builder.add(technique.state);
        builder.addArray(technique.dynamicStates);

        foreach(ref stage; technique.stages)
        {
            builder.addSlotString(stage.file);
            builder.add(stage.stage);
            builder.add(stage.pushConstantRange);
            builder.addArray(stage.layoutBindings);
            builder.addShader(stage.checksum);
            builder.addArray(stage.vertexInput.bindings);
            builder.addArray(stage.vertexInput.attributes);
        }

        const identity = builder.finish();

        TechniqueIdentity result;
        result.key.digest[] = identity.digest[];
        result.slot[] = identity.slot.digest[];

        return result;
    }

    private struct ComputeIdentity
    {
        PipelineKey key;
        ubyte[32] slot;
    }

    private static VkSpecializationInfo copySpecialization(
        ref ComputeTechnique technique,
        VkSpecializationInfo* specialization,
    )
    {
        if(specialization is null)
            return VkSpecializationInfo.init;

        technique.specializationEntries =
            specialization.pMapEntries[0 .. specialization.mapEntryCount].dup;

        if(specialization.dataSize)
        {
            technique.specializationData.length = specialization.dataSize;
            technique.specializationData[] =
                (cast(const ubyte*) specialization.pData)[0 .. specialization.dataSize];
        }

        return VkSpecializationInfo(
            mapEntryCount: cast(uint) technique.specializationEntries.length,
            pMapEntries: technique.specializationEntries.ptr,
            dataSize: technique.specializationData.length,
            pData: technique.specializationData.ptr,
        );
    }

    private static ComputeIdentity computeIdentity(
        ShaderDecl shader,
        VkSpecializationInfo* specialization,
    )
    {
        PipelineVariantKeyBuilder builder;
        builder.addSlotString(shader.file);
        builder.add(shader.stage);
        builder.add(shader.pushConstantRange);
        builder.addArray(shader.layoutBindings);
        builder.addShader(shader.checksum);

        if(specialization !is null)
        {
            builder.add(specialization.dataSize);

            if(specialization.dataSize)
                builder.addArray((cast(const ubyte*) specialization.pData)[0 .. specialization.dataSize]);

            builder.addArray(specialization.pMapEntries[0 .. specialization.mapEntryCount]);
        }

        const identity = builder.finish();

        ComputeIdentity result;
        result.key.digest[] = identity.digest[];
        result.slot[] = identity.slot.digest[];

        return result;
    }

    PipelineKey declare(RenderTechnique technique, uint setsPerPool = 16)
    {
        const identity = techniqueIdentity(technique);
        const key = identity.key;

        synchronized(mutex)
        {
            if((key in techniqueByKey) !is null)
                return key;

            Technique entry;
            entry.key = key;
            entry.slot = identity.slot;
            entry.description = technique;

            auto bindings = createLayoutBinding(technique.stages);
            auto setLayout = internSetLayout(bindings);

            entry.pipelineLayout = internPipelineLayout(setLayout, pushConstantRanges(technique.stages));

            entry.setLayout = setLayout;
            entry.bindings = bindings;
            entry.setsPerPool = setsPerPool;
            entry.allocator = new DescriptorAllocator(device, setLayout, bindings, setsPerPool);
            owner.own(entry.allocator);

            techniques ~= entry;
            techniqueByKey[key] = TechniqueId(cast(uint)(techniques.length - 1));
        }

        return key;
    }

    GraphicsPipelineCfg acquire(PipelineKey key, RenderPass renderPass, uint subpass = 0)
    {
        synchronized(mutex)
        {
            const instance = PipelineInstance(key, targetId(renderPass, subpass));

            if(auto found = instance in cache)
                return *found;

            try
                cache[instance] = createPipeline(key, renderPass, subpass);
            catch(PukanVulkanException e)
            {
                e.msg = "technique " ~ techniqueName(key) ~ ": " ~ e.msg;
                throw e;
            }

            return cache[instance];
        }
    }

    /// Declares a compute kernel and returns its layouts, without compiling it
    ComputeLayoutCfg declareCompute(ShaderDecl shader, VkSpecializationInfo* specialization = null)
    {
        auto identity = computeIdentity(shader, specialization);
        auto key = identity.key;

        synchronized(mutex)
        {
            if(auto found = key in computeByKey)
            {
                ref existing = computeTechniques[*found];

                return ComputeLayoutCfg(existing.key, existing.pipelineLayout, existing.setLayout);
            }

            ComputeTechnique entry;
            entry.key = key;
            entry.slot = identity.slot;
            entry.shader = shader;
            entry.hasSpecialization = specialization !is null;
            entry.specialization = copySpecialization(entry, specialization);

            auto bindings = createLayoutBinding([shader]);
            entry.setLayout = internSetLayout(bindings);
            entry.pipelineLayout = internComputePipelineLayout(
                entry.setLayout,
                pushConstantRanges([shader]),
            );

            computeTechniques ~= entry;
            computeByKey[key] = computeTechniques.length - 1;

            return ComputeLayoutCfg(key, entry.pipelineLayout, entry.setLayout);
        }
    }

    /// Returns the shared compute pipeline for a declared kernel
    ComputePipelineCfg acquireCompute(PipelineKey key)
    {
        synchronized(mutex)
        {
            auto found = key in computeByKey;
            assert(found !is null, "compute kernel was not declared");

            ref technique = computeTechniques[*found];

            if(technique.cfg.pipeline !is null)
                return technique.cfg;

            technique.cfg = createComputePipeline(technique);

            return technique.cfg;
        }
    }

    /// Returns a ready variant without creating one
    bool tryAcquire(PipelineKey key, RenderPass renderPass, uint subpass, out GraphicsPipelineCfg cfg)
    {
        synchronized(mutex)
        {
            const instance = PipelineInstance(key, targetId(renderPass, subpass));

            if(auto found = instance in cache)
            {
                cfg = *found;
                return true;
            }

            return false;
        }
    }

    /// Queues a variant for the preload thread; a ready or queued variant is ignored
    void request(PipelineKey key, RenderPass renderPass, uint subpass = 0)
    {
        if(preloadThread is null)
            return;

        synchronized(mutex)
        {
            const instance = PipelineInstance(key, targetId(renderPass, subpass));

            if((instance in cache) || (instance in requested))
                return;

            requested[instance] = true;
            pending ~= Pending(instance, key, renderPass, subpass);
            condition.notify();
        }
    }

    /// Blocks until the preload thread has built every queued variant
    void waitForRequests()
    {
        if(preloadThread is null)
            return;

        synchronized(mutex)
            while(pending.length > 0 || building > 0)
                condition.wait();
    }

    private void preloadRun()
    {
        while(true)
        {
            Pending job;

            mutex.lock();

            while(pending.length == 0 && !stopping)
                condition.wait();

            if(pending.length == 0)
            {
                mutex.unlock();
                break;
            }

            job = pending[0];
            pending = pending[1 .. $];
            ++building;
            mutex.unlock();

            try
                acquire(job.key, job.pass, job.subpass);
            catch(Exception e)
                Instance.log_info("pipeline preload failed: " ~ e.msg);

            mutex.lock();
            --building;
            requested.remove(job.instance);
            if(pending.length == 0 && building == 0)
                condition.notifyAll();
            mutex.unlock();
        }
    }

    DescriptorAllocator descriptorAllocator(PipelineKey key)
    {
        const id = techniqueId(key);

        return techniques[id.value].allocator;
    }

    /// A private allocator for the same technique, for one loading thread.
    DescriptorAllocator createDescriptorAllocator(PipelineKey key)
    {
        const id = techniqueId(key);

        ref technique = techniques[id.value];

        auto allocator = new DescriptorAllocator(device, technique.setLayout, technique.bindings, technique.setsPerPool);
        owner.own(allocator);

        return allocator;
    }

    string techniqueName(PipelineKey key) const
    {
        return techniques[techniqueId(key).value].description.name;
    }

    private TechniqueId techniqueId(PipelineKey key) const
    {
        auto found = key in techniqueByKey;

        assert(found !is null, "pipeline key was not declared");

        return *found;
    }

    private VkDescriptorSetLayout internSetLayout(VkDescriptorSetLayoutBinding[] bindings)
    {
        foreach(i, ref existing; setLayoutBindings)
            if(existing == bindings)
                return setLayouts[i];

        auto handle = new SetLayoutHandle;
        handle.layout = device.createDescriptorSetLayout(bindings);
        owner.own(handle);

        setLayouts ~= handle.layout.vk;
        setLayoutBindings ~= bindings.dup;

        return handle.layout.vk;
    }

    private VkPipelineLayout internPipelineLayout(
        VkDescriptorSetLayout setLayout,
        VkPushConstantRange[] pushConstants,
    )
    {
        foreach(ref entry; pipelineLayoutEntries)
            if(entry.setLayout == setLayout && entry.pushConstants == pushConstants)
                return entry.layout;

        auto layoutObj = VkObj!VkPipelineLayout(device.releaseQueue,
            VkPipelineLayoutCreateInfo(
                setLayoutCount: 2,
                pSetLayouts: [setLayout, frameSetLayout.layout.vk].ptr,
                pushConstantRangeCount: cast(uint) pushConstants.length,
                pPushConstantRanges: pushConstants.ptr,
            ));

        auto layout = layoutObj.vk;
        owner.accept(layoutObj);

        pipelineLayoutEntries ~= PipelineLayoutEntry(setLayout, pushConstants.dup, layout);

        return layout;
    }

    private VkPipelineLayout internComputePipelineLayout(
        VkDescriptorSetLayout setLayout,
        VkPushConstantRange[] pushConstants,
    )
    {
        foreach(ref entry; computeLayoutEntries)
            if(entry.setLayout == setLayout && entry.pushConstants == pushConstants)
                return entry.layout;

        auto layoutObj = VkObj!VkPipelineLayout(device.releaseQueue,
            VkPipelineLayoutCreateInfo(
                setLayoutCount: 1,
                pSetLayouts: &setLayout,
                pushConstantRangeCount: cast(uint) pushConstants.length,
                pPushConstantRanges: pushConstants.ptr,
            ));

        auto layout = layoutObj.vk;
        owner.accept(layoutObj);

        computeLayoutEntries ~= ComputeLayoutEntry(setLayout, pushConstants.dup, layout);

        return layout;
    }

    private RenderTargetId targetId(RenderPass renderPass, uint subpass)
    {
        foreach(i, ref target; targets)
            if(target.renderPass == renderPass.vkRenderPass && target.subpass == subpass)
                return RenderTargetId(cast(uint) i);

        targets ~= RenderTarget(renderPass.vkRenderPass, subpass);

        return RenderTargetId(cast(uint)(targets.length - 1));
    }

    private GraphicsPipelineCfg createPipeline(PipelineKey key, RenderPass renderPass, uint subpass)
    {
        import pukan.vulkan.defaults: multisampling;

        debug import core.time: MonoTime;

        debug const start = MonoTime.currTime;

        ref technique = techniques[techniqueId(key).value];
        const state = technique.description.state;

        VkPipelineShaderStageCreateInfo[] stages;
        foreach(ref decl; technique.description.stages)
            stages ~= device.uploadShaderDecl(decl).createShaderStageInfo;

        VkDynamicState[] dynamicStates = [
            VK_DYNAMIC_STATE_VIEWPORT,
            VK_DYNAMIC_STATE_SCISSOR,
        ];
        dynamicStates ~= technique.description.dynamicStates;

        VkPipelineDynamicStateCreateInfo dynamicStateInfo = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            dynamicStateCount: cast(uint) dynamicStates.length,
            pDynamicStates: dynamicStates.ptr,
        };

        auto vertexInput = techniqueVertexInput(technique.description.stages);

        VkPipelineVertexInputStateCreateInfo vertexInputInfo = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            vertexBindingDescriptionCount: cast(uint) vertexInput.bindings.length,
            pVertexBindingDescriptions: vertexInput.bindings.ptr,
            vertexAttributeDescriptionCount: cast(uint) vertexInput.attributes.length,
            pVertexAttributeDescriptions: vertexInput.attributes.ptr,
        };

        VkPipelineViewportStateCreateInfo viewportState = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            viewportCount: 1,
            scissorCount: 1,
        };

        VkPipelineInputAssemblyStateCreateInfo inputAssembly = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            topology: state.topology,
            primitiveRestartEnable: VK_FALSE,
        };

        VkPipelineRasterizationStateCreateInfo rasterizerInfo = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            depthClampEnable: VK_FALSE,
            rasterizerDiscardEnable: VK_FALSE,
            polygonMode: VK_POLYGON_MODE_FILL,
            cullMode: state.cullMode,
            frontFace: state.frontFace,
            depthBiasEnable: state.depthBiasEnable,
            depthBiasConstantFactor: state.depthBiasConstantFactor,
            depthBiasClamp: 0.0f,
            depthBiasSlopeFactor: state.depthBiasSlopeFactor,
            lineWidth: 1.0f,
        };

        VkPipelineDepthStencilStateCreateInfo depthStencil = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            depthTestEnable: state.depthTestEnable,
            depthWriteEnable: state.depthWriteEnable,
            depthCompareOp: state.depthCompareOp,
            depthBoundsTestEnable: VK_FALSE,
            stencilTestEnable: VK_FALSE,
        };

        VkPipelineColorBlendAttachmentState colorBlendAttachment = {
            blendEnable: state.blendEnable,
            srcColorBlendFactor: state.blendEnable ? VK_BLEND_FACTOR_SRC_ALPHA : VK_BLEND_FACTOR_ONE,
            dstColorBlendFactor: state.blendEnable ? VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA : VK_BLEND_FACTOR_ZERO,
            colorBlendOp: VK_BLEND_OP_ADD,
            srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE,
            dstAlphaBlendFactor: state.blendEnable ? VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA : VK_BLEND_FACTOR_ZERO,
            alphaBlendOp: VK_BLEND_OP_ADD,
            colorWriteMask: state.colorWriteMask,
        };

        VkPipelineMultisampleStateCreateInfo multisampleState = multisampling;
        multisampleState.rasterizationSamples = renderPass.samples;
        multisampleState.alphaToCoverageEnable = state.alphaToCoverage;

        VkPipelineColorBlendStateCreateInfo colorBlending = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            logicOpEnable: VK_FALSE,
            logicOp: VK_LOGIC_OP_COPY,
            attachmentCount: state.colorAttachmentCount,
            pAttachments: state.colorAttachmentCount > 0 ? &colorBlendAttachment : null,
            blendConstants: [0.0f, 0.0f, 0.0f, 0.0f],
        };

        VkGraphicsPipelineCreateInfo pipelineCreateInfo = {
            sType: VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            stageCount: cast(uint) stages.length,
            pStages: stages.ptr,
            pVertexInputState: &vertexInputInfo,
            pInputAssemblyState: &inputAssembly,
            pViewportState: &viewportState,
            pRasterizationState: &rasterizerInfo,
            pMultisampleState: &multisampleState,
            pDepthStencilState: &depthStencil,
            pColorBlendState: &colorBlending,
            pDynamicState: &dynamicStateInfo,
            layout: technique.pipelineLayout,
            renderPass: renderPass.vkRenderPass,
            subpass: subpass,
            basePipelineHandle: null,
            basePipelineIndex: -1,
        };

        const identity = variantIdentity(key, technique.slot, renderPass, subpass);

        bool needsRecompilation;
        auto pipelineCache = acquirePipelineCache(identity, needsRecompilation);
        scope(exit) device.destroyPipelineCache(pipelineCache);

        auto pipeline = device.createGraphicsPipelines([pipelineCreateInfo], pipelineCache)[0];

        auto slot = VkObj!VkPipeline(pipeline, device.releaseQueue);
        owner.accept(slot);

        storePipelineCache(identity, pipelineCache);

        debug
        {
            const elapsed = MonoTime.currTime - start;

            pipelineCreationTime += elapsed;

            if(needsRecompilation)
                ++compiledVariants;
            else
            {
                ++cachedVariants;
                assert(pipeline != VkPipeline.init, "a cached pipeline variant is not valid");
            }

            Instance.log_info(
                "pipeline cache: " ~ technique.description.name ~ "-" ~ identity.toString() ~
                (needsRecompilation ? " compiled" : " cached") ~
                " in " ~ elapsed.total!"usecs".to!string ~ " us");
        }

        return GraphicsPipelineCfg(
            graphicsPipeline: pipeline,
            pipelineLayout: technique.pipelineLayout,
            needsRecompilation: needsRecompilation,
        );
    }

    private ComputePipelineCfg createComputePipeline(ref ComputeTechnique technique)
    {
        debug import core.time: MonoTime;

        debug const start = MonoTime.currTime;

        auto shader = device.uploadShaderDecl(technique.shader);
        auto stage = shader.createShaderStageInfo;
        stage.pSpecializationInfo = technique.hasSpecialization ? &technique.specialization : null;

        VkComputePipelineCreateInfo pipelineCreateInfo = {
            sType: VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            stage: stage,
            layout: technique.pipelineLayout,
            basePipelineHandle: null,
            basePipelineIndex: -1,
        };

        const identity = computeVariantIdentity(technique.key, technique.slot);

        bool needsRecompilation;
        auto pipelineCache = acquirePipelineCache(identity, needsRecompilation);
        scope(exit) device.destroyPipelineCache(pipelineCache);

        auto pipeline = device.createComputePipelines([pipelineCreateInfo], pipelineCache)[0];

        auto slot = VkObj!VkPipeline(pipeline, device.releaseQueue);
        owner.accept(slot);

        storePipelineCache(identity, pipelineCache);

        debug
        {
            const elapsed = MonoTime.currTime - start;

            pipelineCreationTime += elapsed;

            if(needsRecompilation)
                ++compiledVariants;
            else
            {
                ++cachedVariants;
                assert(pipeline != VkPipeline.init, "a cached compute pipeline is not valid");
            }

            Instance.log_info(
                "pipeline cache: " ~ technique.shader.file ~ "-" ~ identity.toString() ~
                (needsRecompilation ? " compiled" : " cached") ~
                " in " ~ elapsed.total!"usecs".to!string ~ " us");
        }

        return ComputePipelineCfg(
            pipeline: pipeline,
            pipelineLayout: technique.pipelineLayout,
            setLayout: technique.setLayout,
            needsRecompilation: needsRecompilation,
        );
    }

    /// What a kernel is for the store: bindings, push constant, specialization
    /// and shader sums, with no render target.
    private static PipelineVariantKey computeVariantIdentity(PipelineKey key, const(ubyte)[32] slot)
    {
        PipelineVariantKeyBuilder builder;
        builder.addKey(slot, key.digest);

        return builder.finish;
    }

    /// Driver cache for one variant, seeded with its stored record
    private VkPipelineCache acquirePipelineCache(PipelineVariantKey identity, out bool needsRecompilation)
    {
        needsRecompilation = false;

        if(cacheManager)
            return cacheManager.acquire(identity, needsRecompilation);

        needsRecompilation = true;

        return device.createPipelineCache();
    }

    /// Hands the driver blob to the writer, which saves it outside the frame
    private void storePipelineCache(PipelineVariantKey identity, VkPipelineCache pipelineCache)
    {
        if(cacheManager)
            cacheManager.storeResult(identity, pipelineCache);
    }

    /**
        What a variant is for the store, not how its creation info is
        assembled. The shader sums change the digest but not the slot.
    */
    private PipelineVariantKey variantIdentity(
        PipelineKey key,
        const(ubyte)[32] slot,
        RenderPass renderPass,
        uint subpass,
    ) const
    {
        PipelineVariantKeyBuilder builder;
        builder.addKey(slot, key.digest);
        builder.add(renderPass.imageFormat);
        builder.add(renderPass.depthFormat);
        builder.add(renderPass.samples);
        builder.add(subpass);

        return builder.finish;
    }

    private static ShaderVertexInput techniqueVertexInput(ShaderDecl[] stages)
    {
        ShaderVertexInput result;
        bool found;

        foreach(ref stage; stages)
            if(stage.stage == VK_SHADER_STAGE_VERTEX_BIT)
            {
                assert(!found, "multiple vertex shader stages in one technique");
                result = stage.vertexInput;
                found = true;
            }

        return result;
    }

    private static VkPushConstantRange[] pushConstantRanges(ShaderDecl[] stages)
    {
        VkPushConstantRange[] ranges;

        foreach(ref stage; stages)
        {
            if(!stage.pushConstantRange.stageFlags)
                continue;

            bool found;
            foreach(ref range; ranges)
                if(range == stage.pushConstantRange)
                {
                    found = true;
                    break;
                }

            if(!found)
                ranges ~= stage.pushConstantRange;
        }

        return ranges;
    }
}

unittest
{
    ShaderDecl stage;
    stage.file = "test.spv";
    stage.stage = VK_SHADER_STAGE_VERTEX_BIT;
    stage.checksum[0] = 1;

    const first = PipelineFactory.techniqueIdentity(RenderTechnique(
        name: "first",
        stages: [stage],
    ));
    const renamed = PipelineFactory.techniqueIdentity(RenderTechnique(
        name: "second",
        stages: [stage],
    ));

    assert(first.key == renamed.key);
    assert(first.slot[] == renamed.slot[]);

    auto changedShader = stage;
    changedShader.checksum[0] = 2;

    const changed = PipelineFactory.techniqueIdentity(RenderTechnique(
        name: "first",
        stages: [changedShader],
    ));

    assert(first.key != changed.key);
    assert(first.slot[] == changed.slot[]);
    assert(first.key.digest[] != changed.key.digest[]);

    auto renamedFile = stage;
    renamedFile.file = "other.spv";

    const otherFile = PipelineFactory.techniqueIdentity(RenderTechnique(
        name: "first",
        stages: [renamedFile],
    ));

    assert(first.key == otherFile.key);
    assert(first.slot[] != otherFile.slot[]);
}
