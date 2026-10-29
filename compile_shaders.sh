#!/bin/bash

TGT="--target-env=vulkan1.3"
INCLUDES="-I source/pukan/shaders"

glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/mesh_vertices.glsl -o compiled_shaders/mesh_static_vert.spv
glslc ${TGT} ${INCLUDES} -DSKINNED -fshader-stage=vertex source/pukan/shaders/mesh_vertices.glsl -o compiled_shaders/mesh_skinned_vert.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/mesh_lit.vert -o compiled_shaders/mesh_lit_vert.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/mesh_pbr.vert -o compiled_shaders/mesh_pbr_vert.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/mesh_pbr_static.vert -o compiled_shaders/mesh_pbr_static_vert.spv

glslc ${TGT} ${INCLUDES} -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag.spv
glslc ${TGT} ${INCLUDES} -DUNLIT -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_unlit.spv
glslc ${TGT} ${INCLUDES} -DLIT -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_lit.spv
glslc ${TGT} ${INCLUDES} -DSKY_ANALYTIC -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_analytic.spv
glslc ${TGT} ${INCLUDES} -DSKY_NONE -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_nosky.spv
glslc ${TGT} ${INCLUDES} -DCORE -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_core.spv
glslc ${TGT} ${INCLUDES} -DCORE -DSKY_ANALYTIC -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_core_analytic.spv
glslc ${TGT} ${INCLUDES} -DCORE -DSKY_NONE -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_core_nosky.spv
glslc ${TGT} ${INCLUDES} -DOIT -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_oit.spv
glslc ${TGT} ${INCLUDES} -DOIT -DSKY_ANALYTIC -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_oit_analytic.spv
glslc ${TGT} ${INCLUDES} -DOIT -DSKY_NONE -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_oit_nosky.spv
glslc ${TGT} ${INCLUDES} -DOIT -DCORE -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_core_oit.spv
glslc ${TGT} ${INCLUDES} -DOIT -DCORE -DSKY_ANALYTIC -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_core_oit_analytic.spv
glslc ${TGT} ${INCLUDES} -DOIT -DCORE -DSKY_NONE -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_core_oit_nosky.spv
glslc ${TGT} ${INCLUDES} -DLIT -DOIT -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_lit_oit.spv
glslc ${TGT} ${INCLUDES} -DUNLIT -DOIT -fshader-stage=frag source/pukan/shaders/mesh_pbr.frag -o compiled_shaders/mesh_pbr_frag_unlit_oit.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/fullscreen.vert -o compiled_shaders/fullscreen_vert.spv
glslc ${TGT} ${INCLUDES} -DOIT_READ_ONLY -fshader-stage=frag source/pukan/shaders/oit_resolve.frag -o compiled_shaders/oit_resolve_frag.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=frag source/pukan/shaders/mesh_fragment.glsl -o compiled_shaders/mesh_frag.spv
glslc ${TGT} ${INCLUDES} -DHAS_NORMAL -fshader-stage=frag source/pukan/shaders/mesh_fragment.glsl -o compiled_shaders/mesh_lit_frag.spv
glslc ${TGT} -fshader-stage=vertex source/pukan/shaders/line.vert -o compiled_shaders/line_vert.spv
glslc ${TGT} -fshader-stage=frag source/pukan/shaders/line.frag -o compiled_shaders/line_frag.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/sphere.vert -o compiled_shaders/sphere_vert.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=frag source/pukan/shaders/sphere.frag -o compiled_shaders/sphere_frag.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/icosphere.comp -o compiled_shaders/icosphere.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/sphere_classify.comp -o compiled_shaders/sphere_classify.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/sphere_scan.comp -o compiled_shaders/sphere_scan.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/sphere_scatter.comp -o compiled_shaders/sphere_scatter.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/cylinder.vert -o compiled_shaders/cylinder_vert.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=frag source/pukan/shaders/cylinder.frag -o compiled_shaders/cylinder_frag.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/cylinder_mesh.comp -o compiled_shaders/cylinder_mesh.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/cylinder_classify.comp -o compiled_shaders/cylinder_classify.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/cylinder_scan.comp -o compiled_shaders/cylinder_scan.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/cylinder_scatter.comp -o compiled_shaders/cylinder_scatter.spv
glslc ${TGT} -fshader-stage=vertex source/pukan/shaders/checkerboard.vert -o compiled_shaders/checkerboard_vert.spv
glslc ${TGT} -fshader-stage=frag source/pukan/shaders/checkerboard.frag -o compiled_shaders/checkerboard_frag.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/gemm.comp -o compiled_shaders/gemm.spv
glslc ${TGT} -fshader-stage=compute source/pukan/shaders/skin_matrices.comp -o compiled_shaders/skin_matrices.spv
