#!/bin/bash

TGT="--target-env=vulkan1.2"

glslc ${TGT} -fshader-stage=vertex source/pukan/shaders/vertices.glsl -o compiled_shaders/vert.spv
glslc ${TGT} -fshader-stage=vertex source/pukan/shaders/gltf_vertices.glsl -o compiled_shaders/gltf_vertices.spv

glslc ${TGT} -fshader-stage=frag source/pukan/shaders/colored_fragment.glsl -o compiled_shaders/colored_frag.spv
glslc ${TGT} -fshader-stage=frag source/pukan/shaders/textured_fragment.glsl -o compiled_shaders/textured_frag.spv
glslc ${TGT} -fshader-stage=frag source/pukan/shaders/gltf_fragment.glsl -o compiled_shaders/gltf_fragment.spv
