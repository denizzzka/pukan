module pukan.graphics.g2d.ui;

import d_imgui.imgui_h;
import ImGui = d_imgui;

import pukan.graphics.common.shaders: shaderStage;
import pukan.vulkan.bindings;
import pukan.vulkan.descriptors: imageWriteDescriptor;
import pukan.vulkan.frame_builder: createImageView;
import pukan.vulkan.helpers: vkCall;
import pukan.vulkan.image: ImageMemory, loadImageToMemory;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: MemoryBufferMappedToCPU;
import pukan.vulkan.pipelines: DescriptorAllocator, FixedState, GraphicsPipelineCfg, PipelineFactory, PipelineKey, RenderTechnique;
import pukan.vulkan.shaders: ShaderVertexInput;
import pukan.vulkan.renderpass: RenderPass;
import pukan.vulkan.resources.vkobj: VkObj;

import std.algorithm: max, min, sort;
import std.file: read;

/// Unicode coverage a font is built with
enum UiScript: uint
{
    latin,
    cyrillic,
    greek,
    thai,
    vietnamese,
    japanese,
    korean,
    chineseSimplified,
    chineseFull,
}

/// A font request, kept until the atlas is built
private struct FontRequest
{
    string path;
    float size;
    UiScript[] scripts;
    /// Characters the UI shows; the atlas keeps only these
    string text;
    bool merge;
}

/// Dear ImGui rendered over the frame, for debug windows and tools
final class Ui
{
    private LogicalDevice device;
    private PipelineFactory pipelines;

    private UiPass pass;
    private PipelineKey technique;
    private GraphicsPipelineCfg pipeline;
    private VkDescriptorSet fontSet;
    private VkObj!VkSampler fontSampler;
    private VkObj!VkImageView fontView;
    private ImageMemory fontImage;

    private FontRequest[] requests;
    /// Atlas inputs that must outlive the atlas: the TTF bytes and the ranges
    private ubyte[][] fontBytes;
    private ImWchar[][] fontRanges;

    private MemoryBufferMappedToCPU[] vertexBuffers;
    private MemoryBufferMappedToCPU[] indexBuffers;
    private VkObj!VkFramebuffer[] frameBuffers;
    private VkImageView[] frameViews;
    private VkExtent2D[] frameExtents;

    private bool atlasBuilt;
    private bool released;
    private bool inFrame;
    private bool wantsMouse;
    private bool wantsKeyboard;

    this(LogicalDevice device, PipelineFactory pipelines, VkFormat imageFormat)
    {
        this.device = device;
        this.pipelines = pipelines;

        pass = new UiPass(device, imageFormat);

        ImGui.CreateContext();

        ref ImGuiIO io = ImGui.GetIO();
        io.ConfigFlags |= ImGuiConfigFlags.NavEnableKeyboard;
        io.BackendFlags |= ImGuiBackendFlags.RendererHasVtxOffset;
        // A debug overlay keeps its windows in memory, not in the working directory
        io.IniFilename = null;

        technique = pipelines.declare(RenderTechnique(
            name: "ui",
            stages: [
                shaderStage!"ui_vert.spv"(
                    VK_SHADER_STAGE_VERTEX_BIT,
                    [],
                    VkPushConstantRange(
                        stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                        offset: 0,
                        size: 4 * float.sizeof,
                    ),
                    ShaderVertexInput(
                        [
                            VkVertexInputBindingDescription(
                                binding: 0,
                                stride: ImDrawVert.sizeof,
                                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
                            ),
                        ],
                        [
                            VkVertexInputAttributeDescription(
                                location: 0,
                                binding: 0,
                                format: VK_FORMAT_R32G32_SFLOAT,
                                offset: 0,
                            ),
                            VkVertexInputAttributeDescription(
                                location: 1,
                                binding: 0,
                                format: VK_FORMAT_R32G32_SFLOAT,
                                offset: 8,
                            ),
                            VkVertexInputAttributeDescription(
                                location: 2,
                                binding: 0,
                                format: VK_FORMAT_R8G8B8A8_UNORM,
                                offset: 16,
                            ),
                        ],
                    ),
                ),
                shaderStage!"ui_frag.spv"(
                    VK_SHADER_STAGE_FRAGMENT_BIT,
                    [
                        VkDescriptorSetLayoutBinding(
                            binding: 0,
                            descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                            descriptorCount: 1,
                            stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
                        ),
                    ],
                ),
            ],
            state: FixedState(
                cullMode: VK_CULL_MODE_NONE,
                depthTestEnable: VK_FALSE,
                depthWriteEnable: VK_FALSE,
                blendEnable: VK_TRUE,
            ),
        ));

        pipeline = pipelines.acquire(technique, pass, 0);
    }

    ~this()
    {
        if(released)
            return;

        released = true;

        ImGui.DestroyContext();

        if(fontImage !is null)
            destroy(fontImage);

        fontSampler = VkObj!VkSampler.init;
        fontView = VkObj!VkImageView.init;

        foreach(ref buffer; vertexBuffers)
            if(buffer !is null)
                destroy(buffer);

        foreach(ref buffer; indexBuffers)
            if(buffer !is null)
                destroy(buffer);

        foreach(ref buffer; frameBuffers)
            buffer = VkObj!VkFramebuffer.init;

        vertexBuffers = null;
        indexBuffers = null;
        frameBuffers = null;

        if(pass !is null)
            destroy(pass);
    }

    /// Queues a TrueType file; `scripts` and `text` decide which glyphs it holds
    void addFont(string path, float size, UiScript[] scripts = [UiScript.latin], string text = "", bool merge = false)
    {
        requests ~= FontRequest(path, size, scripts, text, merge);
    }

    /// Registers a font request for a file with every script it contains
    void addFontFile(string path, float size, UiScript[] scripts = [UiScript.latin], string text = "")
    {
        addFont(path, size, scripts, text, requests.length != 0);
    }

    void setFontScale(float scale)
    {
        ImGui.GetIO().FontGlobalScale = scale;
        ImGui.GetStyle().ScaleAllSizes(scale);
    }

    /// Queues the pointer state for the frame that `beginFrame` starts
    void setMouse(float x, float y, bool left, bool right, bool middle,
        float wheelX = 0, float wheelY = 0)
    {
        ref ImGuiIO io = ImGui.GetIO();
        io.AddMousePosEvent(x, y);
        io.AddMouseButtonEvent(0, left);
        io.AddMouseButtonEvent(1, right);
        io.AddMouseButtonEvent(2, middle);

        if(wheelX != 0 || wheelY != 0)
            io.AddMouseWheelEvent(wheelX, wheelY);
    }

    void addKey(ImGuiKey key, bool down)
    {
        ImGui.GetIO().AddKeyEvent(key, down);
    }

    void addText(string value) nothrow @nogc
    {
        ImGui.GetIO().AddInputCharactersUTF8(value);
    }

    /// Starts the frame; windows are built between this and the render pass
    void beginFrame(float deltaSeconds, VkExtent2D extent)
    {
        // A frame can end without a render pass, for example when the swapchain
        // was out of date; ImGui has to be told before another one begins
        if(inFrame)
        {
            ImGui.Render();
            inFrame = false;
        }

        buildAtlas();

        ref ImGuiIO io = ImGui.GetIO();
        io.DisplaySize = ImVec2(cast(float) extent.width, cast(float) extent.height);
        io.DisplayFramebufferScale = ImVec2(1, 1);
        io.DeltaTime = deltaSeconds > 0.0f ? deltaSeconds : 1.0f / 60.0f;

        ImGui.NewFrame();
        inFrame = true;

        wantsMouse = io.WantCaptureMouse;
        wantsKeyboard = io.WantCaptureKeyboard;
    }

    /// Whether the UI takes the pointer this frame, so the camera must not
    bool capturesMouse() const => wantsMouse;

    bool capturesKeyboard() const => wantsKeyboard;

    /// Records the windows built since `beginFrame` into the frame's colour
    void record(VkCommandBuffer buf, VkImageView colorView, uint frameIndex, VkExtent2D extent)
    {
        if(!inFrame)
            return;

        inFrame = false;
        ImGui.Render();

        auto data = ImGui.GetDrawData();

        if(data is null || data.CmdListsCount == 0 || data.TotalVtxCount == 0)
            return;

        ensureFrame(frameIndex, colorView, extent);
        const vertexBytes = cast(size_t) data.TotalVtxCount * ImDrawVert.sizeof;
        const indexBytes = cast(size_t) data.TotalIdxCount * ImDrawIdx.sizeof;
        ensureBuffers(frameIndex, vertexBytes, indexBytes);

        auto vertices = cast(ImDrawVert[]) vertexBuffers[frameIndex].cpuBuf[0 .. vertexBytes];
        auto indices = cast(ImDrawIdx[]) indexBuffers[frameIndex].cpuBuf[0 .. indexBytes];

        size_t[] vertexBase;
        size_t[] indexBase;
        uint vertexOffset;
        uint indexOffset;

        foreach(i; 0 .. cast(uint) data.CmdListsCount)
        {
            auto list = data.CmdLists[i];
            const listVertices = list.VtxBuffer.asArray();
            const listIndices = list.IdxBuffer.asArray();

            vertexBase ~= vertexOffset;
            indexBase ~= indexOffset;
            vertices[vertexOffset .. vertexOffset + listVertices.length] = listVertices;
            indices[indexOffset .. indexOffset + listIndices.length] = listIndices;
            vertexOffset += cast(uint) listVertices.length;
            indexOffset += cast(uint) listIndices.length;
        }

        pass.record(buf, frameBuffers[frameIndex].vk, extent, (ref VkCommandBuffer cb)
        {
            VkViewport viewport = {
                x: 0.0f,
                y: 0.0f,
                width: cast(float) extent.width,
                height: cast(float) extent.height,
                minDepth: 0.0f,
                maxDepth: 1.0f,
            };
            vkCmdSetViewport(cb, 0, 1, &viewport);

            vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);
            vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipelineLayout,
                0, 1, &fontSet, 0, null);

            // Pixels to clip space; Vulkan's clip y grows downwards
            float[4] transform = [
                2.0f / extent.width,
                2.0f / extent.height,
                -1.0f,
                -1.0f,
            ];
            vkCmdPushConstants(cb, pipeline.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT,
                0, uint(transform.sizeof), &transform);

            foreach(i; 0 .. cast(uint) data.CmdListsCount)
            {
                auto list = data.CmdLists[i];
                const vertexStart = vertexBase[i] * ImDrawVert.sizeof;
                const indexStart = indexBase[i] * ImDrawIdx.sizeof;
                VkBuffer vertexBuffer = vertexBuffers[frameIndex].buf;
                VkBuffer indexBuffer = indexBuffers[frameIndex].buf;

                vkCmdBindVertexBuffers(cb, 0, 1, &vertexBuffer, &vertexStart);
                vkCmdBindIndexBuffer(cb, indexBuffer, indexStart, VK_INDEX_TYPE_UINT16);

                foreach(command; list.CmdBuffer.asArray())
                {
                    if(command.UserCallback !is null)
                        continue;

                    const clip = command.ClipRect;
                    const left = cast(int) max(0.0f, clip.x);
                    const top = cast(int) max(0.0f, clip.y);
                    const right = cast(int) min(cast(float) extent.width, clip.z);
                    const bottom = cast(int) min(cast(float) extent.height, clip.w);

                    if(right <= left || bottom <= top)
                        continue;

                    VkRect2D scissor = {
                        offset: VkOffset2D(left, top),
                        extent: VkExtent2D(cast(uint) (right - left), cast(uint) (bottom - top)),
                    };
                    vkCmdSetScissor(cb, 0, 1, &scissor);

                    vkCmdDrawIndexed(cb, command.ElemCount, 1, command.IdxOffset, cast(int) command.VtxOffset, 0);
                }
            }
        });
    }

    private void buildAtlas()
    {
        if(atlasBuilt)
            return;

        atlasBuilt = true;

        ref ImGuiIO io = ImGui.GetIO();
        auto fonts = io.Fonts;
        fonts.Clear();

        if(requests.length == 0)
            fonts.AddFontDefault();
        else
            foreach(request; requests)
            {
                ubyte[] bytes = cast(ubyte[]) read(request.path);
                ImWchar[] ranges = buildRanges(fonts, request.scripts, request.text);

                ImFontConfig config = ImFontConfig(false);
                config.MergeMode = request.merge;
                config.FontDataOwnedByAtlas = false;

                fontBytes ~= bytes;
                fontRanges ~= ranges;

                fonts.AddFontFromMemoryTTF(bytes, request.size, &config, ranges.ptr);
            }

        fonts.Build();

        ubyte[] pixels;
        int width;
        int height;
        fonts.GetTexDataAsRGBA32(&pixels, &width, &height);

        AtlasPixels image;
        image.width = width;
        image.height = height;
        image.allPixelsAtOnce = pixels;

        auto pool = device.createCommandPool();
        auto buffers = pool.allocateBuffers(1);
        scope(exit)
        {
            pool.freeBuffers(buffers);
            destroy(pool);
        }

        fontImage = loadImageToMemory(device, pool, buffers[0], image, VK_FORMAT_R8G8B8A8_UNORM);
        fontView = createImageView(device, VK_FORMAT_R8G8B8A8_UNORM, fontImage.image);

        VkSamplerCreateInfo samplerInfo = {
            sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            magFilter: VK_FILTER_LINEAR,
            minFilter: VK_FILTER_LINEAR,
            mipmapMode: VK_SAMPLER_MIPMAP_MODE_LINEAR,
            addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            compareEnable: VK_FALSE,
        };
        fontSampler = VkObj!VkSampler(device.releaseQueue, samplerInfo);

        fontSet = pipelines.descriptorAllocator(technique).allocate();

        VkDescriptorImageInfo imageInfo = {
            sampler: fontSampler.vk,
            imageView: fontView.vk,
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        auto writes = [imageWriteDescriptor(fontSet, 0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, imageInfo)];
        device.updateDescriptorSets(writes);

        fonts.SetTexID(cast(ImTextureID) fontSet);
    }

    private void ensureFrame(uint frameIndex, VkImageView view, VkExtent2D extent)
    {
        if(frameBuffers.length <= frameIndex)
        {
            const oldLength = frameBuffers.length;
            frameBuffers.length = frameIndex + 1;
            frameViews.length = frameIndex + 1;
            frameExtents.length = frameIndex + 1;

            foreach(i; oldLength .. frameBuffers.length)
                frameViews[i] = VkImageView.init;
        }

        if(frameViews[frameIndex] == view
            && frameExtents[frameIndex].width == extent.width
            && frameExtents[frameIndex].height == extent.height)
            return;

        frameViews[frameIndex] = view;
        frameExtents[frameIndex] = extent;

        VkFramebufferCreateInfo info = {
            renderPass: pass.vkRenderPass,
            attachmentCount: 1,
            pAttachments: &view,
            width: extent.width,
            height: extent.height,
            layers: 1,
        };
        frameBuffers[frameIndex] = VkObj!VkFramebuffer(device.releaseQueue, info);
    }

    private void ensureBuffers(uint frameIndex, size_t vertexBytes, size_t indexBytes)
    {
        if(vertexBuffers.length <= frameIndex)
        {
            vertexBuffers.length = frameIndex + 1;
            indexBuffers.length = frameIndex + 1;
        }

        vertexBuffers[frameIndex] = grown(vertexBuffers[frameIndex], vertexBytes, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        indexBuffers[frameIndex] = grown(indexBuffers[frameIndex], indexBytes, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
    }

    private MemoryBufferMappedToCPU grown(MemoryBufferMappedToCPU buffer, size_t bytes, VkBufferUsageFlags usage)
    {
        import std.algorithm: max;

        const size = max(bytes, 1 << 16);

        if(buffer !is null && buffer.cpuBuf.length >= size)
            return buffer;

        if(buffer !is null)
            destroy(buffer);

        return device.create!MemoryBufferMappedToCPU(size, usage);
    }

    /// Converts the requested scripts and text into a zero-terminated range list
    private static ImWchar[] buildRanges(ImFontAtlas* atlas, UiScript[] scripts, string text)
    {
        struct Span
        {
            ImWchar first;
            ImWchar last;
        }

        void addPointer(const(ImWchar)* ranges, ref Span[] spans)
        {
            for(; ranges[0] != 0; ranges += 2)
                spans ~= Span(ranges[0], ranges[1]);
        }

        Span[] spans;

        foreach(script; scripts)
        {
            final switch(script)
            {
                case UiScript.latin: addPointer(atlas.GetGlyphRangesDefault(), spans); break;
                case UiScript.cyrillic: addPointer(atlas.GetGlyphRangesCyrillic(), spans); break;
                case UiScript.greek: addPointer(atlas.GetGlyphRangesGreek(), spans); break;
                case UiScript.thai: addPointer(atlas.GetGlyphRangesThai(), spans); break;
                case UiScript.vietnamese: addPointer(atlas.GetGlyphRangesVietnamese(), spans); break;
                case UiScript.japanese: addPointer(atlas.GetGlyphRangesJapanese(), spans); break;
                case UiScript.korean: addPointer(atlas.GetGlyphRangesKorean(), spans); break;
                case UiScript.chineseSimplified: addPointer(atlas.GetGlyphRangesChineseSimplifiedCommon(), spans); break;
                case UiScript.chineseFull: addPointer(atlas.GetGlyphRangesChineseFull(), spans); break;
            }
        }

        // Only the characters the UI actually shows, so a CJK font stays small
        foreach(dchar character; text)
            if(character > 0 && character <= 0xFFFF)
                spans ~= Span(cast(ImWchar) character, cast(ImWchar) character);

        // Space and the ASCII range are what ImGui's own widgets expect
        spans ~= Span(0x20, 0x7E);

        spans.sort!((a, b) => a.first < b.first);

        ImWchar[] result;

        foreach(span; spans)
        {
            if(result.length != 0 && span.first <= result[$ - 1] + 1)
            {
                if(span.last > result[$ - 1])
                    result[$ - 1] = span.last;
                continue;
            }

            result ~= span.first;
            result ~= span.last;
        }

        result ~= 0;
        return result;
    }
}

/// One-sample pass that loads the colour the scene left and stores it back
final class UiPass: RenderPass
{
    private LogicalDevice device;

    this(LogicalDevice device, VkFormat imageFormat)
    {
        this.device = device;
        this.imageFormat = imageFormat;
        samples = VK_SAMPLE_COUNT_1_BIT;

        VkAttachmentDescription color = {
            format: imageFormat,
            samples: samples,
            loadOp: VK_ATTACHMENT_LOAD_OP_LOAD,
            storeOp: VK_ATTACHMENT_STORE_OP_STORE,
            stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
            initialLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            finalLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        VkAttachmentReference colorRef = {
            attachment: 0,
            layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        VkSubpassDescription subpass = {
            pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
            colorAttachmentCount: 1,
            pColorAttachments: &colorRef,
        };

        VkSubpassDependency dependency = {
            srcSubpass: VK_SUBPASS_EXTERNAL,
            dstSubpass: 0,
            srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            srcAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            dstStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        };

        VkRenderPassCreateInfo info = {
            attachmentCount: 1,
            pAttachments: &color,
            subpassCount: 1,
            pSubpasses: &subpass,
            dependencyCount: 1,
            pDependencies: &dependency,
        };

        vkCall(device, &info, device.alloc, &vkRenderPass);
    }

    ~this()
    {
        if(vkRenderPass)
            vkDestroyRenderPass(device, vkRenderPass, device.alloc);
    }

    void record(VkCommandBuffer buf, VkFramebuffer frameBuffer, VkExtent2D extent, void delegate(ref VkCommandBuffer) draw)
    {
        VkRenderPassBeginInfo info = {
            sType: VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            renderPass: vkRenderPass,
            framebuffer: frameBuffer,
            renderArea: VkRect2D(offset: VkOffset2D(0, 0), extent: extent),
        };

        vkCmdBeginRenderPass(buf, &info, VK_SUBPASS_CONTENTS_INLINE);
        draw(buf);
        vkCmdEndRenderPass(buf);
    }
}

/// What `loadImageToMemory` needs from the font atlas pixels
private struct AtlasPixels
{
    int width;
    int height;
    void[] allPixelsAtOnce;
}
