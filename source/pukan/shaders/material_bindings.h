// Bindings of the glTF material descriptor set, shared by GLSL and importC.
// TODO: replace with SPIR-V reflection once it exists; this list is manual.
// Keep the values ascending: the material textures are written in this order.
#define MATERIAL_UNIFORM 0
#define MATERIAL_BASE_COLOR 1
#define MATERIAL_JOINTS 2
#define MATERIAL_METALLIC_ROUGHNESS 3
#define MATERIAL_NORMAL 4
#define MATERIAL_OCCLUSION 5
#define MATERIAL_EMISSIVE 6
#define MATERIAL_SPECULAR 7
#define MATERIAL_SPECULAR_COLOR 8
#define MATERIAL_CLEARCOAT 9
#define MATERIAL_CLEARCOAT_ROUGHNESS 10
#define MATERIAL_CLEARCOAT_NORMAL 11
#define MATERIAL_SHEEN_COLOR 12
#define MATERIAL_SHEEN_ROUGHNESS 13
#define MATERIAL_ANISOTROPY 14
#define MATERIAL_IRIDESCENCE 15
#define MATERIAL_IRIDESCENCE_THICKNESS 16
#define MATERIAL_TRANSMISSION 17
