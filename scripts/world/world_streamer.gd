class_name WorldStreamer
extends Node3D
## LOD world loading. The city is cut into 50 m chunks (one block each). Around the
## camera, chunk layers are turned into GPU meshes on demand, a few per frame, and freed
## again when you move away (with hysteresis so nothing flickers at the edge):
##
##   detail    benches, signs, AC units, shop products ...   ~45 m
##   interior  rooms of enterable shops/bank                   ~65 m
##   main      full-detail buildings, streets, sidewalks       ~95 m
##   mid       palms, lamp posts, poles                        ~130 m
##   far       HLOD: one textured box per building + flat ground, one draw call per
##             chunk, always resident, shown wherever `main` isn't loaded
##
## Radii scale with the graphics preset (Settings -> lod_scale). Buildings also become
## occluders, so blocks hidden behind other blocks aren't drawn at all.
## Pattern: chunked visibility-range HLOD as recommended in Godot's "Visibility ranges
## (HLOD)" and "Occlusion culling" docs, streamed with a per-frame time budget.

const BASE_RADII := {"detail": 45.0, "interior": 65.0, "main": 95.0, "mid": 130.0}
const HYST := 20.0
const LAYER_BITS := {"main": 1, "mid": 1, "detail": 1, "interior": 2}

var B: MeshBuilder
var cells := {}                 # Vector2i -> {rect, far, layers: {name: {nodes: [], loaded, queued}}}
var queue: Array = []           # [ck, layer, dist]
var far_mat: ShaderMaterial
var lod_scale := 1.0
var budget_usec := 2500         # time allowed per frame for building chunk meshes
var eval_t := 0.0
var stats := {"loaded": 0, "far": 0, "queued": 0, "built_ms": 0.0}
var occluder: OccluderInstance3D

func setup(builder: MeshBuilder) -> void:
	B = builder
	far_mat = ShaderMaterial.new()
	far_mat.shader = load("res://assets/shaders/far_city.gdshader")
	far_mat.set_shader_parameter("atlas", load("res://assets/textures/far_atlas.png"))
	var keys := {}
	for ck in B.chunks:
		keys[ck] = true
	var far_by := _far_geometry()
	for ck in far_by:
		keys[ck] = true
	for ck in keys:
		var cell := {"rect": MeshBuilder.chunk_rect(ck), "far": null, "layers": {}}
		for l in MeshBuilder.LAYERS:
			cell.layers[l] = {"nodes": [], "loaded": false, "queued": false, "empty": not _has_layer(ck, l)}
		if far_by.has(ck):
			var mi := MeshInstance3D.new()
			mi.name = "Far_%d_%d" % [ck.x, ck.y]
			mi.mesh = far_by[ck]
			mi.material_override = far_mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi)
			cell.far = mi
		cells[ck] = cell
	_build_occluders()

func _has_layer(ck: Vector2i, layer: String) -> bool:
	if not B.chunks.has(ck):
		return false
	for key in B.chunks[ck].parts:
		var p: Dictionary = B.chunks[ck].parts[key]
		if p.layer == layer and not p.v.is_empty():
			return true
	return false

## Load everything around a point immediately (spawn / respawn / teleport) so the first
## frame has no pop-in.
func prime(at: Vector3) -> void:
	_evaluate(at)
	var t := Time.get_ticks_usec()
	while not queue.is_empty():
		var q: Array = queue.pop_front()
		_load(q[0], q[1])
	stats.built_ms = (Time.get_ticks_usec() - t) / 1000.0

func _process(dt: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	eval_t -= dt
	if eval_t <= 0.0:
		eval_t = 0.15
		_evaluate(cam.global_position)
	var t0 := Time.get_ticks_usec()
	while not queue.is_empty() and Time.get_ticks_usec() - t0 < budget_usec:
		var q: Array = queue.pop_front()
		_load(q[0], q[1])

static func _dist(p: Vector3, r: Rect2) -> float:
	var dx := maxf(maxf(r.position.x - p.x, 0.0), p.x - r.end.x)
	var dz := maxf(maxf(r.position.y - p.z, 0.0), p.z - r.end.y)
	return sqrt(dx * dx + dz * dz)

func _evaluate(cam: Vector3) -> void:
	queue.clear()
	var loaded := 0
	var far_n := 0
	for ck in cells:
		var cell: Dictionary = cells[ck]
		var d := _dist(cam, cell.rect)
		for l in MeshBuilder.LAYERS:
			var L: Dictionary = cell.layers[l]
			L.queued = false
			if L.empty:
				continue
			var r: float = BASE_RADII[l] * lod_scale
			if not L.loaded and d < r:
				L.queued = true
				# nearest first; full-detail shells before small props
				queue.append([ck, l, d + (0.0 if l == "main" else 5.0)])
			elif L.loaded and d > r + HYST:
				_unload(L)
			if L.loaded:
				loaded += 1
		if cell.far:
			cell.far.visible = not cell.layers.main.loaded
			if cell.far.visible:
				far_n += 1
	queue.sort_custom(func(a, b): return a[2] < b[2])
	stats.loaded = loaded
	stats.far = far_n
	stats.queued = queue.size()

func _load(ck: Vector2i, layer: String) -> void:
	var L: Dictionary = cells[ck].layers[layer]
	if L.loaded:
		return
	var surfs := B.layer_surfaces(ck, layer)
	if not surfs.is_empty():
		var mesh := ArrayMesh.new()
		for s in surfs:
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, s.mat)
		var mi := MeshInstance3D.new()
		mi.name = "%s_%d_%d" % [layer, ck.x, ck.y]
		mi.mesh = mesh
		mi.layers = LAYER_BITS[layer]
		# small props don't cast shadows (cheaper shadow pass, invisible difference)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if layer == "detail" else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(mi)
		L.nodes.append(mi)
	L.loaded = true
	L.queued = false
	var cell: Dictionary = cells[ck]
	if layer == "main" and cell.far:
		cell.far.visible = false

func _unload(L: Dictionary) -> void:
	for n in L.nodes:
		n.queue_free()
	L.nodes.clear()
	L.loaded = false

func layer_loaded(p: Vector3, layer: String) -> bool:
	var ck := MeshBuilder.chunk_of(p)
	return cells.has(ck) and cells[ck].layers[layer].loaded

# ---------- far HLOD ----------
func _far_geometry() -> Dictionary:
	var acc := {}  # ck -> [v, n, uv, uv2, c, i]
	var add_box := func(minv: Vector3, maxv: Vector3, side_cell: int, color: Color, gf: float):
		var ck := MeshBuilder.chunk_of((minv + maxv) * 0.5)
		if not acc.has(ck):
			acc[ck] = [PackedVector3Array(), PackedVector3Array(), PackedVector2Array(), PackedVector2Array(), PackedColorArray(), PackedInt32Array()]
		var a: Array = acc[ck]
		var size := maxv - minv
		var bands := []
		if gf > 0.0 and size.y > gf + 1.0:
			bands = [[minv.y, minv.y + gf, 4, Color(0.92, 0.92, 0.92)], [minv.y + gf, maxv.y, side_cell, color]]
		else:
			bands = [[minv.y, maxv.y, side_cell, color]]
		for bi in bands.size():
			var y0: float = bands[bi][0]
			var y1: float = bands[bi][1]
			var top := bi == bands.size() - 1
			_far_box(a, Vector3(minv.x, y0, minv.z), Vector3(maxv.x, y1, maxv.z), bands[bi][2], bands[bi][3], top)
	for fb in B.far_boxes:
		add_box.call(fb.min, fb.max, fb.cell, fb.color, fb.ground_floor)
	for g in B.far_ground:
		var r: Rect2 = g.rect
		# ground pieces can be long (whole streets): cut them per chunk
		var xs := B._cuts(r.position.x, r.end.x)
		var zs := B._cuts(r.position.y, r.end.y)
		for i in xs.size() - 1:
			for j in zs.size() - 1:
				var mn := Vector3(xs[i], g.y, zs[j])
				var mx := Vector3(xs[i + 1], g.y, zs[j + 1])
				var ck := MeshBuilder.chunk_of((mn + mx) * 0.5)
				if not acc.has(ck):
					acc[ck] = [PackedVector3Array(), PackedVector3Array(), PackedVector2Array(), PackedVector2Array(), PackedColorArray(), PackedInt32Array()]
				_far_quad_up(acc[ck], mn, mx, g.color)
	var out := {}
	for ck in acc:
		var a: Array = acc[ck]
		if a[0].is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = a[0]
		arrays[Mesh.ARRAY_NORMAL] = a[1]
		arrays[Mesh.ARRAY_TEX_UV] = a[2]
		arrays[Mesh.ARRAY_TEX_UV2] = a[3]
		arrays[Mesh.ARRAY_COLOR] = a[4]
		arrays[Mesh.ARRAY_INDEX] = a[5]
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out[ck] = m
	return out

func _far_box(a: Array, mn: Vector3, mx: Vector3, cell: int, color: Color, with_top: bool) -> void:
	var size := mx - mn
	var faces := [
		[Vector3(1, 0, 0), Vector3(mx.x, mn.y, mx.z), Vector3(0, 0, -1), size.z],
		[Vector3(-1, 0, 0), Vector3(mn.x, mn.y, mn.z), Vector3(0, 0, 1), size.z],
		[Vector3(0, 0, 1), Vector3(mn.x, mn.y, mx.z), Vector3(1, 0, 0), size.x],
		[Vector3(0, 0, -1), Vector3(mx.x, mn.y, mn.z), Vector3(-1, 0, 0), size.x],
	]
	var tile_u := 4.0
	var tile_v := 3.4 if cell != 4 else size.y
	for f in faces:
		var n: Vector3 = f[0]
		var o: Vector3 = f[1]
		var r: Vector3 = f[2]
		var w: float = f[3]
		var base: int = a[0].size()
		var tu := w / tile_u
		var tv := size.y / tile_v
		a[0].append(o + Vector3(0, size.y, 0)); a[0].append(o + r * w + Vector3(0, size.y, 0))
		a[0].append(o + r * w); a[0].append(o)
		a[2].append(Vector2(0, 0)); a[2].append(Vector2(tu, 0)); a[2].append(Vector2(tu, tv)); a[2].append(Vector2(0, tv))
		for k in 4:
			a[1].append(n)
			a[3].append(Vector2(cell, 0))
			a[4].append(color)
		a[5].append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	if with_top:
		var base: int = a[0].size()
		a[0].append(Vector3(mn.x, mx.y, mn.z)); a[0].append(Vector3(mx.x, mx.y, mn.z))
		a[0].append(Vector3(mx.x, mx.y, mx.z)); a[0].append(Vector3(mn.x, mx.y, mx.z))
		a[2].append(Vector2(0, 0)); a[2].append(Vector2(size.x / 6.0, 0)); a[2].append(Vector2(size.x / 6.0, size.z / 6.0)); a[2].append(Vector2(0, size.z / 6.0))
		for k in 4:
			a[1].append(Vector3.UP)
			a[3].append(Vector2(5, 0))
			a[4].append(Color(0.75, 0.74, 0.72))
		a[5].append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

func _far_quad_up(a: Array, mn: Vector3, mx: Vector3, color: Color) -> void:
	var base: int = a[0].size()
	a[0].append(Vector3(mn.x, mn.y, mn.z)); a[0].append(Vector3(mx.x, mn.y, mn.z))
	a[0].append(Vector3(mx.x, mn.y, mx.z)); a[0].append(Vector3(mn.x, mn.y, mx.z))
	for k in 4:
		a[1].append(Vector3.UP)
		a[2].append(Vector2.ZERO)
		a[3].append(Vector2(-1, 0))
		a[4].append(color)
	a[5].append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

# ---------- occlusion ----------
func _build_occluders() -> void:
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for o in B.occluders:
		var mn: Vector3 = o.min
		var mx: Vector3 = o.max
		var b := verts.size()
		for y in [mn.y, mx.y]:
			verts.append(Vector3(mn.x, y, mn.z)); verts.append(Vector3(mx.x, y, mn.z))
			verts.append(Vector3(mx.x, y, mx.z)); verts.append(Vector3(mn.x, y, mx.z))
		# 4 sides + top (bottom never visible)
		for q in [[0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7], [4, 5, 6, 7]]:
			idx.append_array(PackedInt32Array([b + q[0], b + q[1], b + q[2], b + q[0], b + q[2], b + q[3]]))
	if verts.is_empty():
		return
	var ao := ArrayOccluder3D.new()
	ao.set_arrays(verts, idx)
	occluder = OccluderInstance3D.new()
	occluder.name = "CityOccluders"
	occluder.occluder = ao
	add_child(occluder)
