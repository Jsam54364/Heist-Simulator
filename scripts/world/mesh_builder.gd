class_name MeshBuilder
extends RefCounted
## Accumulates static geometry per material (one draw call per material) and
## creates box colliders. Every box keeps its world-space AABB in `cols` so
## navigation, line-of-sight helpers and the minimap can use the same data.

var surfaces := {}
var cols: Array = []          # {min: Vector3, max: Vector3, glass: bool, solid: bool, tag}
var world_body: StaticBody3D
var glass_body: StaticBody3D
var ground_body: StaticBody3D

const FACES := [
	# normal, right (u+), up (v-)
	[Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)],
	[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
	[Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)],
	[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
	[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
	[Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
]

func _init(parent: Node3D) -> void:
	world_body = _body(parent, "WorldStatic", Game.L_WORLD)
	glass_body = _body(parent, "GlassStatic", Game.L_GLASS)
	ground_body = _body(parent, "GroundStatic", Game.L_GROUND)

func _body(parent: Node3D, n: String, layer: int) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = n
	b.collision_layer = layer
	b.collision_mask = 0
	parent.add_child(b)
	return b

## Geometry is merged per (spatial chunk, material, shadow flag): few draw calls, but
## chunks still frustum-cull, and each chunk only touches nearby lights (the Mobile
## renderer allows 8 omni/spot lights per mesh instance).
const CHUNK := 48.0

func _surf(mat: Material, shadow: bool, at: Vector3) -> Dictionary:
	var ck := Vector2i(int(floor(at.x / CHUNK)), int(floor(at.z / CHUNK)))
	var key := "%d_%s_%d_%d" % [mat.get_instance_id(), shadow, ck.x, ck.y]
	if not surfaces.has(key):
		surfaces[key] = {"mat": mat, "shadow": shadow, "chunk": ck, "v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array(), "c": PackedColorArray(), "i": PackedInt32Array()}
	return surfaces[key]

## Take a surface's arrays out of the dictionary (so appends don't copy), then put them back.
func _take(s: Dictionary) -> Array:
	var a := [s.v, s.n, s.uv, s.c, s.i]
	s.v = PackedVector3Array(); s.n = PackedVector3Array(); s.uv = PackedVector2Array(); s.c = PackedColorArray(); s.i = PackedInt32Array()
	return a

func _put(s: Dictionary, a: Array) -> void:
	s.v = a[0]; s.n = a[1]; s.uv = a[2]; s.c = a[3]; s.i = a[4]

## Box with base at y. opts: color, tile (Vector2 metres per texture repeat), basis (rotation),
## collide (bool, default true), layer ("world"|"glass"|"ground"), shadow (bool), tag
func box(cx: float, y: float, cz: float, w: float, h: float, d: float, mat: Material, opts := {}) -> Dictionary:
	var tile: Vector2 = opts.get("tile", Mats.tile_of(mat))
	var col: Color = opts.get("color", Color.WHITE)
	var basis: Basis = opts.get("basis", Basis.IDENTITY)
	var center := Vector3(cx, y + h * 0.5, cz)
	var hs := Vector3(w * 0.5, h * 0.5, d * 0.5)
	var s := _surf(mat, opts.get("shadow", true), center)
	var a := _take(s)
	var v: PackedVector3Array = a[0]
	var n: PackedVector3Array = a[1]
	var uv: PackedVector2Array = a[2]
	var c: PackedColorArray = a[3]
	var idx: PackedInt32Array = a[4]
	for f in FACES:
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
		v.append(basis * ((nn - r + up) * hs) + center)
		v.append(basis * ((nn + r + up) * hs) + center)
		v.append(basis * ((nn + r - up) * hs) + center)
		v.append(basis * ((nn - r - up) * hs) + center)
		n.append(wn); n.append(wn); n.append(wn); n.append(wn)
		uv.append(Vector2(0, 0)); uv.append(Vector2(tu, 0)); uv.append(Vector2(tu, tv)); uv.append(Vector2(0, tv))
		c.append(col); c.append(col); c.append(col); c.append(col)
		idx.append(base); idx.append(base + 1); idx.append(base + 2)
		idx.append(base); idx.append(base + 2); idx.append(base + 3)
	_put(s, [v, n, uv, c, idx])
	var res := {}
	if opts.get("collide", true):
		res = add_col(Vector3(cx - w * 0.5, y, cz - d * 0.5), Vector3(cx + w * 0.5, y + h, cz + d * 0.5), opts)
	return res

## Single textured quad facing yaw (outward normal = U.fwd(yaw)); uv rect in 0..1
func quad(center: Vector3, w: float, h: float, yaw: float, mat: Material, uv0: Vector2, uv1: Vector2, opts := {}) -> void:
	var s := _surf(mat, opts.get("shadow", false), center)
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
		a[1].append(nn); a[3].append(col)
	a[2].append(uv0); a[2].append(Vector2(uv1.x, uv0.y)); a[2].append(uv1); a[2].append(Vector2(uv0.x, uv1.y))
	a[4].append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	_put(s, a)

## Vertical cylinder (or cone when r_top = 0) with base at y
func cylinder(cx: float, y: float, cz: float, r: float, h: float, mat: Material, color := Color.WHITE, seg := 10, r_top := -1.0, opts := {}) -> void:
	if r_top < 0.0:
		r_top = r
	var s := _surf(mat, opts.get("shadow", true), Vector3(cx, y, cz))
	var a := _take(s)
	var base: int = a[0].size()
	var slope := (r - r_top) / h
	for k in seg + 1:
		var ang := TAU * k / seg
		var dx := cos(ang)
		var dz := sin(ang)
		var nn := Vector3(dx, slope, dz).normalized()
		a[0].append(Vector3(cx + dx * r, y, cz + dz * r)); a[1].append(nn); a[2].append(Vector2(float(k) / seg, 1)); a[3].append(color)
		a[0].append(Vector3(cx + dx * r_top, y + h, cz + dz * r_top)); a[1].append(nn); a[2].append(Vector2(float(k) / seg, 0)); a[3].append(color)
	for k in seg:
		var a0 := base + k * 2
		a[4].append_array(PackedInt32Array([a0, a0 + 2, a0 + 1, a0 + 1, a0 + 2, a0 + 3]))
	if r_top > 0.0:
		var cidx: int = a[0].size()
		a[0].append(Vector3(cx, y + h, cz)); a[1].append(Vector3.UP); a[2].append(Vector2(0.5, 0.5)); a[3].append(color)
		for k in seg + 1:
			var ang := TAU * k / seg
			a[0].append(Vector3(cx + cos(ang) * r_top, y + h, cz + sin(ang) * r_top)); a[1].append(Vector3.UP); a[2].append(Vector2(0.5, 0.5)); a[3].append(color)
		for k in seg:
			a[4].append_array(PackedInt32Array([cidx, cidx + 1 + k, cidx + 2 + k]))
	_put(s, a)

func add_col(minv: Vector3, maxv: Vector3, opts := {}) -> Dictionary:
	var layer: String = opts.get("layer", "world")
	var colinfo := {"min": minv, "max": maxv, "glass": layer == "glass", "solid": opts.get("solid", true), "tag": opts.get("tag", ""), "ground": layer == "ground"}
	cols.append(colinfo)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = (maxv - minv).max(Vector3(0.02, 0.02, 0.02))
	cs.shape = bs
	cs.position = (minv + maxv) * 0.5
	var body := world_body
	if layer == "glass":
		body = glass_body
	elif layer == "ground":
		body = ground_body
	body.add_child(cs)
	colinfo["shape"] = cs
	return colinfo

func finalize(parent: Node3D) -> void:
	var meshes := {}
	for key in surfaces:
		var s: Dictionary = surfaces[key]
		if s.v.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = s.v
		arrays[Mesh.ARRAY_NORMAL] = s.n
		arrays[Mesh.ARRAY_TEX_UV] = s.uv
		arrays[Mesh.ARRAY_COLOR] = s.c
		arrays[Mesh.ARRAY_INDEX] = s.i
		var st := SurfaceTool.new()
		st.create_from_arrays(arrays)
		st.generate_tangents()
		var mkey := "%d_%d_%s" % [s.chunk.x, s.chunk.y, s.shadow]
		if not meshes.has(mkey):
			meshes[mkey] = {"mesh": ArrayMesh.new(), "shadow": s.shadow, "chunk": s.chunk}
		var mesh: ArrayMesh = meshes[mkey].mesh
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, s.mat)
	for mkey in meshes:
		var m: Dictionary = meshes[mkey]
		var mi := MeshInstance3D.new()
		mi.mesh = m.mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if m.shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.name = "Chunk_%d_%d%s" % [m.chunk.x, m.chunk.y, "" if m.shadow else "_ns"]
		parent.add_child(mi)
	surfaces.clear()
