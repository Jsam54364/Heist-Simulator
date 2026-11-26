class_name CarModel
extends RefCounted
## Procedural car bodies built from side-profile extrusions (placeholder art).
## Replace with .glb models later: Vehicle only needs `wheels` (pivot/spin
## nodes + mount points), `paint_mat`, `body_mi` (tail lights via instance uniform) and optional siren bars.

const PROFILES := {
	"sedan": {"body": [[-2.3, 0.32], [2.3, 0.32], [2.3, 0.78], [2.12, 0.93], [0.98, 1.0], [-1.6, 1.02], [-2.24, 0.96], [-2.3, 0.78]], "cab": [[0.95, 0.98], [0.12, 1.42], [-1.0, 1.44], [-1.62, 1.0]], "roof": [-1.0, 0.12, 1.43]},
	"coupe": {"body": [[-2.2, 0.28], [2.2, 0.28], [2.2, 0.62], [2.05, 0.76], [0.7, 0.85], [-1.6, 0.88], [-2.16, 0.82], [-2.2, 0.62]], "cab": [[0.66, 0.84], [-0.18, 1.2], [-0.92, 1.22], [-1.78, 0.86]], "roof": [-0.9, -0.18, 1.21]},
	"suv": {"body": [[-2.4, 0.42], [2.4, 0.42], [2.4, 1.0], [2.24, 1.15], [1.3, 1.22], [-2.4, 1.25]], "cab": [[1.26, 1.2], [0.58, 1.78], [-2.3, 1.8], [-2.38, 1.22]], "roof": [-2.3, 0.58, 1.79]},
	"pickup": {"body": [[-2.6, 0.42], [2.6, 0.42], [2.6, 1.0], [2.45, 1.15], [1.4, 1.2], [-2.6, 1.2]], "cab": [[1.36, 1.18], [0.76, 1.74], [-0.42, 1.75], [-0.46, 1.2]], "roof": [-0.42, 0.76, 1.745]},
}

static var shared := {}
static var wheel_mesh: ArrayMesh

static func _shared() -> void:
	if not shared.is_empty():
		return
	shared.trim = Mats.solid(Color("1b1d20"), 0.6)
	shared.black = Mats.solid(Color("121417"), 0.5)
	var g := StandardMaterial3D.new()
	g.albedo_color = Color(0.08, 0.11, 0.14, 0.85)
	g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	g.roughness = 0.05
	g.metallic = 0.6
	shared.glass = g
	shared.chrome = Mats.solid(Color("c9ccd0"), 0.15, 1.0)
	shared.plate = Mats.solid(Color("f4f4f4"), 0.5)
	shared.head = Mats.solid(Color("fff4d6"), 0.2, 0.0, 2.5)
	shared.taxi = Mats.solid(Color("fff1a8"), 0.3, 0.0, 1.5)
	var dec := StandardMaterial3D.new()
	dec.albedo_texture = load("res://assets/textures/police_decal.png")
	dec.roughness = 0.4
	shared.decal = dec
	shared.tire = Mats.solid(Color("141414"), 0.9)
	shared.hub = Mats.solid(Color("b9bdc2"), 0.25, 0.9)
	var pm := ShaderMaterial.new()
	pm.shader = load("res://assets/shaders/car_parts.gdshader")
	shared.parts = pm
	# wheel: tyre + hub merged into ONE surface (vertex colours), axle along X; every
	# car's wheels share mesh + material
	wheel_mesh = ArrayMesh.new()
	var wv := PackedVector3Array()
	var wn := PackedVector3Array()
	var wc := PackedColorArray()
	var wu2 := PackedVector2Array()
	var wi := PackedInt32Array()
	var tire := CylinderMesh.new()
	tire.top_radius = Vehicle.WHEEL_R
	tire.bottom_radius = Vehicle.WHEEL_R
	tire.height = 0.26
	tire.radial_segments = 16
	var hub := CylinderMesh.new()
	hub.top_radius = 0.2
	hub.bottom_radius = 0.2
	hub.height = 0.28
	hub.radial_segments = 10
	for part in [[tire, Color("141414"), Vector2(0.9, 0.0)], [hub, Color("b9bdc2"), Vector2(0.25, 0.9)]]:
		var arr: Array = part[0].get_mesh_arrays()
		var rot := Basis(Vector3.BACK, PI / 2)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var ns: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var ids: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var base := wv.size()
		for i in vs.size():
			wv.append(rot * vs[i])
			wn.append(rot * ns[i])
			var c: Color = part[1]
			c.a = 0.0
			wc.append(c)
			wu2.append(part[2])
		for i in ids:
			wi.append(base + i)
	var warr := []
	warr.resize(Mesh.ARRAY_MAX)
	warr[Mesh.ARRAY_VERTEX] = wv
	warr[Mesh.ARRAY_NORMAL] = wn
	warr[Mesh.ARRAY_COLOR] = wc
	warr[Mesh.ARRAY_TEX_UV2] = wu2
	warr[Mesh.ARRAY_INDEX] = wi
	wheel_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, warr)
	wheel_mesh.surface_set_material(0, pm)

class Parts:
	## small parts merged into one "parts" surface: colour, roughness, metal, emission class
	const MERGE := {"trim": [Color("1b1d20"), 0.6, 0.0, 0.0], "black": [Color("121417"), 0.5, 0.0, 0.0],
		"chrome": [Color("c9ccd0"), 0.15, 1.0, 0.0], "plate": [Color("f4f4f4"), 0.5, 0.0, 0.0],
		"head": [Color("fff4d6"), 0.2, 0.0, 0.5], "tail": [Color("b01010"), 0.3, 0.0, 1.0],
		"taxi": [Color("fff1a8"), 0.3, 0.0, 0.5], "stripe": [Color("d4ac0d"), 0.4, 0.0, 0.0]}
	var sts := {}
	func st(key: String) -> SurfaceTool:
		if MERGE.has(key):
			key = "parts"
		if not sts.has(key):
			var s := SurfaceTool.new()
			s.begin(Mesh.PRIMITIVE_TRIANGLES)
			sts[key] = s
		return sts[key]
	func tri(key: String, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
		var s := st(key)
		if (b - a).cross(c - a).dot(n) > 0.0:
			var t := b
			b = c
			c = t
		var m = MERGE.get(key)
		for p in [a, b, c]:
			s.set_normal(n)
			if m != null:
				var col: Color = m[0]
				col.a = m[3]
				s.set_color(col)
				s.set_uv2(Vector2(m[1], m[2]))
			s.add_vertex(p)
	func box(key: String, size: Vector3, c: Vector3) -> void:
		var hs := size * 0.5
		for f in MeshBuilder.FACES:
			var nn: Vector3 = f[0]
			var r: Vector3 = f[1]
			var up: Vector3 = f[2]
			var q := [(nn - r + up) * hs + c, (nn + r + up) * hs + c, (nn + r - up) * hs + c, (nn - r - up) * hs + c]
			tri(key, q[0], q[1], q[2], nn)
			tri(key, q[0], q[2], q[3], nn)
	## side profile [z, y] extruded across the car width
	func extrude(key: String, pts: Array, width: float) -> void:
		var poly := PackedVector2Array()
		for p in pts:
			poly.append(Vector2(p[0], p[1]))
		var idx := Geometry2D.triangulate_polygon(poly)
		var hw := width * 0.5
		for side in [-1.0, 1.0]:
			var n := Vector3(side, 0, 0)
			for k in range(0, idx.size(), 3):
				var a := poly[idx[k]]
				var b := poly[idx[k + 1]]
				var c := poly[idx[k + 2]]
				tri(key, Vector3(side * hw, a.y, a.x), Vector3(side * hw, b.y, b.x), Vector3(side * hw, c.y, c.x), n)
		var ccw := 0.0
		for i in poly.size():
			var p0 := poly[i]
			var p1 := poly[(i + 1) % poly.size()]
			ccw += (p1.x - p0.x) * (p1.y + p0.y)
		var sgn := -1.0 if ccw > 0.0 else 1.0
		for i in poly.size():
			var p0 := poly[i]
			var p1 := poly[(i + 1) % poly.size()]
			var e := p1 - p0
			var n := Vector3(0, -e.x, e.y).normalized() * sgn
			var a := Vector3(-hw, p0.y, p0.x)
			var b := Vector3(hw, p0.y, p0.x)
			var c := Vector3(hw, p1.y, p1.x)
			var d := Vector3(-hw, p1.y, p1.x)
			tri(key, a, b, c, n)
			tri(key, a, c, d, n)
	func commit(mats: Dictionary) -> ArrayMesh:
		var mesh := ArrayMesh.new()
		for key in sts:
			var s: SurfaceTool = sts[key]
			s.commit(mesh)
			mesh.surface_set_material(mesh.get_surface_count() - 1, mats[key])
		return mesh

static func build(v: Vehicle) -> void:
	_shared()
	var kind: String = v.kind
	var L: float = v.L
	var W: float = v.W
	var body := Node3D.new()
	body.name = "Body"
	v.add_child(body)
	v.body_node = body
	var paint := StandardMaterial3D.new()
	var col: Color = Game.CAR_COLORS[v.color_idx]
	if kind == "police":
		col = Color("f4f4f4")
	elif kind == "truck":
		col = Color("4d5a4a")
	paint.albedo_color = col
	paint.metallic = 0.55
	paint.roughness = 0.3
	paint.clearcoat_enabled = true
	paint.clearcoat = 1.0
	paint.clearcoat_roughness = 0.08
	v.paint_mat = paint
	var mats := {"paint": paint, "glass": shared.glass, "decal": shared.decal, "parts": shared.parts}
	var P := Parts.new()
	var light_y := 0.7
	if kind == "truck":
		P.box("paint", Vector3(W, 1.0, L), Vector3(0, 0.95, 0))
		P.box("paint", Vector3(W, 1.8, 4.2), Vector3(0, 2.25, -1.0))
		P.box("glass", Vector3(W - 0.1, 1.2, 1.6), Vector3(0, 1.95, 2.1))
		P.box("stripe", Vector3(W + 0.02, 0.25, 4.2), Vector3(0, 2.7, -1.0))
		P.box("trim", Vector3(1.2, 1.4, 0.06), Vector3(0, 2.1, -3.12))
		light_y = 0.95
	else:
		var pr: Dictionary = PROFILES.get(kind, PROFILES.sedan)
		if kind == "police":
			pr = {"body": PROFILES.sedan.body.map(func(p): return [p[0] * 1.04, p[1]]), "cab": PROFILES.sedan.cab.map(func(p): return [p[0] * 1.04, p[1]]), "roof": [-1.04, 0.12, 1.43]}
		P.extrude("paint", pr.body, W)
		P.extrude("glass", pr.cab, W - 0.16)
		var r0: float = pr.roof[0]
		var r1: float = pr.roof[1]
		var ry: float = pr.roof[2]
		P.box("paint", Vector3(W - 0.18, 0.06, r1 - r0), Vector3(0, ry, (r0 + r1) / 2))
		P.box("trim", Vector3(W + 0.04, 0.2, 0.18), Vector3(0, 0.42, L / 2 + 0.02))
		P.box("trim", Vector3(W + 0.04, 0.2, 0.18), Vector3(0, 0.42, -L / 2 - 0.02))
		P.box("black", Vector3(W * 0.45, 0.16, 0.05), Vector3(0, 0.64, L / 2 + 0.03))
		P.box("plate", Vector3(0.5, 0.14, 0.03), Vector3(0, 0.55, -L / 2 - 0.12))
		var cab_front: float = pr.cab[0][0]
		for sx in [-1.0, 1.0]:
			P.box("paint", Vector3(0.16, 0.12, 0.22), Vector3(sx * (W / 2 + 0.06), pr.cab[0][1] + 0.05, cab_front - 0.1))
		light_y = (pr.body[2][1] + pr.body[1][1]) / 2.0 + 0.12
		if kind == "pickup":
			P.box("black", Vector3(W - 0.1, 0.05, 2.0), Vector3(0, 1.21, -1.55))
			for sx in [-1.0, 1.0]:
				P.box("paint", Vector3(0.08, 0.35, 2.05), Vector3(sx * (W / 2 - 0.04), 1.37, -1.55))
			P.box("paint", Vector3(W, 0.35, 0.08), Vector3(0, 1.37, -2.56))
		if kind == "taxi":
			P.box("taxi", Vector3(0.8, 0.22, 0.32), Vector3(0, ry + 0.14, -0.4))
			P.box("black", Vector3(W + 0.01, 0.12, 2.4), Vector3(0, 0.75, 0))
		if kind == "police":
			P.box("black", Vector3(W + 0.015, 0.36, 1.25), Vector3(0, 0.6, 1.55))
			P.box("black", Vector3(W + 0.015, 0.36, 1.0), Vector3(0, 0.6, -1.85))
			P.box("trim", Vector3(1.5, 0.06, 0.34), Vector3(0, ry + 0.03, -0.45))
			P.box("black", Vector3(W + 0.1, 0.5, 0.12), Vector3(0, 0.6, L / 2 + 0.12))
			for sx in [-1.0, 1.0]:
				var x: float = sx * (W / 2 + 0.03)
				var n := Vector3(sx, 0, 0)
				var a := Vector3(x, 0.86, -0.9)
				var b := Vector3(x, 0.86, 0.7)
				var c := Vector3(x, 0.46, 0.7)
				var d := Vector3(x, 0.46, -0.9)
				var s := P.st("decal")
				var pts := [b, a, d, c] if sx > 0 else [a, b, c, d]
				var uv2 := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
				for tri_i in [[0, 1, 2], [0, 2, 3]]:
					var p0: Vector3 = pts[tri_i[0]]
					var p1: Vector3 = pts[tri_i[1]]
					var p2: Vector3 = pts[tri_i[2]]
					var order = tri_i
					if (p1 - p0).cross(p2 - p0).dot(n) > 0.0:
						order = [tri_i[0], tri_i[2], tri_i[1]]
					for k in order:
						s.set_normal(n)
						s.set_uv(uv2[k])
						s.add_vertex(pts[k])
			for sx in [-1.0, 1.0]:
				var bar := MeshInstance3D.new()
				var bm := BoxMesh.new()
				bm.size = Vector3(0.6, 0.16, 0.3)
				bar.mesh = bm
				bar.material_override = Mats.solid(Color("ff2030") if sx < 0 else Color("2050ff"), 0.3, 0.0, 0.3)
				bar.position = Vector3(sx * 0.36, ry + 0.1, -0.45)
				body.add_child(bar)
				if sx < 0:
					v.bar_red = bar
				else:
					v.bar_blue = bar
	for sx in [-1.0, 1.0]:
		P.box("head", Vector3(0.42, 0.14, 0.06), Vector3(sx * (W / 2 - 0.33), light_y, L / 2 + 0.01))
		P.box("tail", Vector3(0.4, 0.14, 0.06), Vector3(sx * (W / 2 - 0.3), light_y, -L / 2 - 0.01))
	var mi := MeshInstance3D.new()
	mi.mesh = P.commit(mats)
	body.add_child(mi)
	v.body_mi = mi
	# wheels: FL, FR, RL, RR
	var wz: float = v.spec.wb / 2.0
	for wp in [[1.0, 1.0], [-1.0, 1.0], [1.0, -1.0], [-1.0, -1.0]]:
		var piv := Node3D.new()
		piv.position = Vector3(wp[0] * (W / 2 - 0.13), Vehicle.WHEEL_R, wp[1] * wz)
		var spin := MeshInstance3D.new()
		spin.mesh = wheel_mesh
		piv.add_child(spin)
		v.add_child(piv)
		v.wheels.append({"mount": Vector3(wp[0] * (W / 2 - 0.13), 0, wp[1] * wz), "front": wp[1] > 0, "pivot": piv, "spin": spin, "comp": 0.0, "prev_comp": 0.0, "grounded": false, "len": Vehicle.REST})
