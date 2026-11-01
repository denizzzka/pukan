module pukan.pbr.factory;

import pukan.mesh: MeshResources;
import pukan.pbr.pipeline_set: PbrPipelineSet;
import pukan.pbr.pipelines: PbrPipelines, PbrProfile;
import pukan.vulkan;
import pukan.vulkan.pipelines: DescriptorAllocator, PipelineFactory, PipelineKey;

class PbrFactory
{
    LogicalDevice device;
    private PipelineFactory pipelines;
    private PipelineKey materialLayout;
    MeshResources resources;
    PbrPipelines[PbrProfile] sets;

    this(
        LogicalDevice device,
        PipelineFactory pipelines,
        MeshResources resources,
        PbrPipelineSet declarations,
    )
    {
        this.device = device;
        this.pipelines = pipelines;
        this.resources = resources;
        this.sets = declarations.sets;
        this.materialLayout = declarations.materialLayout;
    }

    /// Queues every variant of both families, for the all warmup policy
    void warmAll()
    {
        foreach(ref set; sets)
            set.warmAll();
    }

    /// Queues the selected concrete variants of both families
    void warmVariants(Variants...)()
    {
        foreach(ref set; sets)
            static foreach(v; Variants)
                set.warmVariant(v);
    }

    /// Throws when any variant of either family is missing
    void validateAll()
    {
        foreach(ref set; sets)
            set.validateAll();
    }

    /// Active pipeline set of a profile
    PbrPipelines pipelinesFor(PbrProfile profile)
    {
        auto found = profile in sets;
        assert(found !is null, "pipeline profile is not active");
        return *found;
    }

    /// A private allocator, so loads can run on different threads.
    DescriptorAllocator createAllocator()
    {
        return pipelines.createDescriptorAllocator(materialLayout);
    }
}
