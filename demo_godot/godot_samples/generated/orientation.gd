extends SceneTree

# Builds orientation.tscn: a labelled cube whose faces name their own axis.
# Each label is readable when the face is viewed from outside with its up axis.

const HALF := 1.0

const FACES := [
	{"name": "Front", "normal": Vector3(0, 0, 1), "up": Vector3(0, 1, 0), "texture": "res://orientation_front.ctex"},
	{"name": "Back", "normal": Vector3(0, 0, -1), "up": Vector3(0, 1, 0), "texture": "res://orientation_back.ctex"},
	{"name": "Right", "normal": Vector3(1, 0, 0), "up": Vector3(0, 1, 0), "texture": "res://orientation_right.ctex"},
	{"name": "Left", "normal": Vector3(-1, 0, 0), "up": Vector3(0, 1, 0), "texture": "res://orientation_left.ctex"},
	{"name": "Top", "normal": Vector3(0, 1, 0), "up": Vector3(0, 0, 1), "texture": "res://orientation_top.ctex"},
	{"name": "Bottom", "normal": Vector3(0, -1, 0), "up": Vector3(0, 0, -1), "texture": "res://orientation_bottom.ctex"},
]


func _init() -> void:
	var root := Node3D.new()
	root.name = "Orientation"

	for face in FACES:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.albedo_texture = load(face["texture"])

		var plane := PlaneMesh.new()
		plane.size = Vector2(HALF * 2.0, HALF * 2.0)

		var normal: Vector3 = face["normal"]
		var up: Vector3 = face["up"]
		var z := -up
		var x := normal.cross(z).normalized()

		var instance := MeshInstance3D.new()
		instance.name = face["name"]
		instance.mesh = plane
		instance.material_override = material
		instance.transform = Transform3D(Basis(x, normal, z), normal * HALF)
		root.add_child(instance)
		instance.owner = root

	var packed := PackedScene.new()
	packed.pack(root)
	print("saved: ", ResourceSaver.save(packed, "res://orientation.tscn"))
	quit()
