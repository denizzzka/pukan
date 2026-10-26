#!/bin/bash

TGT="--target-env=vulkan1.3"

glslc ${TGT} -fshader-stage=vertex source/pukan/shaders/vertices.glsl -o compiled_shaders/vert.spv
glslc ${TGT} -fshader-stage=vertex source/pukan/shaders/gltf_vertices.glsl -o compiled_shaders/gltf_vertices.spv

glslc ${TGT} -fshader-stage=frag source/pukan/shaders/colored_fragment.glsl -o compiled_shaders/colored_frag.spv
glslc ${TGT} -fshader-stage=frag source/pukan/shaders/textured_fragment.glsl -o compiled_shaders/textured_frag.spv
glslc ${TGT} -fshader-stage=frag source/pukan/shaders/gltf_fragment.glsl -o compiled_shaders/gltf_fragment.spv
glslc ${TGT} -fshader-stage=vertex source/pukan/shaders/sphere.vert -o compiled_shaders/sphere_vert.spv
glslc ${TGT} -fshader-stage=frag source/pukan/shaders/sphere.frag -o compiled_shaders/sphere_frag.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/icosphere.comp -o compiled_shaders/icosphere.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/sphere_classify.comp -o compiled_shaders/sphere_classify.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/sphere_scan.comp -o compiled_shaders/sphere_scan.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/sphere_scatter.comp -o compiled_shaders/sphere_scatter.spv
glslc ${TGT} -fshader-stage=vertex source/pukan/shaders/cylinder.vert -o compiled_shaders/cylinder_vert.spv
glslc ${TGT} -fshader-stage=frag source/pukan/shaders/cylinder.frag -o compiled_shaders/cylinder_frag.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/cylinder_mesh.comp -o compiled_shaders/cylinder_mesh.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/cylinder_classify.comp -o compiled_shaders/cylinder_classify.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/cylinder_scan.comp -o compiled_shaders/cylinder_scan.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/cylinder_scatter.comp -o compiled_shaders/cylinder_scatter.spv
glslc ${TGT} -fshader-stage=vertex source/pukan/shaders/checkerboard.vert -o compiled_shaders/checkerboard_vert.spv
glslc ${TGT} -fshader-stage=frag source/pukan/shaders/checkerboard.frag -o compiled_shaders/checkerboard_frag.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/gemm.comp -o compiled_shaders/gemm.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/skin_matrices.comp -o compiled_shaders/skin_matrices.spv
