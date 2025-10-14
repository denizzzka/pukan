#!/bin/bash

glslc -fshader-stage=vertex source/pukan/shaders/vertices.glsl -o vert.spv
glslc -fshader-stage=vertex source/pukan/shaders/gltf_vertices.glsl -o gltf_vertices.spv

glslc -fshader-stage=frag source/pukan/shaders/colored_fragment.glsl -o colored_frag.spv
glslc -fshader-stage=frag source/pukan/shaders/textured_fragment.glsl -o textured_frag.spv
