class_name CharModel
extends RefCounted
## Builds the blocky placeholder humanoid (merged, vertex-coloured boxes).
## Swap for a rigged .glb + AnimationTree later; Character only needs
## `inner`, `arm_l`, `arm_r`, `gun`, `mask` nodes from here.

static var mat: StandardMaterial3D
static var mask_mat: StandardMaterial3D
static var gun_mat: StandardMaterial3D

const SKIN := [Color("c68e6a"), Color("e0b08f"), Color("8d5a3b"), Color("f1c9a5"), Color("6b4229")]
const HAIR := [Color("1b130d"), Color("3b2615"), Color("6b4a2a"), Color("c9a26b"), Color("111111"), Color("8a8a8a")]

static func _mats() -> void:
	if mat:
		return
	mat = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.8
	mask_mat = Mats.solid(Color("111111"), 0.9)
	gun_mat = Mats.solid(Color("0b0b0b"), 0.35, 0.7)

## parts: Array of [size: Vector3, center: Vector3, color: Color, tag]
static func merged(parts: Array) -> Dictionary:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ranges := {}
	var count := 0
	for p in parts:
		var size: Vector3 = p[0]
		var c: Vector3 = p[1]
		var colr: Color = p[2]
		var tag: String = p[3] if p.size() > 3 else ""
		var hs := size * 0.5
		for f in MeshBuilder.FACES:
			var nn: Vector3 = f[0]
			var r: Vector3 = f[1]
			var up: Vector3 = f[2]
			var q := [(nn - r + up) * hs + c, (nn + r + up) * hs + c, (nn + r - up) * hs + c, (nn - r - up) * hs + c]
			for k in [0, 1, 2, 0, 2, 3]:
				st.set_color(colr)
				st.set_normal(nn)
				st.add_vertex(q[k])
		if tag != "":
			if not ranges.has(tag):
				ranges[tag] = []
			ranges[tag].append([count, 36])
		count += 36
	return {"mesh": st.commit(), "ranges": ranges}

static func build(owner: Node3D, role: String, color: Color, leg: Color, skin: Color) -> Dictionary:
	_mats()
	var inner := Node3D.new()
	inner.name = "Model"
	owner.add_child(inner)
	var parts := [
		[Vector3(0.46, 0.85, 0.26), Vector3(0, 0.425, 0), leg],
		[Vector3(0.56, 0.66, 0.32), Vector3(0, 1.18, 0), color, "outfit"],
		[Vector3(0.28, 0.3, 0.28), Vector3(0, 1.68, 0), skin],
		[Vector3(0.2, 0.05, 0.03), Vector3(0, 1.72, 0.145), Color("111111")],
		[Vector3(0.18, 0.1, 0.32), Vector3(-0.12, 0.05, 0.04), Color("1a1a1a")],
		[Vector3(0.18, 0.1, 0.32), Vector3(0.12, 0.05, 0.04), Color("1a1a1a")],
		[Vector3(0.58, 0.07, 0.33), Vector3(0, 0.86, 0), Color("1a1a1a")],
	]
	if role in ["cop", "guard", "truckguard"]:
		parts.append([Vector3(0.32, 0.1, 0.36), Vector3(0, 1.86, 0.02), Color("0d1530") if role == "cop" else Color("111111")])
	else:
		parts.append([Vector3(0.3, 0.1, 0.3), Vector3(0, 1.86, -0.01), HAIR[randi() % HAIR.size()]])
	if role == "cop":
		parts.append([Vector3(0.12, 0.12, 0.02), Vector3(0.14, 1.32, 0.17), Color("ffd54a")])
	var body := merged(parts)
	var bm := MeshInstance3D.new()
	bm.mesh = body.mesh
	bm.material_override = mat
	inner.add_child(bm)
	var mask := MeshInstance3D.new()
	var mb := BoxMesh.new()
	mb.size = Vector3(0.3, 0.15, 0.3)
	mask.mesh = mb
	mask.material_override = mask_mat
	mask.position.y = 1.61
	mask.visible = false
	inner.add_child(mask)
	var arms := []
	var arm_meshes := []
	for side in [1.0, -1.0]:
		var piv := Node3D.new()
		piv.position = Vector3(side * 0.36, 1.46, 0)
		var a := merged([[Vector3(0.15, 0.62, 0.15), Vector3(0, -0.3, 0), color, "outfit"], [Vector3(0.12, 0.12, 0.12), Vector3(0, -0.66, 0), skin]])
		var am := MeshInstance3D.new()
		am.mesh = a.mesh
		am.material_override = mat
		am.set_meta("ranges", a.ranges)
		piv.add_child(am)
		inner.add_child(piv)
		arms.append(piv)
		arm_meshes.append(am)
	var gun := MeshInstance3D.new()
	var gb := BoxMesh.new()
	gb.size = Vector3(0.07, 0.12, 0.32)
	gun.mesh = gb
	gun.material_override = gun_mat
	gun.position = Vector3(0, -0.62, 0.12)
	gun.visible = false
	arms[1].add_child(gun)
	return {"inner": inner, "body": bm, "ranges": body.ranges, "arm_l": arms[0], "arm_r": arms[1], "arm_meshes": arm_meshes, "gun": gun, "mask": mask}

## Recolour the outfit vertices (used when the player changes clothes)
static func recolor(mi: MeshInstance3D, ranges: Dictionary, color: Color) -> void:
	if not ranges.has("outfit"):
		return
	var arr := mi.mesh.surface_get_arrays(0)
	var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR]
	for rg in ranges.outfit:
		for i in range(rg[0], rg[0] + rg[1]):
			cols[i] = color
	arr[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mi.mesh = m
