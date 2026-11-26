class_name CityGen
extends RefCounted
## Procedural city: roads, blocks of multi-storey buildings with shop fronts, awnings,
## signs and rooftop clutter, a park, the beach strip and street furniture.
## Port of the web build's city.js. Buildings are merged per material by MeshBuilder.

const PASTEL := [0xffc7d6, 0xbfeee0, 0xffe2b8, 0xd8ccff, 0xbfe3ff, 0xfff2c2, 0xf9d1b7, 0xc9f2c4, 0xfafafa, 0xffd9ec]
const CONCRETE := [0xe9e6e0, 0xd9d6cf, 0xcfd3d6, 0xf2ece2, 0xdfe3e8]
const GLASSC := [0xbfe3ff, 0xc9f0e2, 0xf0dcc0, 0xd6d9ff, 0xe8f4ff, 0xbfd8e8]
const BRICKC := [0xffffff, 0xf3e1d6, 0xe8d0c4, 0xd9c2b8]
const AWNING := [0xe2434b, 0x2c8f6e, 0x2e6fd1, 0xf2a531, 0x8b4bd1, 0x1d9fb5, 0xe85d9a, 0x333a44]
const FH := 3.4
const GF := 4.2

var B: MeshBuilder
var rng := RandomNumberGenerator.new()
var keep_clear: Array = []

static func col(h: int) -> Color:
	return Color.hex((h << 8) | 0xff)

func R() -> float:
	return rng.randf()

func pick(a: Array):
	return a[rng.randi() % a.size()]

func _init(builder: MeshBuilder) -> void:
	B = builder
	rng.seed = 1337

# ---------- layout ----------
static func intervals(roads: Array, lo: float, hi: float) -> Array:
	var out := []
	var prev := lo
	var prev_road := false
	for r in roads:
		if r - 6.0 > prev:
			out.append({"a": prev, "b": r - 6.0, "lo": prev_road, "hi": true})
		prev = r + 6.0
		prev_road = true
	if hi > prev:
		out.append({"a": prev, "b": hi, "lo": prev_road, "hi": false})
	return out

static func x_blocks() -> Array:
	return intervals(Game.ROAD_X, Game.WORLD.min_x, Game.ROAD_SPAN_X[1])

static func z_blocks() -> Array:
	return intervals(Game.ROAD_Z, Game.WORLD.min_z, Game.WORLD.max_z)

const RESERVED := {
	"-44,-44": [[-41, -9, -41, -28]],
	"6,-44": [[9, 41, -41, -26], [32, 41, -22, -12]],
	"6,6": [[9, 41, 35, 41]],
	"-44,6": [],
	"-94,-44": [[-91, -84, -41, -12], [-80, -62, -41, -27]],
	"56,-44": [[85, 91, -41, -12], [66, 82, -41, -30], [59, 63, -41, -27]],
	"56,6": [[80, 91, 9, 41], [64, 76, 30, 41]],
	"-94,56": "park",
}

func build(keep: Array) -> void:
	keep_clear = keep
	roads()
	blocks()
	beach()
	street_props()

# ---------- buildings ----------
func rooftop(cx: float, cz: float, w: float, d: float, top: float) -> void:
	var roof := Mats.m("roof_gravel")
	var t := 0.25
	var ph := 0.9
	var nc := {"collide": false}
	B.box(cx, top, cz - d / 2 + t / 2, w, ph, t, roof, nc)
	B.box(cx, top, cz + d / 2 - t / 2, w, ph, t, roof, nc)
	B.box(cx - w / 2 + t / 2, top, cz, t, ph, d, roof, nc)
	B.box(cx + w / 2 - t / 2, top, cz, t, ph, d, roof, nc)
	var paint := Mats.m("paint")
	var metal := Mats.m("metal_brushed")
	for i in 1 + int(R() * 3):
		var ax := cx + (R() - 0.5) * (w - 4)
		var az := cz + (R() - 0.5) * (d - 4)
		B.box(ax, top, az, 1.6, 1.1, 1.2, paint, {"color": col(0xb9bdc2), "collide": false})
		B.box(ax, top + 1.1, az, 1.0, 0.12, 0.8, metal, nc)
	if w > 10 and d > 10 and R() < 0.5:
		B.box(cx + (R() - 0.5) * (w - 6), top, cz + (R() - 0.5) * (d - 6), 3, 2.6, 3, paint, {"color": col(0xcfcac2), "collide": false})
	if R() < 0.35 and w > 8:
		var tx := cx + (R() - 0.5) * (w - 5)
		var tz := cz + (R() - 0.5) * (d - 5)
		for o in [[-0.8, -0.8], [0.8, -0.8], [-0.8, 0.8], [0.8, 0.8]]:
			B.box(tx + o[0], top, tz + o[1], 0.18, 2.2, 0.18, metal, nc)
		B.cylinder(tx, top + 2.2, tz, 1.3, 2.4, Mats.m("wood_planks"), Color.WHITE, 12)
		B.cylinder(tx, top + 4.6, tz, 1.4, 0.8, metal, Color.WHITE, 12, 0.0)
	if R() < 0.25:
		B.box(cx + (R() - 0.5) * w * 0.6, top, cz + (R() - 0.5) * d * 0.6, 0.15, 5 + R() * 5, 0.15, metal, nc)

func facade_for(style: String) -> Array:
	match style:
		"glass": return [Mats.m("facade_glass"), col(pick(GLASSC))]
		"office": return [Mats.m("facade_office"), col(pick(CONCRETE))]
		"brick": return [Mats.m("facade_brick"), col(pick(BRICKC))]
	return [Mats.m("facade_stucco"), col(pick(PASTEL))]

func sign_quad(p: Vector3, w: float, yaw: float, idx: int) -> void:
	var c := idx % 4
	var r := idx / 4
	B.quad(p, w, w / 4.0, yaw, Mats.m("signs"), Vector2(c / 4.0, r / 8.0), Vector2((c + 1) / 4.0, (r + 1) / 8.0))

func ad_quad(p: Vector3, w: float, yaw: float, idx: int) -> void:
	var c := idx % 2
	var r := idx / 2
	B.quad(p, w, w / 2.0, yaw, Mats.m("ads"), Vector2(c / 2.0, r / 2.0), Vector2((c + 1) / 2.0, (r + 1) / 2.0))

## o: style, floors, setback, ad, sides {n,s,e,w}, facade (Material), color
func building(x1: float, x2: float, z1: float, z2: float, o: Dictionary) -> float:
	var w := x2 - x1
	var d := z2 - z1
	var cx := (x1 + x2) / 2
	var cz := (z1 + z2) / 2
	Game.footprints.append(Rect2(x1, z1, w, d))
	var style: String = o.get("style", "stucco")
	var fc: Array = [o.facade, o.color] if o.has("facade") else facade_for(style)
	var mat: Material = fc[0]
	var color: Color = fc[1]
	var floors: int = o.floors
	var trim: Color = col(0x8fa3b3) if style == "glass" else col(0xf4f1ea)
	var paint := Mats.m("paint")
	var nc := {"collide": false}
	var gf_color: Color = col(0xdfe3e8) if style in ["glass", "office"] else color
	B.box(cx, 0, cz, w, GF, d, Mats.m("shopfront"), {"color": gf_color, "collide": false})
	B.box(cx, GF - 0.25, cz, w + 0.3, 0.35, d + 0.3, paint, {"color": trim, "collide": false})
	var setback: bool = o.get("setback", false) and floors > 9 and w > 16 and d > 16
	var low_f: int = int(ceil(floors * 0.55)) if setback else floors
	var low_top := GF + low_f * FH
	B.box(cx, GF, cz, w, low_f * FH, d, mat, {"color": color, "collide": false})
	var f := 3
	while f < low_f:
		B.box(cx, GF + f * FH - 0.1, cz, w + 0.2, 0.22, d + 0.2, paint, {"color": trim, "collide": false})
		f += 3
	if style != "glass" and style != "office":
		for pc in [[x1, z1], [x2, z1], [x1, z2], [x2, z2]]:
			B.box(pc[0], GF, pc[1], 0.7, low_f * FH + 0.3, 0.7, paint, {"color": trim, "collide": false})
	B.box(cx, low_top - 0.15, cz, w + 0.6, 0.5, d + 0.6, paint, {"color": trim, "collide": false})
	B.box(cx, low_top, cz, w, 0.12, d, Mats.m("roof_gravel"), nc)
	B.add_col(Vector3(x1, 0, z1), Vector3(x2, low_top + 1, z2))
	B.building_volume(Vector3(x1, 0, z1), Vector3(x2, low_top, z2), Mats.far_cell(mat), color, GF)
	var top := low_top
	if setback:
		var iw := w - 6
		var id := d - 6
		var up_f := floors - low_f
		B.box(cx, low_top, cz, iw, up_f * FH, id, mat, {"color": color, "collide": false})
		f = 3
		while f < up_f:
			B.box(cx, low_top + f * FH - 0.1, cz, iw + 0.2, 0.22, id + 0.2, paint, {"color": trim, "collide": false})
			f += 3
		top = low_top + up_f * FH
		B.box(cx, top - 0.15, cz, iw + 0.6, 0.5, id + 0.6, paint, {"color": trim, "collide": false})
		B.box(cx, top, cz, iw, 0.12, id, Mats.m("roof_gravel"), nc)
		B.add_col(Vector3(cx - iw / 2, low_top, cz - id / 2), Vector3(cx + iw / 2, top + 1, cz + id / 2))
		B.building_volume(Vector3(cx - iw / 2, low_top, cz - id / 2), Vector3(cx + iw / 2, top, cz + id / 2), Mats.far_cell(mat), color)
		rooftop(cx, cz, iw, id, top)
		rooftop(cx, cz, w, d, low_top)
	else:
		rooftop(cx, cz, w, d, top)
	var sides: Dictionary = o.get("sides", {})
	if style == "deco" and not sides.is_empty():
		var side := "w" if sides.get("w") else "n" if sides.get("n") else "s" if sides.get("s") else "e"
		var fx := x1 - 0.4 if side == "w" else x2 + 0.4 if side == "e" else cx
		var fz := z1 - 0.4 if side == "n" else z2 + 0.4 if side == "s" else cz
		var fw := 0.8 if side in ["w", "e"] else 2.4
		var fd := 2.4 if side in ["w", "e"] else 0.8
		B.box(fx, GF, fz, fw, top - GF + 4, fd, paint, {"color": Color.WHITE, "collide": false})
		B.box(fx, top + 2.5, fz, fw + 0.3, 0.4, fd + 0.3, Mats.m("lamp_glow"), {"collide": false})
	var faces := []
	if sides.get("n"): faces.append({"ax": "x", "a": x1, "b": x2, "pos": z1, "out": -1.0, "yaw": PI})
	if sides.get("s"): faces.append({"ax": "x", "a": x1, "b": x2, "pos": z2, "out": 1.0, "yaw": 0.0})
	if sides.get("w"): faces.append({"ax": "z", "a": z1, "b": z2, "pos": x1, "out": -1.0, "yaw": -PI / 2})
	if sides.get("e"): faces.append({"ax": "z", "a": z1, "b": z2, "pos": x2, "out": 1.0, "yaw": PI / 2})
	for fa in faces:
		var length: float = fa.b - fa.a
		var bays := maxi(1, int(length / 7.0))
		var bw := length / bays
		for i in bays:
			var c: float = fa.a + bw * (i + 0.5)
			if R() < 0.7:
				var aw := minf(5.2, bw - 1.2)
				var basis := Basis(Vector3.RIGHT, -fa.out * 0.32) if fa.ax == "x" else Basis(Vector3.BACK, fa.out * 0.32)
				var off: float = 0.85 * fa.out
				var p := Vector3(c, 2.85, fa.pos + off) if fa.ax == "x" else Vector3(fa.pos + off, 2.85, c)
				B.box(p.x, p.y - 0.07, p.z, aw if fa.ax == "x" else 1.7, 0.14, 1.7 if fa.ax == "x" else aw, Mats.m("awning"), {"basis": basis, "color": col(pick(AWNING)), "collide": false})
			if R() < 0.8:
				var sw := minf(4.0, bw - 1.5)
				var so: float = 0.09 * fa.out
				var sp := Vector3(c, 3.6, fa.pos + so) if fa.ax == "x" else Vector3(fa.pos + so, 3.6, c)
				sign_quad(sp, sw, fa.yaw, rng.randi() % 32)
	if o.get("ad", false) and not faces.is_empty():
		var fa: Dictionary = faces[0]
		var bw := minf(12.0, (fa.b - fa.a) - 2.0)
		var c: float = (fa.a + fa.b) / 2
		var inset: float = -2.2 * fa.out
		var bx: float = c if fa.ax == "x" else fa.pos + inset
		var bz: float = fa.pos + inset if fa.ax == "x" else c
		var metal := Mats.m("metal_brushed")
		var ox := bw / 3 if fa.ax == "x" else 0.0
		var oz := bw / 3 if fa.ax == "z" else 0.0
		B.box(bx - ox, top, bz - oz, 0.3, 3, 0.3, metal, nc)
		B.box(bx + ox, top, bz + oz, 0.3, 3, 0.3, metal, nc)
		B.box(bx, top + 3, bz, bw + 0.4 if fa.ax == "x" else 0.3, bw / 2 + 0.4, 0.3 if fa.ax == "x" else bw + 0.4, metal, nc)
		var ap := Vector3(bx + (0.17 * fa.out if fa.ax == "z" else 0.0), top + 3 + bw / 4 + 0.2, bz + (0.17 * fa.out if fa.ax == "x" else 0.0))
		ad_quad(ap, bw, fa.yaw, rng.randi() % 4)
	return top

func zone_of(cx: float, cz: float) -> String:
	if cx > 100:
		return "beach"
	if maxf(absf(cx), absf(cz)) < 75:
		return "core"
	return "outer"

func style_for(zone: String) -> Dictionary:
	var r := R()
	if zone == "beach":
		return {"style": "deco", "floors": 4 + int(R() * 7), "facade": Mats.m("facade_stucco"), "color": col(pick(PASTEL)), "ad": R() < 0.3}
	if zone == "core":
		return {"style": "stucco" if r < 0.45 else "brick" if r < 0.75 else "office", "floors": 2 + int(R() * 5), "ad": R() < 0.25}
	return {"style": "glass" if r < 0.45 else "office" if r < 0.85 else "stucco", "floors": 8 + int(R() * 10 + R() * 6), "setback": R() < 0.6, "ad": R() < 0.15}

func blocks() -> void:
	var walk := Mats.m("sidewalk")
	for bx in x_blocks():
		for bz in z_blocks():
			var key := "%d,%d" % [int(bx.a), int(bz.a)]
			var bld := [bx.a + (3.0 if bx.lo else 0.0), bx.b - (3.0 if bx.hi else 0.0), bz.a + (3.0 if bz.lo else 0.0), bz.b - (3.0 if bz.hi else 0.0)]
			B.box((bx.a + bx.b) / 2, 0, (bz.a + bz.b) / 2, bx.b - bx.a, 0.15, bz.b - bz.a, walk, {"layer": "ground", "shadow": false})
			var res = RESERVED.get(key)
			if res is String:
				park(bld)
				continue
			var lots := []
			if res != null:
				lots = res
			else:
				var x1: float = bld[0]
				var x2: float = bld[1]
				var z1: float = bld[2]
				var z2: float = bld[3]
				var xs := [[x1, x2]]
				if x2 - x1 >= 30 and R() < 0.8:
					var m := (x1 + x2) / 2 - 1.8 + (R() - 0.5) * 6
					xs = [[x1, m], [m + 3.6, x2]]
				var zs := [[z1, z2]]
				if z2 - z1 >= 30 and R() < 0.8:
					var m := (z1 + z2) / 2 - 1.8 + (R() - 0.5) * 6
					zs = [[z1, m], [m + 3.6, z2]]
				for a in xs:
					for b in zs:
						lots.append([a[0], a[1], b[0], b[1]])
			for l in lots:
				var cx: float = (l[0] + l[1]) / 2.0
				var cz: float = (l[2] + l[3]) / 2.0
				var st := style_for(zone_of(cx, cz))
				if res != null and st.floors > 6:
					st.floors = 3 + int(R() * 4)
				st["sides"] = {
					"n": bz.lo and absf(l[2] - bld[2]) < 0.01, "s": bz.hi and absf(l[3] - bld[3]) < 0.01,
					"w": bx.lo and absf(l[0] - bld[0]) < 0.01, "e": bx.hi and absf(l[1] - bld[1]) < 0.01,
				}
				building(l[0], l[1], l[2], l[3], st)

func park(bld: Array) -> void:
	var x1: float = bld[0]
	var x2: float = bld[1]
	var z1: float = bld[2]
	var z2: float = bld[3]
	var cx := (x1 + x2) / 2
	var cz := (z1 + z2) / 2
	var w := x2 - x1
	var d := z2 - z1
	B.box(cx, 0.15, cz, w, 0.05, d, Mats.m("grass"), {"collide": false, "shadow": false})
	B.box(cx, 0.2, cz, w, 0.02, 3, Mats.m("sidewalk"), {"collide": false, "shadow": false})
	B.box(cx, 0.2, cz, 3, 0.02, d, Mats.m("sidewalk"), {"collide": false, "shadow": false})
	B.cylinder(cx, 0.15, cz, 5, 0.7, Mats.m("concrete"), col(0xe9e6e0), 24)
	B.add_col(Vector3(cx - 4.4, 0, cz - 4.4), Vector3(cx + 4.4, 0.85, cz + 4.4))
	B.cylinder(cx, 0.5, cz, 4.5, 0.32, Mats.m("water"), Color.WHITE, 24, -1.0, {"shadow": false})
	B.cylinder(cx, 0.5, cz, 0.6, 2.4, Mats.m("concrete"), col(0xe9e6e0), 12)
	B.cylinder(cx, 2.9, cz, 1.4, 0.3, Mats.m("concrete"), col(0xe9e6e0), 16)
	for i in 14:
		var a := TAU * i / 14.0
		palm(cx + cos(a) * (w / 2 - 3), cz + sin(a) * (d / 2 - 3), 6 + R() * 4)
	for bb in [[cx - 7, cz, 0.0], [cx + 7, cz, 0.0], [cx, cz - 7, PI / 2], [cx, cz + 7, PI / 2]]:
		bench(bb[0], bb[1], bb[2])

# ---------- props ----------
func palm(x: float, z: float, h := 7.0) -> void:
	var lean := (R() - 0.5) * 0.12
	var dir := R() * TAU
	var trunk := Mats.m("trunk")
	var segs := 6
	for i in segs:
		var t := float(i) / segs
		var ox := cos(dir) * lean * t * h * t
		var oz := sin(dir) * lean * t * h * t
		var s := 0.42 - t * 0.12
		B.box(x + ox, i * (h / segs), z + oz, s, h / segs + 0.05, s, trunk, {"basis": Basis(Vector3.UP, i * 0.4), "collide": false})
	var tx := x + cos(dir) * lean * h
	var tz := z + sin(dir) * lean * h
	var top := Vector3(tx, h, tz)
	var leaf := Mats.m("leaf")
	var greens := [0x3f8f3a, 0x4ea341, 0x5aa84a, 0x377f33]
	for i in 8:
		var basis := Basis(Vector3.UP, TAU * i / 8.0 + R() * 0.3) * Basis(Vector3.RIGHT, 0.35 + R() * 0.35)
		var c := top + basis * Vector3(0, 0, 1.5)
		B.box(c.x, c.y - 0.02, c.z, 0.7, 0.04, 3.2, leaf, {"basis": basis, "color": col(greens[i % 4]), "collide": false})
	B.box(tx, h - 0.35, tz, 0.5, 0.4, 0.5, Mats.m("paint"), {"color": col(0x6b4a2a), "collide": false})
	B.add_col(Vector3(x - 0.25, 0, z - 0.25), Vector3(x + 0.25, h, z + 0.25))

func lamp(x: float, z: float, dx: float, dz: float) -> void:
	var metal := Mats.m("metal_brushed")
	B.box(x, 0.15, z, 0.18, 6.2, 0.18, metal, {"collide": false})
	B.add_col(Vector3(x - 0.15, 0, z - 0.15), Vector3(x + 0.15, 6, z + 0.15))
	B.box(x + dx * 0.8, 6.2, z + dz * 0.8, 1.8 if dx != 0 else 0.12, 0.12, 1.8 if dz != 0 else 0.12, metal, {"collide": false})
	B.box(x + dx * 1.6, 6.0, z + dz * 1.6, 0.6, 0.18, 0.6, Mats.m("lamp_glow"), {"collide": false, "shadow": false})
	B.box(x + dx * 1.6, 6.15, z + dz * 1.6, 0.7, 0.12, 0.7, metal, {"collide": false})

func bench(x: float, z: float, rot: float) -> void:
	var b := Basis(Vector3.UP, rot)
	var wood := Mats.m("wood_planks")
	var seat := Vector3(x, 0.55, z)
	B.box(seat.x, seat.y, seat.z, 1.8, 0.1, 0.5, wood, {"basis": b, "collide": false})
	var back := seat + b * Vector3(0, 0, -0.25)
	B.box(back.x, 0.8, back.z, 1.8, 0.45, 0.08, wood, {"basis": b, "collide": false})
	for s in [-0.8, 0.8]:
		var lp := seat + b * Vector3(s, 0, 0)
		B.box(lp.x, 0.15, lp.z, 0.08, 0.42, 0.45, Mats.m("metal_brushed"), {"basis": b, "collide": false})

func traffic_light(x: float, z: float, dx: float, dz: float) -> void:
	var metal := Mats.m("metal_brushed")
	var paint := Mats.m("paint")
	B.box(x, 0.15, z, 0.24, 5.6, 0.24, metal, {"collide": false})
	B.add_col(Vector3(x - 0.18, 0, z - 0.18), Vector3(x + 0.18, 5.6, z + 0.18))
	B.box(x + dx * 2.6, 5.4, z + dz * 2.6, 5.2 if dx != 0 else 0.14, 0.14, 5.2 if dz != 0 else 0.14, metal, {"collide": false})
	for k in [2.2, 4.6]:
		var hx: float = x + dx * k
		var hz: float = z + dz * k
		B.box(hx, 4.3, hz, 0.38, 1.05, 0.38, paint, {"color": col(0x2a2d31), "collide": false})
		var on := rng.randi() % 3
		var lit := [0xff3b30, 0xffcc00, 0x34c759]
		for i in 3:
			if i == on:
				B.box(hx, 5.1 - i * 0.32, hz, 0.42, 0.22, 0.42, Mats.m("lamp_glow"), {"collide": false, "shadow": false, "color": col(lit[i])})
			else:
				B.box(hx, 5.1 - i * 0.32, hz, 0.42, 0.22, 0.42, paint, {"color": col(0x3a3d42), "collide": false})

func hydrant(x: float, z: float) -> void:
	B.cylinder(x, 0.15, z, 0.16, 0.7, Mats.m("paint_gloss"), col(0xd63a2f), 8)
	B.box(x, 0.45, z, 0.5, 0.12, 0.12, Mats.m("paint_gloss"), {"color": col(0xd63a2f), "collide": false})

func trash_bin(x: float, z: float) -> void:
	B.cylinder(x, 0.15, z, 0.3, 0.95, Mats.m("paint"), col(0x2f5d3a), 10)

func near_keep(x: float, z: float, r: float) -> bool:
	for p in keep_clear:
		if Vector2(p[0] - x, p[1] - z).length() < r:
			return true
	return false

func street_props() -> void:
	var span_z: Array = Game.ROAD_SPAN_Z
	var span_x: Array = Game.ROAD_SPAN_X
	for rx in Game.ROAD_X:
		for side in [-1.0, 1.0]:
			if rx == 150.0 and side == 1.0:
				continue
			var px: float = rx + side * 6.6
			var k := 0
			var z: float = span_z[0] + 8
			while z < span_z[1] - 4:
				var skip := false
				for r in Game.ROAD_Z:
					if absf(z - r) < 9.5:
						skip = true
				if not skip and not near_keep(px, z, 4):
					var boulevard: bool = rx == 150.0 or rx == 0.0
					if k % 2 == 0:
						lamp(px, z, -side, 0)
					elif boulevard or R() < 0.35:
						palm(px + side * 0.6, z, 6.5 + R() * 3.5)
					elif R() < 0.3:
						if R() < 0.5: hydrant(px, z)
						else: trash_bin(px, z)
				z += 12.5
				k += 1
	for rz in Game.ROAD_Z:
		for side in [-1.0, 1.0]:
			var pz: float = rz + side * 6.6
			var k := 0
			var x: float = span_x[0] + 8
			while x < span_x[1] - 4:
				var skip := false
				for r in Game.ROAD_X:
					if absf(x - r) < 9.5:
						skip = true
				if not skip and not near_keep(x, pz, 4):
					if k % 2 == 0:
						lamp(x, pz, 0, -side)
					elif rz == 0.0 or R() < 0.35:
						palm(x, pz + side * 0.6, 6.5 + R() * 3.5)
					elif R() < 0.3:
						if R() < 0.5: hydrant(x, pz)
						else: trash_bin(x, pz)
				x += 12.5
				k += 1
	# zebra crossings as real stripes in the merged city material (no transparent
	# overlay quads = no extra draw calls / overdraw)
	var stripe := Mats.m("line_white")
	var zc := {"collide": false, "shadow": false, "color": Color(0.96, 0.96, 0.94)}
	var zebra := func(cx: float, y: float, cz: float, along_x: bool):
		for k in 8:
			var o := -6.0 + 0.375 + 0.375 + k * 1.5
			if along_x:
				B.box(cx + o, y, cz, 0.75, 0.02, 2.8, stripe, zc)
			else:
				B.box(cx, y, cz + o, 2.8, 0.02, 0.75, stripe, zc)
	for rx in Game.ROAD_X:
		for rz in Game.ROAD_Z:
			var tee: bool = rx == 150.0
			for dd in [[0, 1], [0, -1], [1, 0], [-1, 0]]:
				if tee and dd[0] == 1:
					continue
				if dd[1] != 0:
					zebra.call(rx, 0.03, rz + dd[1] * 7.6, true)
				else:
					zebra.call(rx + dd[0] * 7.6, 0.05, rz, false)
			if not near_keep(rx + 7.4, rz + 7.4, 4):
				traffic_light(rx + 7.4, rz + 7.4, -1, 0)
			if not tee and not near_keep(rx - 7.4, rz - 7.4, 4):
				traffic_light(rx - 7.4, rz - 7.4, 1, 0)

# ---------- roads ----------
func roads() -> void:
	var W: Dictionary = Game.WORLD
	var asphalt := Mats.m("asphalt")
	var yellow := Mats.m("line_yellow")
	var white := Mats.m("line_white")
	var nc := {"collide": false, "shadow": false}
	var span_z: Array = Game.ROAD_SPAN_Z
	var span_x: Array = Game.ROAD_SPAN_X
	var len_z: float = span_z[1] - span_z[0]
	for x in Game.ROAD_X:
		B.box(x, 0, 0, 12, 0.02, len_z, asphalt, nc)
		var z: float = span_z[0] + 2
		while z < span_z[1]:
			var skip := false
			for r in Game.ROAD_Z:
				if absf(z - r) < 9:
					skip = true
			if not skip:
				B.box(x - 0.15, 0.021, z, 0.12, 0.01, 6, yellow, nc)
				B.box(x + 0.15, 0.021, z, 0.12, 0.01, 6, yellow, nc)
			z += 6
		for s in [-5.6, 5.6]:
			B.box(x + s, 0.021, 0, 0.12, 0.01, len_z, white, nc)
	for z in Game.ROAD_Z:
		var x0: float = span_x[0]
		var x1: float = span_x[1] + 6
		B.box((x0 + x1) / 2, 0.025, z, x1 - x0, 0.02, 12, asphalt, nc)
		var x: float = x0 + 2
		while x < x1:
			var skip := false
			for r in Game.ROAD_X:
				if absf(x - r) < 9:
					skip = true
			if not skip:
				B.box(x, 0.046, z - 0.15, 6, 0.01, 0.12, yellow, nc)
				B.box(x, 0.046, z + 0.15, 6, 0.01, 0.12, yellow, nc)
			x += 6
		var stops := [x0]
		for r in Game.ROAD_X:
			stops.append(r - 6.0)
			stops.append(r + 6.0)
		stops.append(x1)
		stops = stops.filter(func(v): return v >= x0 and v <= x1)
		stops.sort()
		var k := 0
		while k < stops.size() - 1:
			var a: float = stops[k]
			var b: float = stops[k + 1]
			if b - a >= 1:
				for s in [-5.6, 5.6]:
					B.box((a + b) / 2, 0.046, z + s, b - a, 0.01, 0.12, white, nc)
			k += 2
	# boundary walls
	var paint := Mats.m("concrete")
	var cx: float = (W.min_x + W.shore) / 2
	var wx: float = W.shore - W.min_x + 2
	B.box(cx, 0, W.min_z - 0.5, wx, 10, 1, paint, {"color": col(0xd9d6cf)})
	B.box(cx, 0, W.max_z + 0.5, wx, 10, 1, paint, {"color": col(0xd9d6cf)})
	B.box(W.min_x - 0.5, 0, 0, 1, 10, W.max_z - W.min_z + 2, paint, {"color": col(0xd9d6cf)})
	for x in Game.ROAD_X:
		for z in [span_z[0] + 1, span_z[1] - 1]:
			var kk := -5.0
			while kk <= 5.0:
				B.box(x + kk, 0, z, 2, 1, 0.6, Mats.m("paint"), {"color": col(0xf2f2f2) if int(kk) % 5 == 0 else col(0xe2434b)})
				kk += 2.5

# ---------- beach ----------
func beach() -> void:
	var W: Dictionary = Game.WORLD
	var z0: float = W.min_z
	var z1: float = W.max_z
	var L := z1 - z0
	B.box(158, 0, 0, 4, 0.15, L, Mats.m("wood_planks"), {"layer": "ground", "shadow": false})
	B.box(167, 0, 0, 14, 0.12, L, Mats.m("sand"), {"layer": "ground", "shadow": false})
	B.box(181, 0, 0, 14, 0.04, L, Mats.m("sand"), {"layer": "ground", "shadow": false})
	B.add_col(Vector3(W.shore, 0, z0), Vector3(W.shore + 2, 4, z1))
	var z := z0 + 10
	while z < z1 - 5:
		palm(160.6, z, 7 + R() * 3)
		if R() < 0.5:
			bench(161.5, z + 6, PI / 2)
		z += 14
	var cols := [0xe2434b, 0xf2a531, 0x1d9fb5, 0xe85d9a, 0x2c8f6e, 0xffffff]
	for i in 26:
		var x := 165 + R() * 10
		var uz := z0 + 12 + R() * (L - 24)
		B.cylinder(x, 0.1, uz, 0.05, 2.3, Mats.m("metal_brushed"), Color.WHITE, 6)
		B.cylinder(x, 2.0, uz, 1.5, 0.6, Mats.m("paint"), col(pick(cols)), 10, 0.0)
		B.box(x + 1.2, 0.3, uz, 0.7, 0.12, 1.9, Mats.m("paint"), {"basis": Basis(Vector3.UP, R() * 0.6), "collide": false})
	for tz in [-90.0, -10.0, 70.0]:
		for o in [[-0.9, -0.9], [0.9, -0.9], [-0.9, 0.9], [0.9, 0.9]]:
			B.box(172 + o[0], 0.1, tz + o[1], 0.15, 2.2, 0.15, Mats.m("wood_planks"), {"collide": false})
		B.box(172, 2.3, tz, 2.4, 1.8, 2.4, Mats.m("paint"), {"color": col(pick(PASTEL)), "collide": false})
		B.box(172, 4.1, tz, 2.9, 0.15, 2.9, Mats.m("paint"), {"basis": Basis(Vector3.RIGHT, 0.12), "color": col(0xe2434b), "collide": false})
		B.add_col(Vector3(171, 0, tz - 1), Vector3(173, 4, tz + 1))
