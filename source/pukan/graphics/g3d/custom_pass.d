module pukan.graphics.g3d.custom_pass;

import pukan.graphics.g3d.material: AlphaMode;
import pukan.graphics.g3d.pbr.pipelines: LazyPipeline, PbrProfile;
import pukan.vulkan.bindings;
import pukan.vulkan.renderpass: DrawPhase;

/// Properties of one draw the core offers to the active pass
struct DrawSubject
{
    DrawPhase phase;
    PbrProfile profile;
    AlphaMode alphaMode;
    /// Opaque surface: neither blended nor off on its own transmission pass
    bool opaque;
    bool doubleSided;
    bool skinned;
    /// PBR material, not lit or unlit
    bool pbr;
}

/// Pipeline the active pass substitutes for one draw
struct PipelineOverride
{
    /// Null leaves the draw to the core
    LazyPipeline* pipeline;
    /// Pass data the draw pushes before its pipeline, empty for none
    const(ubyte)[] data;

    bool claimed() const => pipeline !is null;
}

/// Where a pass-data block starts, after the model matrix of the vertex stages
enum passDataOffset = 64;

/// A scene effect with its own phases, pipelines and data. The scene records
/// one at a time; while none is active every draw takes the ordinary path.
abstract class CustomPass
{
    /// Whether the pass records anything this frame; an off pass costs nothing
    abstract bool active() const;

    /// Whether the scene records `DrawPhase.custom` between `begin` and the
    /// ordinary opaque draws
    bool drawsCustomPhase() const => false;

    /// Prepares the attachments the pass draws into
    void begin(VkCommandBuffer cmd, VkDescriptorSet frameSet, VkExtent2D extent) {}

    /// Records what follows the opaque draws, before the blended ones
    void end(VkCommandBuffer cmd, VkDescriptorSet frameSet) {}

    /// Before the blended draws
    void beforeBlended(VkCommandBuffer cmd, VkDescriptorSet frameSet) {}

    /// After the blended draws
    void afterBlended(VkCommandBuffer cmd, VkDescriptorSet frameSet) {}

    /// Whether a draw belongs to the pass's own phase
    bool claims(in DrawSubject subject) => false;

    /// Replaces the ordinary pipeline of a draw; an unclaimed result leaves it
    PipelineOverride overridePipeline(in DrawSubject subject) => PipelineOverride.init;
}

/// Pass the drawables consult while the scene records; null when none is on
CustomPass activeCustomPass;

/// Views a struct as the bytes a push constant block reads
const(ubyte)[] pushConstantBytes(T)(ref T value)
{
    return (cast(const(ubyte)*) &value)[0 .. T.sizeof];
}
