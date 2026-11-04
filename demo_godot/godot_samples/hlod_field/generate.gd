extends SceneTree

# Builds `hlod_field.tscn`: a 10 km square of ground with villages on it.
#
# The scene is meant to measure the cell and HLOD rings. Props keep their own
# meshes, so a cell holds geometry that belongs to it, and the ground is
# subdivided to the cell size so clipping a cell keeps a surface under it.

const extent := 10000.0
const ground_tiles := 20
const ground_divisions := 8
const villages := 40
const props_per_village := 40
const seed_value := 20261104

var rng := RandomNumberGenerator.new()

func _init() -> void:
    rng.seed = seed_value

    var root := Node3D.new()
    root.name = "HlodField"

    var environment := Environment.new()
    environment.background_mode = Environment.BG_SKY
    var sky := Sky.new()
    var sky_material := ProceduralSkyMaterial.new()
    sky_material.sky_top_color = Color(0.35, 0.55, 0.85)
    sky_material.sky_horizon_color = Color(0.7, 0.78, 0.85)
    sky_material.ground_horizon_color = Color(0.5, 0.52, 0.45)
    sky_material.ground_bottom_color = Color(0.2, 0.22, 0.18)
    sky.sky_material = sky_material
    environment.sky = sky
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
    environment.ambient_light_energy = 0.6

    var world_environment := WorldEnvironment.new()
    world_environment.name = "WorldEnvironment"
    world_environment.environment = environment
    root.add_child(world_environment)
    world_environment.owner = root

    var sun := DirectionalLight3D.new()
    sun.name = "Sun"
    sun.transform = Transform3D(Basis(Vector3(1, 0, 0), deg_to_rad(-50)).rotated(Vector3(0, 1, 0), deg_to_rad(30)), Vector3(0, 60, 0))
    sun.light_energy = 1.3
    sun.shadow_enabled = true
    sun.directional_shadow_max_distance = 400.0
    root.add_child(sun)
    sun.owner = root

    var ground := Node3D.new()
    ground.name = "Ground"
    root.add_child(ground)
    ground.owner = root

    var props := Node3D.new()
    props.name = "Props"
    root.add_child(props)
    props.owner = root

    var tile_size := extent / ground_tiles
    var ground_mesh := BoxMesh.new()
    ground_mesh.size = Vector3(tile_size, 0.2, tile_size)
    ground_mesh.subdivide_width = ground_divisions
    ground_mesh.subdivide_depth = ground_divisions
    ground_mesh.material = material(Color(0.31, 0.44, 0.23), 0.95)

    for x in ground_tiles:
        for z in ground_tiles:
            var tile := MeshInstance3D.new()
            tile.name = "Tile_%d_%d" % [x, z]
            tile.mesh = ground_mesh
            tile.transform = Transform3D(Basis(), Vector3(
                -extent * 0.5 + tile_size * (x + 0.5),
                -0.1,
                -extent * 0.5 + tile_size * (z + 0.5),
            ))
            ground.add_child(tile)
            tile.owner = root

    var house_mesh := BoxMesh.new()
    house_mesh.size = Vector3(9, 6, 7)
    house_mesh.subdivide_width = 1
    house_mesh.subdivide_depth = 1
    house_mesh.material = material(Color(0.72, 0.66, 0.55), 0.85)

    var tower_mesh := CylinderMesh.new()
    tower_mesh.top_radius = 1.6
    tower_mesh.bottom_radius = 2.2
    tower_mesh.height = 16.0
    tower_mesh.radial_segments = 12
    tower_mesh.material = material(Color(0.55, 0.35, 0.3), 0.7)

    var rock_mesh := SphereMesh.new()
    rock_mesh.radius = 1.5
    rock_mesh.height = 3.0
    rock_mesh.radial_segments = 10
    rock_mesh.rings = 6
    rock_mesh.material = material(Color(0.42, 0.42, 0.45), 0.9)

    var trunk_mesh := CylinderMesh.new()
    trunk_mesh.top_radius = 0.35
    trunk_mesh.bottom_radius = 0.5
    trunk_mesh.height = 4.0
    trunk_mesh.radial_segments = 8
    trunk_mesh.material = material(Color(0.35, 0.24, 0.16), 0.9)

    var crown_mesh := SphereMesh.new()
    crown_mesh.radius = 2.6
    crown_mesh.height = 5.2
    crown_mesh.radial_segments = 10
    crown_mesh.rings = 6
    crown_mesh.material = material(Color(0.19, 0.38, 0.2), 1.0)

    var glass_mesh := BoxMesh.new()
    glass_mesh.size = Vector3(12, 4.5, 12)
    glass_mesh.material = transparent(Color(0.55, 0.75, 0.85, 0.35))

    var road_mesh := BoxMesh.new()
    road_mesh.size = Vector3(extent, 0.15, 9)
    road_mesh.subdivide_width = 160
    road_mesh.material = material(Color(0.24, 0.24, 0.26), 0.95)

    for i in villages:
        var village := Node3D.new()
        village.name = "Village_%d" % i

        var center := village_center(i)
        village.transform = Transform3D(Basis(), center)
        props.add_child(village)
        village.owner = root

        for j in props_per_village:
            add_prop(village, root, j, center, house_mesh, tower_mesh, rock_mesh, trunk_mesh, crown_mesh)

        if i % 5 == 0:
            var glass := MeshInstance3D.new()
            glass.name = "Glass"
            glass.mesh = glass_mesh
            glass.transform = Transform3D(Basis(), Vector3(rng.randf_range(-30, 30), 2.25, rng.randf_range(-30, 30)))
            village.add_child(glass)
            glass.owner = root

    var roads := Node3D.new()
    roads.name = "Roads"
    props.add_child(roads)
    roads.owner = root

    for i in 5:
        var road := MeshInstance3D.new()
        road.name = "Road_%d" % i
        road.mesh = road_mesh
        var angle := 0.0 if i % 2 == 0 else PI * 0.5
        var offset := rng.randf_range(-extent * 0.4, extent * 0.4)
        var basis := Basis(Vector3(0, 1, 0), angle)
        var center := Vector3(0, 0.05, offset) if i % 2 == 0 else Vector3(offset, 0.05, 0)
        road.transform = Transform3D(basis, center)
        roads.add_child(road)
        road.owner = root

    var packed := PackedScene.new()
    packed.pack(root)
    ResourceSaver.save(packed, "res://hlod_field.tscn")

    print("wrote hlod_field.tscn: %d nodes" % count_nodes(root))
    quit()

# Every village sits in a ring around the origin, so the spawn sees one close by
func village_center(index: int) -> Vector3:
    if index == 0:
        return Vector3(80, 0, 80)

    var radius := rng.randf_range(300.0, extent * 0.45)
    var angle := rng.randf_range(0.0, PI * 2.0)

    return Vector3(cos(angle) * radius, 0, sin(angle) * radius)

func add_prop(parent: Node3D, owner_node: Node, index: int, center: Vector3,
        house: Mesh, tower: Mesh, rock: Mesh, trunk: Mesh, crown: Mesh) -> void:
    var angle := rng.randf_range(0.0, PI * 2.0)
    var distance := sqrt(rng.randf()) * 70.0
    var spot := Vector3(cos(angle) * distance, 0, sin(angle) * distance)
    var turn := Basis(Vector3(0, 1, 0), rng.randf_range(0.0, PI * 2.0))

    var kind := index % 10

    if kind < 4:
        var house_node := MeshInstance3D.new()
        house_node.name = "House_%d" % index
        house_node.mesh = house
        house_node.transform = Transform3D(turn, spot + Vector3(0, 3, 0))
        parent.add_child(house_node)
        house_node.owner = owner_node
    elif kind < 6:
        var tower_node := MeshInstance3D.new()
        tower_node.name = "Tower_%d" % index
        tower_node.mesh = tower
        tower_node.transform = Transform3D(turn, spot + Vector3(0, 8, 0))
        parent.add_child(tower_node)
        tower_node.owner = owner_node
    elif kind < 7:
        var rock_node := MeshInstance3D.new()
        rock_node.name = "Rock_%d" % index
        rock_node.mesh = rock
        rock_node.transform = Transform3D(Basis(), spot + Vector3(0, 1, 0))
        parent.add_child(rock_node)
        rock_node.owner = owner_node
    else:
        var tree := Node3D.new()
        tree.name = "Tree_%d" % index
        tree.transform = Transform3D(turn, spot)
        parent.add_child(tree)
        tree.owner = owner_node

        var trunk_node := MeshInstance3D.new()
        trunk_node.name = "Trunk"
        trunk_node.mesh = trunk
        trunk_node.transform = Transform3D(Basis(), Vector3(0, 2, 0))
        tree.add_child(trunk_node)
        trunk_node.owner = owner_node

        var crown_node := MeshInstance3D.new()
        crown_node.name = "Crown"
        crown_node.mesh = crown
        crown_node.transform = Transform3D(Basis(), Vector3(0, 6, 0))
        tree.add_child(crown_node)
        crown_node.owner = owner_node

func material(color: Color, roughness: float) -> StandardMaterial3D:
    var result := StandardMaterial3D.new()
    result.albedo_color = color
    result.roughness = roughness
    return result

func transparent(color: Color) -> StandardMaterial3D:
    var result := material(color, 0.15)
    result.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    return result

func count_nodes(node: Node) -> int:
    var total := 1
    for child in node.get_children():
        total += count_nodes(child)
    return total
