#!/bin/bash

TGT="--target-env=vulkan1.2"

glslc ${TGT} -fshader-stage=vertex source/pukan/shaders/vertices.glsl -o vert.spv
glslc ${TGT} -fshader-stage=vertex source/pukan/shaders/gltf_vertices.glsl -o gltf_vertices.spv

glslc ${TGT} -fshader-stage=frag source/pukan/shaders/colored_fragment.glsl -o colored_frag.spv
glslc ${TGT} -fshader-stage=frag source/pukan/shaders/textured_fragment.glsl -o textured_frag.spv
glslc ${TGT} -fshader-stage=frag source/pukan/shaders/gltf_fragment.glsl -o gltf_fragment.spv
