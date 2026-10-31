module pukan.vulkan.pipelines;

import frame_bindings;

import pukan.exceptions: PukanException;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;
import pukan.vulkan.pipeline_cache: PipelineCacheLoadException, PipelineCacheStore;
import core.sync.condition: Condition;
import core.sync.mutex: Mutex;
import core.thread: Thread;
import std.conv: to;

debug
{
    import core.time: Duration;
}

package mixin template Pipelines()
{
    private VkPipeline[] pipelines;
    private VkPipelineLayout[] pipelineLayouts;

    /// Registers a pipeline layout to be destroyed after all pipelines
    void registerPipelineLayout(VkPipelineLayout layout)
    {
        synchronized(this)
            pipelineLayouts ~= layout;
    }

    private void pipelinesDtor()
    {
        foreach(ref p; pipelines)
            vkDestroyPipeline(this.device, p, this.alloc);

        foreach(layout; pipelineLayouts)
            vkDestroyPipelineLayout(this.device, layout, this.alloc);
    }

    VkPipeline[] createGraphicsPipelines(
        VkGraphicsPipelineCreateInfo[] infos,
        VkPipelineCache pipelineCache = null,
    )
    out(r; r.length == infos.length)
    {
        synchronized(this)
        {
            size_t prevLen = pipelines.length;
            pipelines.length += infos.length;

            vkCreateGraphicsPipelines(
                this.device,
                pipelineCache,
                cast(uint) infos.length,
                infos.ptr,
                this.alloc,
                &pipelines[prevLen]
            ).vkCheck;

            return pipelines[prevLen .. $];
        }
    }

    VkPipeline[] createComputePipelines(
        VkComputePipelineCreateInfo[] infos,
        VkPipelineCache pipelineCache = null,
    )
    out(r; r.length == infos.length)
    {
        synchronized(this)
        {
            size_t prevLen = pipelines.length;
            pipelines.length += infos.length;

            vkCreateComputePipelines(
                this.device,
                pipelineCache,
                cast(uint) infos.length,
                infos.ptr,
                this.alloc,
                &pipelines[prevLen]
            ).vkCheck;

            return pipelines[prevLen .. $];
        }
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

struct TechniqueId
{
    uint value;
}

struct RenderTargetId
{
    uint value;
}

struct PipelineKey
{
    TechniqueId technique;
    RenderTargetId target;

    size_t toHash() const nothrow @safe
    {
        return hashOf(technique.value, hashOf(target.value));
    }

    bool opEquals(ref const PipelineKey rhs) const nothrow @safe
    {
        return technique.value == rhs.technique.value &&
            target.value == rhs.target.value;
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
    ShaderInfo[] stages;
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

    VkDescriptorSet allocate()
    {
        if(pools.length == 0 || allocatedInCurrentPool == setsPerPool)
            addPool();

        VkDescriptorSetAllocateInfo info = {
            sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool: pools[$ - 1],
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
            info.descriptorPool = pools[$ - 1];
        }
    }

    private void addPool()
    {
        auto poolAndLayout = device.createDescriptorPool(layout, bindings, setsPerPool);
        pools ~= poolAndLayout.descriptorPool;
        allocatedInCurrentPool = 0;
    }
}

/// Writes cache blobs on one background thread, never inside the frame
private final class PipelineCacheWriter
{
    private struct Job
    {
        string identity;
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

    void put(string identity, ubyte[] payload)
    {
        mutex.lock();
        jobs ~= Job(identity, payload);
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
                store.save(job.identity, job.payload);
            catch(Exception e)
                Instance.log_info("pipeline cache: " ~ job.identity ~ " not saved: " ~ e.msg);
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
            writer = new PipelineCacheWriter(store);
    }

    ~this()
    {
        if(writer)
            destroy(writer);
    }

    /// Whether variants are persisted at all
    bool enabled() const => store !is null;

    /// Driver cache for one variant, seeded with its stored record
    VkPipelineCache acquire(string identity, out bool needsRecompilation)
    {
        ubyte[] payload;
        needsRecompilation = false;

        if(store)
            while(true)
            {
                try
                {
                    payload = store.load(identity);
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

        if(payload is null)
            needsRecompilation = true;

        return device.createPipelineCache(payload);
    }

    /// Hands the driver blob to the writer, which saves it outside the frame
    void storeResult(string identity, VkPipelineCache pipelineCache)
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

    private struct PipelineLayoutEntry
    {
        VkDescriptorSetLayout setLayout;
        VkPushConstantRange[] pushConstants;
        VkPipelineLayout layout;
    }

    private LogicalDevice device;
    private Technique[] techniques;
    private RenderTarget[] targets;
    private GraphicsPipelineCfg[PipelineKey] cache;
    private PipelineCacheManager cacheManager;

    debug
    {
        /// Variants this run compiled because no usable record existed
        size_t compiledVariants;
        /// Variants created from a stored record
        size_t cachedVariants;
        /// Time spent loading records and creating pipelines
        Duration pipelineCreationTime;
    }

    private VkDescriptorSetLayout[] setLayouts;
    private VkDescriptorSetLayoutBinding[][] setLayoutBindings;
    private PipelineLayoutEntry[] pipelineLayoutEntries;

    private VkDescriptorSetLayout frameSetLayout;
    private VkDescriptorSetLayoutBinding[] frameBindings;

    this(LogicalDevice device, PipelineCacheManager cacheManager = null)
    {
        this.device = device;
        this.cacheManager = cacheManager;

        frameBindings = [
            VkDescriptorSetLayoutBinding(
                binding: FRAME_UNIFORM,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: FRAME_IRRADIANCE,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: FRAME_PREFILTERED,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: FRAME_BRDF_LUT,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: FRAME_SCENE_COLOR,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: FRAME_OIT_HEADS,
                descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: FRAME_OIT_FRAGMENTS,
                descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: FRAME_OIT_COUNTER,
                descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: FRAME_LIGHTS,
                descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: FRAME_SHADOW_MAP,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: FRAME_SCENE_DEPTH,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: FRAME_DEPTH_MS,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
        ];
        frameSetLayout = device.createDescriptorSetLayout(frameBindings);
    }

    ~this()
    {
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
        return new DescriptorAllocator(device, frameSetLayout, frameBindings, 16);
    }

    TechniqueId declare(RenderTechnique technique, uint setsPerPool = 16)
    {
        Technique entry;
        entry.description = technique;

        auto bindings = createLayoutBinding(technique.stages);
        auto setLayout = internSetLayout(bindings);

        entry.pipelineLayout = internPipelineLayout(setLayout, pushConstantRanges(technique.stages));

        entry.setLayout = setLayout;
        entry.bindings = bindings;
        entry.setsPerPool = setsPerPool;
        entry.allocator = new DescriptorAllocator(device, setLayout, bindings, setsPerPool);

        techniques ~= entry;

        return TechniqueId(cast(uint)(techniques.length - 1));
    }

    GraphicsPipelineCfg acquire(TechniqueId id, RenderPass renderPass, uint subpass = 0)
    {
        const key = PipelineKey(id, targetId(renderPass, subpass));

        if(auto found = key in cache)
            return *found;

        try
            cache[key] = createPipeline(id, renderPass, subpass);
        catch(PukanException e)
        {
            e.msg = "technique " ~ techniqueName(id) ~ ": " ~ e.msg;
            throw e;
        }

        return cache[key];
    }

    DescriptorAllocator descriptorAllocator(TechniqueId id)
    {
        assert(id.value < techniques.length);

        return techniques[id.value].allocator;
    }

    /// A private allocator for the same technique, for one loading thread.
    DescriptorAllocator createDescriptorAllocator(TechniqueId id)
    {
        assert(id.value < techniques.length);

        ref technique = techniques[id.value];

        return new DescriptorAllocator(device, technique.setLayout, technique.bindings, technique.setsPerPool);
    }

    string techniqueName(TechniqueId id) const
    {
        assert(id.value < techniques.length);

        return techniques[id.value].description.name;
    }

    private VkDescriptorSetLayout internSetLayout(VkDescriptorSetLayoutBinding[] bindings)
    {
        foreach(i, ref existing; setLayoutBindings)
            if(existing == bindings)
                return setLayouts[i];

        auto layout = device.createDescriptorSetLayout(bindings);

        setLayouts ~= layout;
        setLayoutBindings ~= bindings.dup;

        return layout;
    }

    private VkPipelineLayout internPipelineLayout(
        VkDescriptorSetLayout setLayout,
        VkPushConstantRange[] pushConstants,
    )
    {
        foreach(ref entry; pipelineLayoutEntries)
            if(entry.setLayout == setLayout && entry.pushConstants == pushConstants)
                return entry.layout;

        auto layout = createPipelineLayout(device, [setLayout, frameSetLayout], pushConstants);
        device.registerPipelineLayout(layout);

        pipelineLayoutEntries ~= PipelineLayoutEntry(setLayout, pushConstants.dup, layout);

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

    private GraphicsPipelineCfg createPipeline(TechniqueId id, RenderPass renderPass, uint subpass)
    {
        import pukan.vulkan.defaults: multisampling;

        debug import core.time: MonoTime;

        debug const start = MonoTime.currTime;

        ref technique = techniques[id.value];
        const state = technique.description.state;

        VkPipelineShaderStageCreateInfo[] stages;
        foreach(ref stage; technique.description.stages)
            stages ~= stage.createShaderStageInfo;

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

        const identity = variantIdentity(id, renderPass, subpass);

        bool needsRecompilation;
        auto pipelineCache = acquirePipelineCache(identity, needsRecompilation);
        scope(exit) device.destroyPipelineCache(pipelineCache);

        auto pipeline = device.createGraphicsPipelines([pipelineCreateInfo], pipelineCache)[0];

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
                "pipeline cache: " ~ identity ~
                (needsRecompilation ? " compiled" : " cached") ~
                " in " ~ elapsed.total!"usecs".to!string ~ " us");
        }

        return GraphicsPipelineCfg(
            graphicsPipeline: pipeline,
            pipelineLayout: technique.pipelineLayout,
            needsRecompilation: needsRecompilation,
        );
    }

    /// Driver cache for one variant, seeded with its stored record
    private VkPipelineCache acquirePipelineCache(string identity, out bool needsRecompilation)
    {
        needsRecompilation = false;

        if(cacheManager)
            return cacheManager.acquire(identity, needsRecompilation);

        needsRecompilation = true;

        return device.createPipelineCache();
    }

    /// Hands the driver blob to the writer, which saves it outside the frame
    private void storePipelineCache(string identity, VkPipelineCache pipelineCache)
    {
        if(cacheManager)
            cacheManager.storeResult(identity, pipelineCache);
    }

    /**
        What a variant is for the store, not how its creation info is
        assembled. Shader bytes stay out, the driver keys those itself.
    */
    private string variantIdentity(TechniqueId id, RenderPass renderPass, uint subpass) const
    {
        import std.ascii: isAlphaNum;
        import std.digest.sha: SHA256, toHexString;

        ref const technique = techniques[id.value];

        SHA256 hash;

        void addValue(T)(in T value)
        {
            hash.put((cast(const ubyte*) &value)[0 .. T.sizeof]);
        }

        void addString(string value)
        {
            addValue(value.length);
            hash.put(cast(const ubyte[]) value);
        }

        void addArray(T)(const(T)[] values)
        {
            addValue(values.length);

            foreach(ref value; values)
                addValue(value);
        }

        addString(technique.description.name);
        addValue(technique.description.state);
        addArray(technique.description.dynamicStates);

        foreach(ref stage; technique.description.stages)
        {
            addValue(stage.stage);
            addValue(stage.pushConstantRange);
            addArray(stage.vertexInput.bindings);
            addArray(stage.vertexInput.attributes);
        }

        addValue(renderPass.imageFormat);
        addValue(renderPass.depthFormat);
        addValue(renderPass.samples);
        addValue(subpass);

        string prefix;

        foreach(c; technique.description.name)
            prefix ~= c.isAlphaNum || c == '_' || c == '-' ? c : '_';

        const digest = hash.finish;

        return cast(string) (prefix ~ "-" ~ toHexString(digest)[0 .. 32]);
    }

    private static ShaderVertexInput techniqueVertexInput(ShaderInfo[] stages)
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

    private static VkPushConstantRange[] pushConstantRanges(ShaderInfo[] stages)
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
