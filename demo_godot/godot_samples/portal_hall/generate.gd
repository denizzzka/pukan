extends SceneTree

# Builds `portal_hall.tscn`: a grid of rooms whose walls carry doorways, with a
# `portal_hall.json` that tells the engine where the rooms and portals are.
#
# Every wall gap is a portal between two rooms, so the engine can walk the room
# graph and drop the rooms no visible doorway reaches.

const rooms := 6
const room_size := 16.0
const wall_thickness := 0.4
const wall_height := 4.0
const doorway_width := 3.0
const doorway_height := 2.6

func _init() -> void:
    var root := Node3D.new()
    root.name = "PortalHall"

    var wall_material := StandardMaterial3D.new()
    wall_material.albedo_color = Color(0.62, 0.6, 0.56)
    wall_material.roughness = 0.85

    var floor_material := StandardMaterial3D.new()
    floor_material.albedo_color = Color(0.34, 0.33, 0.31)
    floor_material.roughness = 0.95

    var wall := BoxMesh.new()
    wall.material = wall_material
    wall.size = Vector3(room_size, wall_height, wall_thickness)

    var post := BoxMesh.new()
    post.material = wall_material
    post.size = Vector3((room_size - doorway_width) / 2, wall_height, wall_thickness)

    var lintel := BoxMesh.new()
    lintel.material = wall_material
    lintel.size = Vector3(doorway_width, wall_height - doorway_height, wall_thickness)

    var slab := BoxMesh.new()
    slab.material = floor_material
    slab.size = Vector3(room_size, 0.2, room_size)

    for x in rooms:
        for z in rooms:
            var room := Node3D.new()
            room.name = "Room_%d_%d" % [x, z]
            room.transform = Transform3D(Basis(), Vector3(x * room_size, 0, z * room_size))
            root.add_child(room)
            room.owner = root

            var floor := MeshInstance3D.new()
            floor.name = "Floor"
            floor.mesh = slab
            floor.transform = Transform3D(Basis(), Vector3(room_size * 0.5, -0.1, room_size * 0.5))
            room.add_child(floor)
            floor.owner = root

            var ceiling := MeshInstance3D.new()
            ceiling.name = "Ceiling"
            ceiling.mesh = slab
            ceiling.transform = Transform3D(Basis(), Vector3(room_size * 0.5, wall_height + 0.1, room_size * 0.5))
            room.add_child(ceiling)
            ceiling.owner = root

            # Each shared wall belongs to the room on its far side, so a wall
            # is built once and no room culls its neighbour's only copy
            for side in 4:
                if (side == 1 and z != rooms - 1) or (side == 3 and x != rooms - 1):
                    continue

                var outer := (side == 0 and z == 0) or (side == 1 and z == rooms - 1) \
                    or (side == 2 and x == 0) or (side == 3 and x == rooms - 1)

                # Sides 0 and 1 close the room in z, 2 and 3 in x
                var centres := [
                    Vector3(room_size * 0.5, wall_height * 0.5, 0),
                    Vector3(room_size * 0.5, wall_height * 0.5, room_size),
                    Vector3(0, wall_height * 0.5, room_size * 0.5),
                    Vector3(room_size, wall_height * 0.5, room_size * 0.5),
                ]
                var turns := [0.0, 0.0, PI * 0.5, PI * 0.5]
                var turn := Basis(Vector3(0, 1, 0), turns[side])

                var wall_node := Node3D.new()
                wall_node.name = "Side_%d" % side
                wall_node.transform = Transform3D(turn, centres[side])
                room.add_child(wall_node)
                wall_node.owner = root

                if outer:
                    add_box(wall_node, root, "Wall", wall, Vector3(0, 0, 0))
                    continue

                # Two jambs and a lintel leave a doorway in the middle
                add_box(wall_node, root, "Left", post, Vector3(-(doorway_width + post.size.x) * 0.5, 0, 0))
                add_box(wall_node, root, "Right", post, Vector3((doorway_width + post.size.x) * 0.5, 0, 0))
                add_box(wall_node, root, "Lintel", lintel, Vector3(0, wall_height - lintel.size.y, 0))

    var packed := PackedScene.new()
    packed.pack(root)
    ResourceSaver.save(packed, "res://portal_hall.tscn")

    var data := {
        "rooms": rooms,
        "room_size": room_size,
        "wall_height": wall_height,
        "doorway_width": doorway_width,
        "doorway_height": doorway_height,
    }
    var file := FileAccess.open("res://portal_hall.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(data, "  "))
    file.close()

    print("wrote portal_hall.tscn and portal_hall.json")

func add_box(parent: Node3D, owner_node: Node, name: String, mesh: Mesh, at: Vector3) -> void:
    var node := MeshInstance3D.new()
    node.name = name
    node.mesh = mesh
    node.transform = Transform3D(Basis(), at)
    parent.add_child(node)
    node.owner = owner_node
