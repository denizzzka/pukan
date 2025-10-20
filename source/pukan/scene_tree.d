module pukan.scene_tree;

import pukan.tree.drawable_tree: DrawableTree;
import pukan.primitives_tree: Bone;
import pukan.vulkan.renderpass: DrawableByVulkan;
import std.variant: Algebraic;

alias Payload = Algebraic!(
    Bone,
    DrawableByVulkan,
);

alias SceneTree = DrawableTree!Payload;
