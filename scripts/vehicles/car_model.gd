class_name CarModel
extends RefCounted
## Vehicle visuals from assets/models/cars.glb (built in Blender by tools/blender/make_cars.py):
## per kind one body mesh (lofted shell with door seams, cut wheel arches, glass, cabin lining,
## seats, dash and steering wheel, lights and trim) plus police/SWAT light-bar halves, and one
## shared alloy wheel. Body surfaces are matched by material name:
##   Paint - per-car StandardMaterial3D (vertex colour darkens seams / rocker)
##   Glass - shared tinted glass, Decal - police door lettering
##   Parts - the shared car_parts shader (vertex colour, UV2 rough/metal, emission class in
##           COLOR.a; the tail-light brightness is a per-car instance uniform)
## Seat hip positions come from cars.json so seated people line up with each interior.
## Vehicle needs: body_node, paint_mat, body_mi (brake uniform), bar_red/bar_blue, wheels.

static var shared := {}
static var meshes := {}          # "sedan_body", "police_bar_red", "wheel" ... -> Mesh
static var paint_surf := {}      # kind -> surface index of the paint
static var meta := {}            # cars.json

static func _shared() -> void:
	if not shared.is_empty():
		return
	var g := StandardMaterial3D.new()
	g.albedo_color = Color(0.06, 0.08, 0.1, 0.78)
	g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	g.roughness = 0.04
	g.metallic = 0.7
	g.specular = 0.7
	shared.glass = g
	var dec := StandardMaterial3D.new()
	dec.albedo_texture = load("res://assets/textures/police_decal.png")
	dec.roughness = 0.35
	dec.metallic = 0.3
	shared.decal = dec
	var pm := ShaderMaterial.new()
	pm.shader = load("res://assets/shaders/car_parts.gdshader")
	shared.parts = pm
	var f := FileAccess.open("res://assets/models/cars.json", FileAccess.READ)
	if f:
		meta = JSON.parse_string(f.get_as_text())
	var root: Node = (load("res://assets/models/cars.glb") as PackedScene).instantiate()
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m: Mesh = mi.mesh
		var nm := String(mi.name)
		meshes[nm] = m
		for i in m.get_surface_count():
			var mat: Material = m.surface_get_material(i)
			var mn := mat.resource_name if mat else "Parts"
			if mn.begins_with("Paint"):
				paint_surf[nm.trim_suffix("_body")] = i
				m.surface_set_material(i, null)
			elif mn.begins_with("Glass"):
				m.surface_set_material(i, shared.glass)
			elif mn.begins_with("Decal"):
				m.surface_set_material(i, shared.decal)
			else:
				m.surface_set_material(i, pm)
	root.free()

static func build(v: Vehicle) -> void:
	_shared()
	var kind: String = v.kind
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
	elif kind == "swat":
		col = Color("1b2a44")
	paint.albedo_color = col
	paint.vertex_color_use_as_albedo = true
	paint.metallic = 0.45
	paint.roughness = 0.32
	paint.clearcoat_enabled = true
	paint.clearcoat = 1.0
	paint.clearcoat_roughness = 0.06
	v.paint_mat = paint
	var mi := MeshInstance3D.new()
	mi.mesh = meshes.get(kind + "_body", meshes.get("sedan_body"))
	mi.set_surface_override_material(int(paint_surf.get(kind, paint_surf.get("sedan", 0))), paint)
	body.add_child(mi)
	v.body_mi = mi
	for nm in ["bar_red", "bar_blue"]:
		if not meshes.has(kind + "_" + nm):
			continue
		var bar := MeshInstance3D.new()
		bar.mesh = meshes[kind + "_" + nm]
		bar.material_override = Mats.solid(Color("ff2030") if nm == "bar_red" else Color("2050ff"), 0.25, 0.0, 0.3)
		body.add_child(bar)
		v.set(nm, bar)
	var info: Dictionary = meta.get(kind, {})
	if info.has("seats"):
		var seats := []
		for s in info.seats:
			seats.append(Vector3(s[0], s[1], s[2]))
		v.seats = seats
		v.occupants.resize(seats.size())
		v.recline = float(info.get("recline", 0.0))
	# wheels: FL, FR, RL, RR (front = +z, left = +x)
	var wz: float = v.spec.wb / 2.0
	for wp in [[1.0, 1.0], [-1.0, 1.0], [1.0, -1.0], [-1.0, -1.0]]:
		var piv := Node3D.new()
		piv.position = Vector3(wp[0] * (W / 2 - 0.13), Vehicle.WHEEL_R, wp[1] * wz)
		var spin := MeshInstance3D.new()
		spin.mesh = meshes.wheel
		piv.add_child(spin)
		v.add_child(piv)
		v.wheels.append({"mount": Vector3(wp[0] * (W / 2 - 0.13), 0, wp[1] * wz), "front": wp[1] > 0, "pivot": piv, "spin": spin, "comp": 0.0, "prev_comp": 0.0, "grounded": false, "len": Vehicle.REST})
