class_name MeshBuilder
extends RefCounted
## Collects the city's static geometry into streamable chunks and creates the box
## colliders. Nothing is turned into GPU meshes here: WorldStreamer builds chunk meshes
## on demand (and frees them again) depending on how far the camera is.
##
## Chunks are 50 m squares aligned to the road grid (roads every 50 m), so one chunk is
## one city block plus half of the surrounding streets - ideal for occlusion culling.
## Each chunk holds several LOD layers:
##   main      building shells, sidewalks, road segments, big structures   (near range)
##   interior  rooms of enterable sites (own visual layer, lit by room lights)
##   mid       tall thin things that read from far away: palms, poles, pilasters
##   detail    small props: benches, signs, AC units, trims, shop products
## plus a records list (`far_boxes`, `far_ground`) used to build the far HLOD mesh.

const CHUNK := 50.0
const LAYERS := ["main", "interior", "mid", "detail"]
const MID_MATS := ["leaf", "trunk", "lamp_glow"]

var chunks := {}               # Vector2i -> {"parts": {key: part}, "verts": int}
var cols: Array = []           # every collider record (kept for site/global colliders)
var cols_by_chunk := {}        # Vector2i -> [collider records] (navigation rasterises these)
var bodies := {}               # Vector2i -> {"world": StaticBody3D, "glass": .., "ground": .., "shore": ..}
var parent_node: Node3D        # null = detached builder used on a worker thread
var pending_cols: Array = []   # detached mode: collider specs to create on the main thread
var force_chunk = null         # Vector2i: put everything into this chunk (lot-anchored generation)
var far_boxes: Array = []      # {min: Vector3, max: Vector3, cell: int, color: Color, ground_floor: float}
var far_ground: Array = []     # {rect: Rect2, y: float, color: Color}
var occluders: Array = []      # {min: Vector3, max: Vector3}
var interior_rects: Array = [] # Rect2 (xz) of enterable rooms, ground floor only

const FACES := [
	# normal, right (u+), up (v-)
	[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)],
	[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
	[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)],
	[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
	[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
	[Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
]

func _init(parent: Node3D = null) -> void:
	parent_node = parent

const BODY_LAYERS := {"world": 1, "glass": 2, "ground": 16, "shore": 32}

## One StaticBody3D per chunk and collision layer, so a chunk's colliders can be added
## and freed as a unit (one big body with thousands of shapes would rebuild constantly).
func _chunk_body(ck: Vector2i, layer: String) -> StaticBody3D:
	if not bodies.has(ck):
		bodies[ck] = {}
	var bd: Dictionary = bodies[ck]
	if not bd.has(layer):
		var b := StaticBody3D.new()
		b.name = "Col_%s_%d_%d" % [layer, ck.x, ck.y]
		b.collision_layer = BODY_LAYERS[layer]
		b.collision_mask = 0
		parent_node.add_child(b)
		bd[layer] = b
	return bd[layer]

static func chunk_of(p: Vector3) -> Vector2i:
	return Vector2i(int(floor(p.x / CHUNK)), int(floor(p.z / CHUNK)))

static func chunk_rect(ck: Vector2i) -> Rect2:
	return Rect2(ck.x * CHUNK, ck.y * CHUNK, CHUNK, CHUNK)

## Materials in CityLayers.INDEX all share one part per (chunk, layer, shadow) drawn with
## the merged city_uber material; the per-vertex UV2.x says which texture layer to use.
var cur_uber := -1.0

func _part(mat: Material, shadow: bool, layer: String, at: Vector3) -> Dictionary:
	var ck: Vector2i = force_chunk if force_chunk != null else chunk_of(at)
	if not chunks.has(ck):
		chunks[ck] = {"parts": {}, "verts": 0}
	var parts: Dictionary = chunks[ck].parts
	var mn := str(mat.resource_name)
	var uber := CityLayers.INDEX.has(mn)
	cur_uber = float(CityLayers.INDEX[mn]) if uber else -1.0
	var draw_mat: Material = Mats.uber() if uber else mat
	# one part per (layer, material): splitting by shadow flag doubled the instance count;
	# whether a layer casts shadows is decided per layer by WorldStreamer
	var key := "%s|%d" % [layer, draw_mat.get_instance_id()]
	if not parts.has(key):
		parts[key] = {"mat": draw_mat, "shadow": shadow, "layer": layer, "uber": uber, "v": PackedVector3Array(), "n": PackedVector3Array(),
			"t": PackedFloat32Array(), "uv": PackedVector2Array(), "uv2": PackedVector2Array(), "c": PackedColorArray(), "i": PackedInt32Array()}
	return parts[key]

func _fill_uv2(s: Dictionary) -> void:
	if not s.uber:
		return
	var u2: PackedVector2Array = s.uv2
	s.uv2 = PackedVector2Array()
	var want: int = s.v.size()
	var l := Vector2(cur_uber, 0)
	while u2.size() < want:
		u2.append(l)
	s.uv2 = u2

## Take a part's arrays out of its dictionary (so appends don't copy), then put them back.
func _take(s: Dictionary) -> Array:
	var a := [s.v, s.n, s.uv, s.c, s.i, s.t]
	s.v = PackedVector3Array(); s.n = PackedVector3Array(); s.uv = PackedVector2Array(); s.c = PackedColorArray(); s.i = PackedInt32Array(); s.t = PackedFloat32Array()
	return a

func _put(s: Dictionary, a: Array) -> void:
	s.v = a[0]; s.n = a[1]; s.uv = a[2]; s.c = a[3]; s.i = a[4]; s.t = a[5]

func _in_interior(p: Vector3, w := 0.0, d := 0.0) -> bool:
	if p.y > 4.0:
		return false
	var fp := Rect2(p.x - w * 0.5, p.z - d * 0.5, w, d)
	for r in interior_rects:
		if r.grow(0.4).encloses(fp):
			return true
	return false

func _classify(mat: Material, center: Vector3, w: float, h: float, d: float, opts: Dictionary) -> String:
	var lod: String = opts.get("lod", "")
	if lod != "":
		return lod
	if _in_interior(center, w, d):
		return "interior"
	if str(mat.resource_name) in MID_MATS:
		return "mid"
	if opts.get("layer", "") == "ground":
		return "main"
	var foot := maxf(w, d)
	if maxf(foot, h) < 2.6:
		return "detail"
	if foot < 1.2 and h >= 2.6:
		return "mid"
	return "main"

## Box with base at y. opts: color, tile (Vector2 metres per texture repeat), basis (rotation),
## collide (bool, default true), layer ("world"|"glass"|"ground"), shadow (bool), tag, lod
func box(cx: float, y: float, cz: float, w: float, h: float, d: float, mat: Material, opts := {}) -> Dictionary:
	var basis: Basis = opts.get("basis", Basis.IDENTITY)
	var res := {}
	if opts.get("collide", true):
		res = add_col(Vector3(cx - w * 0.5, y, cz - d * 0.5), Vector3(cx + w * 0.5, y + h, cz + d * 0.5), opts)
	# long axis-aligned boxes (roads, lines, beach strips) are split at chunk borders so
	# every chunk mesh stays compact for culling and streaming
	if basis == Basis.IDENTITY and (w > CHUNK * 0.6 or d > CHUNK * 0.6):
		var xs := _cuts(cx - w * 0.5, cx + w * 0.5)
		var zs := _cuts(cz - d * 0.5, cz + d * 0.5)
		if xs.size() > 2 or zs.size() > 2:
			for i in xs.size() - 1:
				for j in zs.size() - 1:
					_box_geom((xs[i] + xs[i + 1]) * 0.5, y, (zs[j] + zs[j + 1]) * 0.5, xs[i + 1] - xs[i], h, zs[j + 1] - zs[j], mat, opts, basis)
			_record_far_ground(cx, y, cz, w, h, d, mat, opts)
			return res
	_box_geom(cx, y, cz, w, h, d, mat, opts, basis)
	_record_far_ground(cx, y, cz, w, h, d, mat, opts)
	return res

func _cuts(a: float, b: float) -> Array:
	var out := [a]
	var k := floorf(a / CHUNK) + 1.0
	while k * CHUNK < b - 0.01:
		out.append(k * CHUNK)
		k += 1.0
	out.append(b)
	return out

func _box_geom(cx: float, y: float, cz: float, w: float, h: float, d: float, mat: Material, opts: Dictionary, basis: Basis) -> void:
	var tile: Vector2 = opts.get("tile", Mats.tile_of(mat))
	var col: Color = opts.get("color", Color.WHITE)
	var center := Vector3(cx, y + h * 0.5, cz)
	var hs := Vector3(w * 0.5, h * 0.5, d * 0.5)
	var layer := _classify(mat, center, w, h, d, opts)
	var s := _part(mat, opts.get("shadow", true), layer, center)
	var a := _take(s)
	var v: PackedVector3Array = a[0]
	var n: PackedVector3Array = a[1]
	var uv: PackedVector2Array = a[2]
	var c: PackedColorArray = a[3]
	var idx: PackedInt32Array = a[4]
	var tg: PackedFloat32Array = a[5]
	# boxes resting on the ground never show their underside, and paper-thin boxes
	# (road markings, floor finishes) only need their top face
	var skip_bottom := basis == Basis.IDENTITY and y <= 0.2
	var top_only := basis == Basis.IDENTITY and h <= 0.05 and y <= 0.3
	for fi in 6:
		if (fi == 3 and skip_bottom) or (top_only and fi != 2):
			continue
		var f: Array = FACES[fi]
		var nn: Vector3 = f[0]
		var r: Vector3 = f[1]
		var up: Vector3 = f[2]
		var fw := absf(r.x) * w + absf(r.y) * h + absf(r.z) * d
		var fh := absf(up.x) * w + absf(up.y) * h + absf(up.z) * d
		var top_face := absf(nn.y) > 0.5
		var tu := fw / tile.x
		var tv := fh / (tile.x if top_face else tile.y)
		var base := v.size()
		var wn := basis * nn
		var wt := basis * r
		v.append(basis * ((nn - r + up) * hs) + center)
		v.append(basis * ((nn + r + up) * hs) + center)
		v.append(basis * ((nn + r - up) * hs) + center)
		v.append(basis * ((nn - r - up) * hs) + center)
		for k in 4:
			n.append(wn)
			c.append(col)
			tg.append(wt.x); tg.append(wt.y); tg.append(wt.z); tg.append(1.0)
		uv.append(Vector2(0, 0)); uv.append(Vector2(tu, 0)); uv.append(Vector2(tu, tv)); uv.append(Vector2(0, tv))
		idx.append(base); idx.append(base + 1); idx.append(base + 2)
		idx.append(base); idx.append(base + 2); idx.append(base + 3)
	_put(s, [v, n, uv, c, idx, tg])
	_fill_uv2(s)

## Flat ground pieces (roads, sidewalks, sand, grass) feed the far HLOD ground.
const GROUND_MATS := {"asphalt": Color(0.2, 0.2, 0.21), "sidewalk": Color(0.55, 0.55, 0.54), "sand": Color(0.78, 0.7, 0.55),
	"grass": Color(0.27, 0.42, 0.2), "wood_planks": Color(0.45, 0.33, 0.22), "concrete": Color(0.5, 0.5, 0.48), "checker_floor": Color(0.6, 0.6, 0.6)}
func _record_far_ground(cx: float, y: float, cz: float, w: float, h: float, d: float, mat: Material, opts: Dictionary) -> void:
	var mn := str(mat.resource_name)
	if h > 0.3 or w < 3.0 or d < 3.0 or not GROUND_MATS.has(mn) or opts.has("basis"):
		return
	if _in_interior(Vector3(cx, y, cz), w, d):
		return
	var col: Color = GROUND_MATS[mn] * opts.get("color", Color.WHITE)
	far_ground.append({"rect": Rect2(cx - w * 0.5, cz - d * 0.5, w, d), "y": y + h, "color": col})

## Single textured quad facing yaw (outward normal = U.fwd(yaw)); uv rect in 0..1
func quad(center: Vector3, w: float, h: float, yaw: float, mat: Material, uv0: Vector2, uv1: Vector2, opts := {}) -> void:
	var s := _part(mat, opts.get("shadow", false), opts.get("lod", "detail"), center)
	var a := _take(s)
	var nn := U.fwd(yaw)
	var r := Vector3(nn.z, 0, -nn.x)
	var up := Vector3.UP
	var base: int = a[0].size()
	var col: Color = opts.get("color", Color.WHITE)
	a[0].append(center - r * w * 0.5 + up * h * 0.5)
	a[0].append(center + r * w * 0.5 + up * h * 0.5)
	a[0].append(center + r * w * 0.5 - up * h * 0.5)
	a[0].append(center - r * w * 0.5 - up * h * 0.5)
	for k in 4:
		a[1].append(nn)
		a[3].append(col)
		a[5].append(r.x); a[5].append(r.y); a[5].append(r.z); a[5].append(1.0)
	a[2].append(uv0); a[2].append(Vector2(uv1.x, uv0.y)); a[2].append(uv1); a[2].append(Vector2(uv0.x, uv1.y))
	a[4].append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	_put(s, a)
	_fill_uv2(s)

## Vertical cylinder (or cone when r_top = 0) with base at y
func cylinder(cx: float, y: float, cz: float, r: float, h: float, mat: Material, color := Color.WHITE, seg := 10, r_top := -1.0, opts := {}) -> void:
	if r_top < 0.0:
		r_top = r
	var lod: String = opts.get("lod", "")
	if lod == "" and _in_interior(Vector3(cx, y + h * 0.5, cz), r * 2.0, r * 2.0):
		lod = "interior"
	if lod == "":
		lod = "mid" if (str(mat.resource_name) in MID_MATS or (r < 0.6 and h >= 2.6)) else ("detail" if h < 2.6 and r < 1.5 else "main")
	var s := _part(mat, opts.get("shadow", true), lod, Vector3(cx, y, cz))
	var a := _take(s)
	var base: int = a[0].size()
	var slope := (r - r_top) / h
	for k in seg + 1:
		var ang := TAU * k / seg
		var dx := cos(ang)
		var dz := sin(ang)
		var nn := Vector3(dx, slope, dz).normalized()
		for top in 2:
			var rr := r_top if top else r
			a[0].append(Vector3(cx + dx * rr, y + (h if top else 0.0), cz + dz * rr))
			a[1].append(nn)
			a[2].append(Vector2(float(k) / seg, 0.0 if top else 1.0))
			a[3].append(color)
			a[5].append(-dz); a[5].append(0.0); a[5].append(dx); a[5].append(-1.0)
	for k in seg:
		var a0 := base + k * 2
		a[4].append_array(PackedInt32Array([a0, a0 + 2, a0 + 1, a0 + 1, a0 + 2, a0 + 3]))
	if r_top > 0.0:
		var cidx: int = a[0].size()
		for k in seg + 2:
			var p := Vector3(cx, y + h, cz)
			if k > 0:
				var ang := TAU * (k - 1) / seg
				p += Vector3(cos(ang) * r_top, 0, sin(ang) * r_top)
			a[0].append(p); a[1].append(Vector3.UP); a[2].append(Vector2(0.5, 0.5)); a[3].append(color)
			a[5].append(1.0); a[5].append(0.0); a[5].append(0.0); a[5].append(1.0)
		for k in seg:
			a[4].append_array(PackedInt32Array([cidx, cidx + 1 + k, cidx + 2 + k]))
	_put(s, a)
	_fill_uv2(s)

func add_col(minv: Vector3, maxv: Vector3, opts := {}) -> Dictionary:
	var layer: String = opts.get("layer", "world")
	var colinfo := {"min": minv, "max": maxv, "glass": layer == "glass", "solid": opts.get("solid", true), "tag": opts.get("tag", ""),
		"ground": layer == "ground", "shore": layer == "shore"}
	if parent_node == null:
		pending_cols.append({"min": minv, "max": maxv, "opts": opts})
		return colinfo
	var ck: Vector2i = force_chunk if force_chunk != null else chunk_of((minv + maxv) * 0.5)
	if force_chunk == null:
		cols.append(colinfo)   # hand-built (site) colliders; generated ones live per chunk only
	if not cols_by_chunk.has(ck):
		cols_by_chunk[ck] = []
	cols_by_chunk[ck].append(colinfo)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = (maxv - minv).max(Vector3(0.02, 0.02, 0.02))
	cs.shape = bs
	cs.position = (minv + maxv) * 0.5
	_chunk_body(ck, layer).add_child(cs)
	colinfo["shape"] = cs
	colinfo["chunk"] = ck
	return colinfo

## Bring a worker-thread builder's chunk into this (main) builder: geometry is appended to
## the chunk's parts, collider specs become real shapes.
func merge_chunk(src: MeshBuilder, ck: Vector2i) -> void:
	if src.chunks.has(ck):
		if not chunks.has(ck):
			chunks[ck] = {"parts": {}, "verts": 0}
		var dst: Dictionary = chunks[ck].parts
		for key in src.chunks[ck].parts:
			var p: Dictionary = src.chunks[ck].parts[key]
			if not dst.has(key):
				dst[key] = p
				continue
			var d: Dictionary = dst[key]
			var base: int = d.v.size()
			var idx: PackedInt32Array = p.i
			for k in idx.size():
				idx[k] += base
			d.v.append_array(p.v)
			d.n.append_array(p.n)
			d.t.append_array(p.t)
			d.uv.append_array(p.uv)
			d.uv2.append_array(p.uv2)
			d.c.append_array(p.c)
			d.i.append_array(idx)
	var keep = force_chunk
	force_chunk = ck
	for pc in src.pending_cols:
		add_col(pc.min, pc.max, pc.opts)
	force_chunk = keep

## Free a generated chunk's geometry data and colliders (it can be regenerated later).
func unload_chunk(ck: Vector2i) -> void:
	chunks.erase(ck)
	if bodies.has(ck):
		for l in bodies[ck]:
			bodies[ck][l].queue_free()
		bodies.erase(ck)
	cols_by_chunk.erase(ck)

## Far-LOD + occluder record for a building volume (called by the city/site generators).
## cell: index into far_atlas.png (0 stucco, 1 brick, 2 office, 3 glass, 4 shopfront, 5 roof)
func building_volume(minv: Vector3, maxv: Vector3, cell: int, color: Color, ground_floor := 0.0, occlude_from := 0.0) -> void:
	far_boxes.append({"min": minv, "max": maxv, "cell": cell, "color": color, "ground_floor": ground_floor})
	if occlude_from < maxv.y - 2.0:
		occluders.append({"min": Vector3(minv.x + 0.3, maxf(minv.y, occlude_from), minv.z + 0.3), "max": Vector3(maxv.x - 0.3, maxv.y - 0.2, maxv.z - 0.3)})

## Packs a chunk layer into mesh arrays (one surface per material). Returns [] if empty.
func layer_surfaces(ck: Vector2i, layer: String) -> Array:
	var out := []
	if not chunks.has(ck):
		return out
	for key in chunks[ck].parts:
		var s: Dictionary = chunks[ck].parts[key]
		if s.layer != layer or s.v.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = s.v
		arrays[Mesh.ARRAY_NORMAL] = s.n
		arrays[Mesh.ARRAY_TANGENT] = s.t
		arrays[Mesh.ARRAY_TEX_UV] = s.uv
		arrays[Mesh.ARRAY_COLOR] = s.c
		arrays[Mesh.ARRAY_INDEX] = s.i
		if s.uber:
			arrays[Mesh.ARRAY_TEX_UV2] = s.uv2
		out.append({"arrays": arrays, "mat": s.mat})
	return out
