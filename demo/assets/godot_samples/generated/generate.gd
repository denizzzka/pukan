extends SceneTree

func _init() -> void:
    var mesh := ArrayMesh.new()

    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
        Vector3(-1, 0, -1), Vector3(1, 0, -1),
        Vector3(-1, 0, 1), Vector3(1, 0, 1),
    ])
    arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
        Vector3(0, 1, 0), Vector3(0, 1, 0), Vector3(0, 1, 0), Vector3(0, 1, 0),
    ])
    arrays[Mesh.ARRAY_TANGENT] = PackedFloat32Array([
        1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1,
    ])
    arrays[Mesh.ARRAY_COLOR] = PackedColorArray([
        Color(1, 0, 0, 1), Color(0, 1, 0, 1), Color(0, 0, 1, 1), Color(1, 1, 1, 1),
    ])
    arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
        Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1),
    ])
    arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 1, 2, 3])
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

    var plain := []
    plain.resize(Mesh.ARRAY_MAX)
    plain[Mesh.ARRAY_VERTEX] = PackedVector3Array([
        Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
    ])
    plain[Mesh.ARRAY_NORMAL] = PackedVector3Array([
        Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1),
    ])
    plain[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
        Vector2(0, 0), Vector2(1, 0), Vector2(0, 1),
    ])
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, plain)

    var material := StandardMaterial3D.new()
    material.albedo_color = Color(1, 1, 1, 1)
    material.albedo_texture = load("res://checker.png")
    material.vertex_color_use_as_albedo = true
    mesh.surface_set_material(0, material)

    var plain_material := StandardMaterial3D.new()
    plain_material.albedo_color = Color(0.8, 0.8, 0.8, 1)
    mesh.surface_set_material(1, plain_material)

    var root := Node3D.new()
    root.name = "Root"
    var instance := MeshInstance3D.new()
    instance.name = "Procedural"
    instance.mesh = mesh
    instance.transform = Transform3D(Basis(Vector3(0, 1, 0), deg_to_rad(30)), Vector3(0, 1, 0))
    root.add_child(instance)
    instance.owner = root

    var packed := PackedScene.new()
    packed.pack(root)
    ResourceSaver.save(packed, "res://procedural.tscn")
    ResourceSaver.save(packed, "res://procedural.scn")
    ResourceSaver.save(mesh, "res://procedural_mesh.res")
    ResourceSaver.save(mesh, "res://procedural_mesh.tres")
    ResourceSaver.save(material, "res://procedural_material.tres")
    quit()
