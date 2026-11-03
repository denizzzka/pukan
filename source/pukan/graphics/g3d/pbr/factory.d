module pukan.graphics.g3d.pbr.factory;

import pukan.graphics.g3d.mesh: MeshResources;
import pukan.vulkan;
import pukan.vulkan.pipelines: DescriptorAllocator, PipelineFactory, PipelineKey;

class PbrFactory
{
    LogicalDevice device;
    private PipelineFactory pipelines;
    private PipelineKey materialLayout;
    MeshResources resources;

    this(
        LogicalDevice device,
        PipelineFactory pipelines,
        MeshResources resources,
        PipelineKey materialLayout,
    )
    {
        this.device = device;
        this.pipelines = pipelines;
        this.resources = resources;
        this.materialLayout = materialLayout;
    }

    /// A private allocator, so loads can run on different threads.
    DescriptorAllocator createAllocator()
    {
        return pipelines.createDescriptorAllocator(materialLayout);
    }
}
