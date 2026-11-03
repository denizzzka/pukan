module pukan.graphics.g3d.scene_tree;

import pukan.graphics.g3d.tree.drawable_tree: DrawableTree;
import pukan.graphics.g3d.primitives_tree: Bone;
import pukan.vulkan.renderpass: DrawableByVulkan;
import std.variant: Algebraic;

alias Payload = Algebraic!(
    Bone,
    DrawableByVulkan,
);

alias SceneTree = DrawableTree!Payload;
