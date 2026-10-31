#!/bin/bash

TGT="--target-env=vulkan1.3"
INCLUDES="-I source/pukan/shaders"

glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/mesh_vertices.glsl -o compiled_shaders/mesh_static_vert.spv
glslc ${TGT} ${INCLUDES} -DSKINNED -fshader-stage=vertex source/pukan/shaders/mesh_vertices.glsl -o compiled_shaders/mesh_skinned_vert.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/mesh_lit.vert -o compiled_shaders/mesh_lit_vert.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/mesh_pbr.vert -o compiled_shaders/mesh_pbr_vert.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/mesh_pbr_static.vert -o compiled_shaders/mesh_pbr_static_vert.spv
glslc ${TGT} ${INCLUDES} -DSHADOW -fshader-stage=vertex source/pukan/shaders/mesh_pbr.vert -o compiled_shaders/mesh_pbr_shadow_vert.spv
glslc ${TGT} ${INCLUDES} -DSHADOW -fshader-stage=vertex source/pukan/shaders/mesh_pbr_static.vert -o compiled_shaders/mesh_pbr_static_shadow_vert.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=frag source/pukan/shaders/mesh_shadow.frag -o compiled_shaders/mesh_shadow_frag.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=frag source/pukan/shaders/mesh_shadow_mask.frag -o compiled_shaders/mesh_shadow_mask_frag.spv
glslc ${TGT} ${INCLUDES} -DGODOT_MATERIAL -fshader-stage=frag source/pukan/shaders/mesh_shadow_mask.frag -o compiled_shaders/mesh_shadow_mask_frag_godot.spv

pbr_frag() {
    local name="$1"
    shift
    glslc ${TGT} ${INCLUDES} -fshader-stage=frag "$@" source/pukan/shaders/mesh_pbr.frag -o "compiled_shaders/${name}.spv"
}

for flavor in gltf godot; do
    if [ "$flavor" = "godot" ]; then
        define="-DGODOT_MATERIAL"
        suffix="_godot"
    else
        define=""
        suffix=""
    fi

    pbr_frag "mesh_pbr_frag${suffix}" $define
    pbr_frag "mesh_pbr_frag_unlit${suffix}" $define -DUNLIT
    pbr_frag "mesh_pbr_frag_lit${suffix}" $define -DLIT
    pbr_frag "mesh_pbr_frag_analytic${suffix}" $define -DSKY_ANALYTIC
    pbr_frag "mesh_pbr_frag_nosky${suffix}" $define -DSKY_NONE
    pbr_frag "mesh_pbr_frag_core${suffix}" $define -DCORE
    pbr_frag "mesh_pbr_frag_core_analytic${suffix}" $define -DCORE -DSKY_ANALYTIC
    pbr_frag "mesh_pbr_frag_core_nosky${suffix}" $define -DCORE -DSKY_NONE
    pbr_frag "mesh_pbr_frag_oit${suffix}" $define -DOIT
    pbr_frag "mesh_pbr_frag_oit_analytic${suffix}" $define -DOIT -DSKY_ANALYTIC
    pbr_frag "mesh_pbr_frag_oit_nosky${suffix}" $define -DOIT -DSKY_NONE
    pbr_frag "mesh_pbr_frag_core_oit${suffix}" $define -DOIT -DCORE
    pbr_frag "mesh_pbr_frag_core_oit_analytic${suffix}" $define -DOIT -DCORE -DSKY_ANALYTIC
    pbr_frag "mesh_pbr_frag_core_oit_nosky${suffix}" $define -DOIT -DCORE -DSKY_NONE
    pbr_frag "mesh_pbr_frag_lit_oit${suffix}" $define -DLIT -DOIT
    pbr_frag "mesh_pbr_frag_unlit_oit${suffix}" $define -DUNLIT -DOIT
done

glslc ${TGT} ${INCLUDES} -fshader-stage=vertex source/pukan/shaders/fullscreen.vert -o compiled_shaders/fullscreen_vert.spv
glslc ${TGT} ${INCLUDES} -DOIT_READ_ONLY -fshader-stage=frag source/pukan/shaders/oit_resolve.frag -o compiled_shaders/oit_resolve_frag.spv
glslc ${TGT} ${INCLUDES} -fshader-stage=frag source/pukan/shaders/depth_resolve.frag -o compiled_shaders/depth_resolve_frag.spv
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
