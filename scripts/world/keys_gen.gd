class_name KeysGen
extends RefCounted
## Key Lento - a Florida-Keys island modelled on GTA 6's starting area (Rockstar's take on
## Key Largo): one long, narrow key with Route 1 running its length as the "main strip",
## Blackwater-Sound-style bay to the north and the Atlantic to the south, canal-front
## neighbourhoods of stilt houses with docks, marinas, bars, motels, gas stations, a
## giant whale statue, cell towers, a causeway bridge to the mainland and a long bridge
## to the next key (both closed during this chapter, like the starting area in GTA 6).
##
## Two stages:
##   layout()      at startup, fast: land mask, Route 1, streets, lots, landmarks, far-LOD
##                 volumes, minimap image. No meshes.
##   build_chunk() per 50 m chunk, on a worker thread when the chunk first comes into range:
##                 all geometry + colliders for the lots/streets/landmarks anchored in it.
## Everything is seeded per lot/chunk, so a chunk rebuilt later is identical.

const X0 := -1300.0
const X1 := 1300.0
const Z0 := -340.0
const Z1 := 340.0
const CELL := 5.0
const TOWN := 240.0          # |x| < TOWN: dense strip around the robbery sites
const RHW := 6.0             # Route 1 half width (4 lanes)
const SEA_Y := -0.35
const WATER := 0
const LAND := 1
const SAND := 2
const DOCK := 3
const BRIDGE_X := 1235.0     # land ends here; Route 1 continues as a bridge
const TOWN_X := [-200.0, -150.0, -100.0, -50.0, 0.0, 50.0, 100.0, 150.0, 200.0]
const TOWN_N := -60.0        # back street north of Route 1 (town)
const TOWN_S := 65.0         # back street south of Route 1 (town)
const SEED := 2026
## site footprints (built by SiteBuilder) + room around their doors/cars: no town lots here
const RESERVED := [Rect2(10, -26, 21, 19), Rect2(-36, -26, 22, 19), Rect2(-82, -24, 20, 17), Rect2(11, 7, 28, 27),
	Rect2(-42, 10, 30, 30), Rect2(62, 10, 16, 16), Rect2(-41, -19, 8, 10), Rect2(35, 12, 7, 10), Rect2(26, -21, 8, 11)]
const PASTEL := [0xffc7d6, 0xbfeee0, 0xffe2b8, 0xd8ccff, 0xbfe3ff, 0xfff2c2, 0xf9d1b7, 0xc9f2c4, 0xfafafa, 0xffd9ec, 0x9fe0d8, 0xf6e7a0]
const AWNING := [0xe2434b, 0x2c8f6e, 0x2e6fd1, 0xf2a531, 0x8b4bd1, 0x1d9fb5, 0xe85d9a, 0x333a44]
const ROOFS := [0xe8e8e4, 0xb9bdc2, 0x8a9aa6, 0xc9785a, 0xd9d2c2, 0x6f8a7a]
const BOATS := [0xffffff, 0xf2f2ee, 0x2e6fd1, 0xe2434b, 0x1d9fb5, 0xf2a531]

var nx := 0
var nz := 0
var mask := PackedByteArray()
var lots: Array = []         # {rect, kind, face: Vector2 (unit, toward the street), seed, h, color, cell, name, chunk}
var streets: Array = []      # {rect: Rect2 (asphalt), axis: "x"|"z"}
var marks: Array = []        # landmarks {kind, pos: Vector3, yaw, text, chunk}
var per_chunk := {}          # Vector2i -> {"lots": [], "streets": [], "marks": [], "basins": []}
var basins: Array = []       # marina basins {rect, docks_side}
var stilt_house := Rect2()
var spawn := Vector3.ZERO
var spawn_car := Vector3.ZERO
var spawn_car_yaw := 0.0
var map_image: Image
const MAP_PX := 1.0          # minimap pixels per metre

static func col(h: int) -> Color:
	return Color.hex((h << 8) | 0xff)

# ---------------------------------------------------------------- shape of the key
## Route 1 centre line (z as a function of x): dead straight through town, gentle
## sweeping bends along the rest of the key.
static func rc(x: float) -> float:
	var ax := absf(x)
	if ax <= 240.0:
		return 0.0
	var t := ax - 240.0
	var s := smoothstep(0.0, 160.0, t)
	return s * (24.0 * sin(t / 230.0) + 9.0 * sin(t / 97.0 + 1.3)) * (1.0 if x > 0.0 else -0.8)

static func _taper(x: float) -> float:
	var e := BRIDGE_X - absf(x)
	if e <= 0.0:
		return 0.0
	return lerpf(0.16, 1.0, smoothstep(0.0, 170.0, e))

## distance from the Route 1 centre line to the bay shore (north, -z)
static func north_w(x: float) -> float:
	var ax := absf(x)
	var w := 150.0
	if ax > TOWN + 20.0:
		var t := smoothstep(TOWN + 20.0, TOWN + 140.0, ax)
		w = lerpf(150.0, maxf(74.0, 104.0 + 34.0 * sin(x / 173.0 + 0.7) + 14.0 * sin(x / 61.0)), t)
	# room for Brian's marina, Jason's house and the marina club
	w += 46.0 * exp(-pow((x + 500.0) / 110.0, 2.0)) + 26.0 * exp(-pow((x + 330.0) / 70.0, 2.0)) + 40.0 * exp(-pow((x - 1015.0) / 90.0, 2.0))
	return w * _taper(x)

## distance from the Route 1 centre line to the ocean shore (south, +z)
static func south_w(x: float) -> float:
	var ax := absf(x)
	var w := 160.0
	if ax > TOWN + 20.0:
		var t := smoothstep(TOWN + 20.0, TOWN + 140.0, ax)
		w = lerpf(160.0, maxf(76.0, 100.0 + 40.0 * sin(x / 211.0 + 2.1) + 13.0 * sin(x / 47.0 + 0.3)), t)
	w += 24.0 * exp(-pow((x - 580.0) / 90.0, 2.0))
	return w * _taper(x)

func ci(x: float) -> int: return int(floor((x - X0) / CELL))
func cj(z: float) -> int: return int(floor((z - Z0) / CELL))

func cell_type(x: float, z: float) -> int:
	var i := ci(x)
	var j := cj(z)
	if i < 0 or j < 0 or i >= nx or j >= nz:
		return WATER
	return mask[j * nx + i]

func _set_rect(r: Rect2, t: int) -> void:
	for j in range(maxi(0, cj(r.position.y)), mini(nz, cj(r.end.y - 0.01) + 1)):
		for i in range(maxi(0, ci(r.position.x)), mini(nx, ci(r.end.x - 0.01) + 1)):
			mask[j * nx + i] = t

func walkable(x: float, z: float) -> bool:
	return cell_type(x, z) != WATER

func on_route(x: float, z: float) -> bool:
	return absf(z - rc(x)) < RHW

func _street_at(x: float, z: float):
	var ck := Vector2i(int(floor(x / 50.0)), int(floor(z / 50.0)))
	var pc = per_chunk.get(ck)
	if pc == null:
		return null
	for s in pc.streets:
		if s.rect.has_point(Vector2(x, z)):
			return s
	return null

## Walking surface height (characters stand on it, skid marks sit on it).
func surface_y(x: float, z: float) -> float:
	var t := cell_type(x, z)
	if t == WATER:
		return SEA_Y
	if t == DOCK:
		return 0.02 if absf(x) > BRIDGE_X - 25.0 and on_route(x, z) else 0.25
	if on_route(x, z) or _street_at(x, z) != null:
		return 0.02
	if absf(x) < 206.0 and z > -112.0 and z < 118.0:
		return 0.15   # town blocks are sidewalk-level slabs
	return 0.05

## Tyre grip multiplier for the ground under a car.
func grip_at(x: float, z: float) -> float:
	var t := cell_type(x, z)
	if t == WATER:
		return 0.3
	if t == SAND:
		return 0.55
	if on_route(x, z) or absf(x) < TOWN or _street_at(x, z) != null or t == DOCK:
		return 1.0
	return 0.72

# ---------------------------------------------------------------- layout (startup)
func layout() -> void:
	var t0 := Time.get_ticks_msec()
	nx = int((X1 - X0) / CELL)
	nz = int((Z1 - Z0) / CELL)
	mask.resize(nx * nz)
	mask.fill(WATER)
	for i in nx:
		var x := X0 + (i + 0.5) * CELL
		var c := rc(x)
		var zn := c - north_w(x)
		var zs := c + south_w(x)
		var beach := _beach_zone(x)
		for j in nz:
			var z := Z0 + (j + 0.5) * CELL
			if z > zn and z < zs:
				mask[j * nx + i] = SAND if (beach and z > zs - 16.0) else LAND
	_bridges()
	_town()
	_strip()
	_canal_zones()
	_specials()
	for l in lots:
		_index(l, "lots", Vector2(l.rect.get_center().x, l.rect.get_center().y))
	for s in streets:
		_index_rect(s, "streets", s.rect)
	for m in marks:
		_index(m, "marks", Vector2(m.pos.x, m.pos.z))
	_build_map_image()
	print("Key Lento layout: %d lots, %d streets, %d landmarks in %d ms" % [lots.size(), streets.size(), marks.size(), Time.get_ticks_msec() - t0])

func _pc(ck: Vector2i) -> Dictionary:
	if not per_chunk.has(ck):
		per_chunk[ck] = {"lots": [], "streets": [], "marks": [], "basins": []}
	return per_chunk[ck]

func _index(item: Dictionary, key: String, at: Vector2) -> void:
	var ck := Vector2i(int(floor(at.x / 50.0)), int(floor(at.y / 50.0)))
	item["chunk"] = ck
	_pc(ck)[key].append(item)

## streets are long: list them in every chunk they touch (each chunk builds its own piece)
func _index_rect(item: Dictionary, key: String, r: Rect2) -> void:
	for cx in range(int(floor(r.position.x / 50.0)), int(floor((r.end.x - 0.01) / 50.0)) + 1):
		for cz in range(int(floor(r.position.y / 50.0)), int(floor((r.end.y - 0.01) / 50.0)) + 1):
			_pc(Vector2i(cx, cz))[key].append(item)

func chunk_keys() -> Array:
	var out := {}
	for i in nx:
		for j in nz:
			if mask[j * nx + i] != WATER:
				var x := X0 + (i + 0.5) * CELL
				var z := Z0 + (j + 0.5) * CELL
				out[Vector2i(int(floor(x / 50.0)), int(floor(z / 50.0)))] = true
	for ck in per_chunk:
		out[ck] = true
	return out.keys()

static func _beach_zone(x: float) -> bool:
	return (x > 470.0 and x < 640.0) or (x > -1080.0 and x < -960.0) or (x > 1080.0 and x < 1180.0)

func _bridges() -> void:
	# Route 1 leaves the key on bridges at both ends (closed for now)
	for x in range(int(BRIDGE_X - 30.0), int(X1), 5):
		for sx in [-1.0, 1.0]:
			var px: float = float(x) * sx
			_set_rect(Rect2(px - 2.5, rc(px) - RHW - 1.0, 5.0, RHW * 2.0 + 2.0), DOCK)

func _add_lot(r: Rect2, kind: String, face: Vector2, extra := {}) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + lots.size() * 7919
	var l := {"rect": r, "kind": kind, "face": face, "seed": rng.randi(), "color": col(PASTEL[rng.randi() % PASTEL.size()]),
		"floors": 1, "name": "", "cell": 0}
	l.merge(extra, true)
	# far-LOD + occluder volume, identical to what build_chunk will make
	match kind:
		"shop", "bar", "clinic", "center", "office":
			l.h = 4.2 + (l.floors - 1) * 3.4
			l.cell = 0 if l.floors > 1 else 4
		"house":
			l.h = 3.4 + (2.6 if l.get("stilt", false) else 0.0) + (l.floors - 1) * 3.0
			l.cell = 0
		"motel":
			l.h = 3.6
			l.cell = 0
		"gas":
			l.h = 4.6
			l.cell = 4
		"marina":
			l.h = 9.0
			l.cell = 2
		_:
			l.h = 0.0
	lots.append(l)
	return l

func _reserved(r: Rect2) -> bool:
	for q in RESERVED:
		if q.grow(1.5).intersects(r):
			return true
	return false

# ---- town grid around the robbery sites
func _town() -> void:
	for x in TOWN_X:
		streets.append({"rect": Rect2(x - RHW, -112.0, RHW * 2.0, 112.0 - RHW), "axis": "z"})
		streets.append({"rect": Rect2(x - RHW, RHW, RHW * 2.0, 118.0 - RHW), "axis": "z"})
	streets.append({"rect": Rect2(-206.0, TOWN_N - RHW, 412.0, RHW * 2.0), "axis": "x"})
	streets.append({"rect": Rect2(-206.0, TOWN_S - RHW, 412.0, RHW * 2.0), "axis": "x"})
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 11
	for k in TOWN_X.size() - 1:
		var xa: float = TOWN_X[k] + RHW + 3.0
		var xb: float = TOWN_X[k + 1] - RHW - 3.0
		var mid := (xa + xb) * 0.5
		# [z0, z1, face toward street (+1 = +z)]
		var rows := [[TOWN_N + RHW + 3.0, -RHW - 3.0], [RHW + 3.0, TOWN_S - RHW - 3.0], [-104.0, TOWN_N - RHW - 3.0], [TOWN_S + RHW + 3.0, 110.0]]
		for ri in rows.size():
			var z0: float = rows[ri][0]
			var z1: float = rows[ri][1]
			var outer := ri >= 2
			var depth := minf(20.0, (z1 - z0) * 0.5 - 1.0)
			# two lots on the street side of the block, two on the back side
			var halves := [[z1 - depth, z1, Vector2(0, 1)], [z0, z0 + depth, Vector2(0, -1)]] if not outer else [[z0, z0 + 18.0, Vector2(0, -1)] if ri == 3 else [z1 - 18.0, z1, Vector2(0, 1)]]
			for hz in halves:
				for sx in [[xa, mid - 1.5], [mid + 1.5, xb]]:
					var r := Rect2(sx[0], hz[0], sx[1] - sx[0], hz[1] - hz[0])
					if _reserved(r):
						continue
					var face: Vector2 = hz[2]
					if outer:
						_add_lot(r.grow(-1.0), "house", face, {"floors": 1 + int(rng.randf() < 0.4), "stilt": false})
					elif rng.randf() < 0.18:
						_add_lot(r, "parking", face)
					else:
						_add_lot(r, "shop", face, {"floors": 1 + int(rng.randf() < 0.55) + int(rng.randf() < 0.2), "sign": rng.randi() % 32})

# ---- roadside businesses along the rest of Route 1
func _strip() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 23
	for side in [-1.0, 1.0]:
		var x := -1180.0
		while x < 1180.0:
			var w := 18.0 + rng.randf() * 16.0
			if absf(x + w * 0.5) < TOWN + 10.0 or _special_x(x, w, side):
				x += w + 6.0
				continue
			var c := rc(x + w * 0.5)
			var depth := 16.0 + rng.randf() * 8.0
			var z0: float = c + side * (RHW + 4.0)
			var r := Rect2(x, minf(z0, z0 + side * depth), w, depth)
			# keep away from the shore
			var room: float = north_w(x + w * 0.5) if side < 0.0 else south_w(x + w * 0.5)
			if room > RHW + 6.0 + depth + 8.0 and walkable(r.get_center().x, r.get_center().y):
				var roll := rng.randf()
				var face := Vector2(0, -side)
				if roll < 0.42:
					_add_lot(r, "shop", face, {"floors": 1 + int(rng.randf() < 0.3), "sign": rng.randi() % 32})
				elif roll < 0.6:
					_add_lot(r, "house", face, {"floors": 1, "stilt": rng.randf() < 0.5})
				elif roll < 0.72:
					_add_lot(r, "parking", face)
				else:
					_add_lot(r, "trees", face)
			x += w + 4.0 + rng.randf() * 14.0

## x ranges used by hand-placed places (strip lots skip them)
const SPECIAL := [[-560.0, -400.0, -1], [-362.0, -300.0, -1], [-640.0, -560.0, 1], [-470.0, -410.0, 1], [-300.0, -262.0, -1],
	[300.0, 360.0, 1], [390.0, 460.0, -1], [470.0, 495.0, -1], [520.0, 640.0, 1], [650.0, 735.0, -1], [800.0, 860.0, -1],
	[880.0, 930.0, -1], [960.0, 1080.0, -1], [-800.0, -730.0, 1], [-885.0, -855.0, 1], [-1000.0, -930.0, 1], [-1200.0, -1150.0, -1],
	[-1200.0, -1150.0, 1]]
static func _special_x(x: float, w: float, side: float) -> bool:
	for s in SPECIAL:
		if s[2] == int(side) and x < s[1] and x + w > s[0]:
			return true
	for c in CANAL_ZONES:
		if int(c[2]) == int(side) and x < c[1] + 4.0 and x + w > c[0] - 4.0:
			return true
	return false

## Canal subdivisions: finger canals cut in from the shore with a street between each pair
## and stilt houses backing onto the water (each with a dock and usually a boat).
const CANAL_ZONES := [[-930.0, -660.0, -1.0], [700.0, 960.0, 1.0], [-1120.0, -1010.0, 1.0]]
func _canal_zones() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 37
	for zn in CANAL_ZONES:
		var a: float = zn[0]
		var b: float = zn[1]
		var side: float = zn[2]
		if b <= a:
			continue
		var cx := a + 10.0
		while cx + 70.0 <= b:
			var shore_c := rc(cx) + side * ((north_w(cx) if side < 0.0 else south_w(cx)) + 6.0)
			var inner := rc(cx) + side * 46.0
			var canal := Rect2(cx - 7.0, minf(shore_c, inner), 14.0, absf(shore_c - inner))
			_set_rect(canal, WATER)
			var sx := cx + 35.0
			var shore_s := rc(sx) + side * ((north_w(sx) if side < 0.0 else south_w(sx)) - 10.0)
			var st_r := Rect2(sx - 4.0, minf(rc(sx) + side * RHW, shore_s), 8.0, absf(shore_s - (rc(sx) + side * RHW)))
			streets.append({"rect": st_r, "axis": "z", "narrow": true})
			# houses both sides of the street, backing onto the canals
			var z := rc(sx) + side * (RHW + 6.0)
			while absf(z - shore_s) > 22.0:
				for hs in [-1.0, 1.0]:
					var hr := Rect2(sx + (4.5 if hs > 0.0 else -26.5), minf(z, z + side * 19.0), 22.0, 19.0)
					if walkable(hr.get_center().x, hr.get_center().y):
						var l := _add_lot(hr, "house", Vector2(-hs, 0), {"floors": 1 + int(rng.randf() < 0.3), "stilt": rng.randf() < 0.6, "dock": hs})
						l["canal_x"] = cx + 7.0 if hs < 0.0 else cx + 63.0
				z += side * 21.0
			cx += 70.0

## Hand-placed places from the real starting area.
func _specials() -> void:
	# Brian's Boat Works & Marina (bay side): basin, finger docks, boat racks, workshop.
	var bx := -500.0
	var bshore := rc(bx) - north_w(bx)
	var basin := Rect2(bx - 55.0, bshore - 10.0, 90.0, 48.0)
	_set_rect(basin, WATER)
	basins.append({"rect": basin, "side": -1.0, "name": "BRIAN'S BOAT WORKS & MARINA"})
	_add_lot(Rect2(bx - 55.0, basin.end.y + 2.0, 40.0, 22.0), "marina", Vector2(0, 1), {"name": "BRIAN'S BOAT WORKS", "brian": true})
	_add_lot(Rect2(bx - 10.0, basin.end.y + 2.0, 40.0, 18.0), "shop", Vector2(0, 1), {"floors": 1, "sign": 5, "name": "MARINA OFFICE"})
	streets.append({"rect": Rect2(bx + 34.0, rc(bx + 38.0) - north_w(bx) + 30.0, 8.0, north_w(bx) - 30.0 - RHW), "axis": "z", "narrow": true})
	# Jason's house: a stilt house out on the bay, reached by a long dock.
	var jx := -330.0
	var jshore := rc(jx) - north_w(jx)
	stilt_house = Rect2(jx - 9.0, jshore - 48.0, 18.0, 17.0)
	_set_rect(stilt_house.grow(2.0), DOCK)
	_set_rect(Rect2(jx - 1.5, jshore - 32.0, 3.0, 36.0), DOCK)
	marks.append({"kind": "stilt_house", "pos": Vector3(jx, 0, stilt_house.get_center().y), "yaw": 0.0, "rect": stilt_house})
	var drive_z := jshore + 6.0
	streets.append({"rect": Rect2(jx - 4.0, drive_z, 8.0, rc(jx) - RHW - drive_z), "axis": "z", "narrow": true})
	spawn = Vector3(jx, 0, stilt_house.get_center().y + 9.0)
	spawn_car = Vector3(jx + 5.5, 0, drive_z + 8.0)
	spawn_car_yaw = 0.0
	# Bars, motel, shops and services along the strip
	_add_lot(Rect2(410.0, rc(425.0) - RHW - 30.0, 36.0, 22.0), "bar", Vector2(0, 1), {"name": "THE RUSTY ANCHOR", "deck": -1.0})
	_add_lot(Rect2(-620.0, rc(-600.0) + RHW + 5.0, 34.0, 20.0), "bar", Vector2(0, -1), {"name": "CHEEKY MUTINEER"})
	_add_lot(Rect2(-296.0, rc(-281.0) - RHW - 26.0, 30.0, 20.0), "bar", Vector2(0, 1), {"name": "MARBLES"})
	_add_lot(Rect2(530.0, rc(580.0) + RHW + 5.0, 100.0, 40.0), "motel", Vector2(0, -1), {"name": "THE CAPTAIN'S CABINS"})
	_add_lot(Rect2(-460.0, rc(-440.0) + RHW + 5.0, 40.0, 30.0), "gas", Vector2(0, -1), {"name": "ARROW"})
	_add_lot(Rect2(885.0, rc(905.0) - RHW - 34.0, 40.0, 30.0), "gas", Vector2(0, 1), {"name": "ARROW"})
	_add_lot(Rect2(-790.0, rc(-765.0) + RHW + 5.0, 50.0, 26.0), "clinic", Vector2(0, -1), {"floors": 2, "name": "HAMILTON PRIVATE HEALTH CLINIC"})
	_add_lot(Rect2(805.0, rc(830.0) - RHW - 30.0, 50.0, 24.0), "center", Vector2(0, 1), {"floors": 1, "name": "DONOVAN ROEDER JR. COMMUNITY CENTER"})
	_add_lot(Rect2(305.0, rc(330.0) + RHW + 5.0, 50.0, 26.0), "office", Vector2(0, -1), {"floors": 2, "name": "LEONIDA KEYS SHERIFF", "police": true})
	_add_lot(Rect2(655.0, rc(680.0) - RHW - 26.0, 46.0, 20.0), "shop", Vector2(0, 1), {"floors": 1, "sign": 9, "name": "WONDER WHALE GIFTS"})
	marks.append({"kind": "whale", "pos": Vector3(720.0, 0, rc(720.0) - RHW - 9.0), "yaw": 0.0})
	marks.append({"kind": "tower", "pos": Vector3(-870.0, 0, rc(-870.0) + 40.0), "yaw": 0.0})
	marks.append({"kind": "tower", "pos": Vector3(480.0, 0, rc(480.0) - 42.0), "yaw": 0.0})
	marks.append({"kind": "sign", "pos": Vector3(-1175.0, 0, rc(-1175.0) - RHW - 5.0), "yaw": PI / 2, "text": "WELCOME TO THE KEYS"})
	marks.append({"kind": "sign", "pos": Vector3(-960.0, 0, rc(-960.0) + RHW + 5.0), "yaw": -PI / 2, "text": "KEY LENTO"})
	marks.append({"kind": "barrier", "pos": Vector3(-1282.0, 0, rc(-1282.0)), "yaw": 0.0, "text": "BRIDGE CLOSED"})
	marks.append({"kind": "barrier", "pos": Vector3(1282.0, 0, rc(1282.0)), "yaw": 0.0, "text": "BRIDGE CLOSED"})
	# Key Lento Marina Club (bay side, east)
	var mx := 1015.0
	var mshore := rc(mx) - north_w(mx)
	var mb := Rect2(mx - 40.0, mshore - 10.0, 80.0, 40.0)
	_set_rect(mb, WATER)
	basins.append({"rect": mb, "side": -1.0, "name": "KEY LENTO MARINA CLUB"})
	_add_lot(Rect2(mx - 25.0, mb.end.y + 2.0, 50.0, 20.0), "shop", Vector2(0, 1), {"floors": 2, "sign": 14, "name": "KEY LENTO MARINA CLUB"})
	streets.append({"rect": Rect2(mx + 42.0, mb.end.y, 8.0, rc(mx + 46.0) - RHW - mb.end.y), "axis": "z", "narrow": true})

## One HeightMapShape3D for the whole key: land at 0, sea bed at -3 (2.5 m samples).
## A single seamless surface means no "ghost" bumps where per-chunk boxes would meet -
## at 45 m/s a car's flat underside can catch a box seam and get launched.
func ground_shape() -> CollisionShape3D:
	var step := 2.5
	var w := int((X1 - X0) / step) + 1
	var d := int((Z1 - Z0) / step) + 1
	var data := PackedFloat32Array()
	data.resize(w * d)
	for j in d:
		for i in w:
			var x := X0 + i * step
			var z := Z0 + j * step
			var land := walkable(x - 0.01, z - 0.01) or walkable(x + 0.01, z - 0.01) or walkable(x - 0.01, z + 0.01) or walkable(x + 0.01, z + 0.01)
			data[j * w + i] = 0.0 if land else -3.0 / step
	var hm := HeightMapShape3D.new()
	hm.map_width = w
	hm.map_depth = d
	hm.map_data = data
	var cs := CollisionShape3D.new()
	cs.shape = hm
	cs.scale = Vector3(step, step, step)
	cs.position = Vector3((X0 + X1) * 0.5, 0, (Z0 + Z1) * 0.5)
	return cs

# ---------------------------------------------------------------- map image
func _build_map_image() -> void:
	var small := Image.create(nx, nz, false, Image.FORMAT_RGB8)
	var colors := [Color("1c4054"), Color("33463a"), Color("b7a77d"), Color("6b5a44")]
	for j in nz:
		for i in nx:
			small.set_pixel(i, j, colors[mask[j * nx + i]])
	var w := int((X1 - X0) * MAP_PX)
	var h := int((Z1 - Z0) * MAP_PX)
	small.resize(w, h, Image.INTERPOLATE_BILINEAR)
	map_image = small
	var road := Color("5b6168")
	for xi in w:
		var x := X0 + (xi + 0.5) / MAP_PX
		if absf(x) > X1 - 10.0:
			continue
		var c := rc(x)
		var z0 := int((c - RHW - Z0) * MAP_PX)
		map_image.fill_rect(Rect2i(xi, z0, 1, int(RHW * 2.0 * MAP_PX)), road)
	for s in streets:
		var r: Rect2 = s.rect
		map_image.fill_rect(Rect2i(int((r.position.x - X0) * MAP_PX), int((r.position.y - Z0) * MAP_PX), int(r.size.x * MAP_PX), int(r.size.y * MAP_PX)), road)
	for l in lots:
		if l.h <= 0.0:
			continue
		var r: Rect2 = _footprint(l)
		map_image.fill_rect(Rect2i(int((r.position.x - X0) * MAP_PX), int((r.position.y - Z0) * MAP_PX), maxi(1, int(r.size.x * MAP_PX)), maxi(1, int(r.size.y * MAP_PX))), Color("59616b"))

## the building footprint inside a lot (setback from the street)
func _footprint(l: Dictionary) -> Rect2:
	var r: Rect2 = l.rect
	match l.kind:
		"house":
			return Rect2(r.get_center().x - 5.5, r.get_center().y - 4.5, 11.0, 9.0)
		"gas":
			var f: Vector2 = l.face
			return Rect2(r.get_center().x - 7.0, r.get_center().y - 4.0 - f.y * 8.0, 14.0, 8.0)
		"motel":
			return r.grow(-6.0)
		"marina":
			return r.grow(-2.0)
		_:
			return r.grow(-1.0)

## Far-LOD boxes and ground for the streamer + occluders (called once, after layout()).
func fill_far(B: MeshBuilder) -> void:
	for l in lots:
		if l.h <= 0.0:
			continue
		var fp := _footprint(l)
		var y0 := 2.6 if l.get("stilt", false) else 0.0
		B.building_volume(Vector3(fp.position.x, y0, fp.position.y), Vector3(fp.end.x, l.h, fp.end.y), l.cell, l.color, 4.2 if l.cell == 0 and l.kind != "house" else 0.0, 99.0 if l.h < 6.5 else 0.0)
	# ground: merge mask rows per chunk into strips
	var colors := {LAND: Color(0.3, 0.42, 0.24), SAND: Color(0.76, 0.69, 0.53), DOCK: Color(0.45, 0.35, 0.25)}
	for j in nz:
		var i := 0
		while i < nx:
			var t := mask[j * nx + i]
			if t == WATER:
				i += 1
				continue
			var i0 := i
			var cx0 := int(floor((X0 + i * CELL) / 50.0))
			while i < nx and mask[j * nx + i] == t and int(floor((X0 + i * CELL) / 50.0)) == cx0:
				i += 1
			B.far_ground.append({"rect": Rect2(X0 + i0 * CELL, Z0 + j * CELL, (i - i0) * CELL, CELL), "y": 0.0 if t != DOCK else 0.2, "color": colors[t]})
	for xi in range(int(X0 + 10.0), int(X1 - 10.0), 10):
		var x := float(xi)
		B.far_ground.append({"rect": Rect2(x, rc(x + 5.0) - RHW, 10.0, RHW * 2.0), "y": 0.03, "color": Color(0.2, 0.2, 0.21)})

# ================================================================= chunk geometry
## Builds everything anchored in chunk ck into B (a detached, thread-local MeshBuilder).
## Returns extra things the main thread must create: Label3D texts.
func build_chunk(B: MeshBuilder, ck: Vector2i) -> Dictionary:
	var out := {"labels": []}
	B.force_chunk = ck
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(ck) ^ SEED
	_ground(B, ck)
	_route(B, ck, rng)
	town_block_slab(B, ck)
	var pc = per_chunk.get(ck)
	if pc != null:
		for s in pc.streets:
			_street(B, s, ck)
		for l in pc.lots:
			var lr := RandomNumberGenerator.new()
			lr.seed = l.seed
			_lot(B, l, lr, out)
		for m in pc.marks:
			_mark(B, m, rng, out)
	_scatter(B, ck, rng)
	B.force_chunk = null
	return out

# ---- land, seawalls, docks, character shore walls
func _ground(B: MeshBuilder, ck: Vector2i) -> void:
	var i0 := maxi(0, ci(ck.x * 50.0))
	var i1 := mini(nx, ci(ck.x * 50.0 + 49.99) + 1)
	var j0 := maxi(0, cj(ck.y * 50.0))
	var j1 := mini(nz, cj(ck.y * 50.0 + 49.99) + 1)
	if i1 <= i0 or j1 <= j0:
		return
	var grass := Mats.m("grass")
	var sand := Mats.m("sand")
	var conc := Mats.m("concrete")
	var wood := Mats.m("wood_planks")
	for t in [LAND, SAND, DOCK]:
		# greedy rectangles of equal cells
		var used := {}
		for j in range(j0, j1):
			for i in range(i0, i1):
				if used.has(Vector2i(i, j)) or mask[j * nx + i] != t:
					continue
				var w := 1
				while i + w < i1 and mask[j * nx + i + w] == t and not used.has(Vector2i(i + w, j)):
					w += 1
				var h := 1
				var ok := true
				while j + h < j1 and ok:
					for k in w:
						if mask[(j + h) * nx + i + k] != t or used.has(Vector2i(i + k, j + h)):
							ok = false
							break
					if ok:
						h += 1
				for jj in h:
					for ii in w:
						used[Vector2i(i + ii, j + jj)] = true
				var x := X0 + i * CELL
				var z := Z0 + j * CELL
				var rw := w * CELL
				var rd := h * CELL
				if t == DOCK:
					var top := 0.0 if absf(x + rw * 0.5) > BRIDGE_X - 25.0 else 0.25
					B.box(x + rw * 0.5, top - 0.3, z + rd * 0.5, rw, 0.3, rd, wood if top > 0.1 else conc, {"layer": "ground", "lod": "main", "color": Color(0.95, 0.9, 0.85)})
					var px := x + 1.0
					while px < x + rw:
						var pz := z + 1.0
						while pz < z + rd:
							B.cylinder(px, -1.4, pz, 0.14, 1.2 + top, wood, Color(0.6, 0.5, 0.4), 6, -1.0, {"lod": "detail"})
							pz += 4.0
						px += 4.0
				else:
					# visual only: cars drive on one seamless heightfield (see ground_shape())
					B.box(x + rw * 0.5, -1.4, z + rd * 0.5, rw, 1.4, rd, grass if t == LAND else sand, {"layer": "ground", "lod": "main", "collide": false})
	# seawalls (concrete caps) + walls only people collide with, along every land/water edge
	for j in range(j0, j1):
		for i in range(i0, i1):
			var t := mask[j * nx + i]
			if t == WATER:
				continue
			var x := X0 + i * CELL
			var z := Z0 + j * CELL
			for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
				var ni: int = i + d[0]
				var nj: int = j + d[1]
				var nt := WATER if (ni < 0 or nj < 0 or ni >= nx or nj >= nz) else mask[nj * nx + ni]
				if nt != WATER:
					continue
				var ex := x + (CELL if d[0] > 0 else 0.0) if d[0] != 0 else x + CELL * 0.5
				var ez := z + (CELL if d[1] > 0 else 0.0) if d[1] != 0 else z + CELL * 0.5
				var sw := 0.5 if d[0] != 0 else CELL
				var sd := CELL if d[0] != 0 else 0.5
				if t == LAND:
					B.box(ex - d[0] * 0.25, -0.9, ez - d[1] * 0.25, sw, 1.0, sd, conc, {"collide": false, "lod": "main", "color": Color(0.82, 0.8, 0.74)})
				elif t == DOCK:
					B.box(ex - d[0] * 0.05, 0.25, ez - d[1] * 0.05, sw if d[0] == 0 else 0.1, 0.9, sd if d[1] == 0 else 0.1, wood, {"collide": false, "lod": "detail", "color": Color(0.85, 0.8, 0.72)})
				B.add_col(Vector3(ex - sw * 0.5, 0.0, ez - sd * 0.5), Vector3(ex + sw * 0.5, 2.0, ez + sd * 0.5), {"layer": "shore"})

# ---- Route 1: asphalt, lane markings, shoulders, bridge rails
func _route(B: MeshBuilder, ck: Vector2i, rng: RandomNumberGenerator) -> void:
	var xa := ck.x * 50.0
	var asph := Mats.m("asphalt")
	var yel := Mats.m("line_yellow")
	var wht := Mats.m("line_white")
	var conc := Mats.m("concrete")
	var x := xa
	while x < xa + 50.0 - 0.01:
		var seg := 10.0
		var m := x + seg * 0.5
		if m < X0 + 2.0 or m > X1 - 2.0:
			x += seg
			continue
		var c0 := rc(x)
		var c1 := rc(x + seg)
		var cz := (c0 + c1) * 0.5
		if int(floor(cz / 50.0)) != ck.y:
			x += seg
			continue
		var ang := atan2(c1 - c0, seg)
		var len := sqrt(seg * seg + (c1 - c0) * (c1 - c0)) + 0.05
		var basis := Basis(Vector3.UP, -ang) if absf(ang) > 0.001 else Basis.IDENTITY
		var bridge := absf(m) > BRIDGE_X - 2.0
		var opts := {"collide": false, "lod": "main", "basis": basis} if basis != Basis.IDENTITY else {"collide": false, "lod": "main"}
		B.box(m, -0.02, cz, len, 0.04, RHW * 2.0, asph, opts)
		var lo := opts.duplicate()
		lo["shadow"] = false
		var nrm := Vector3(-sin(ang), 0, cos(ang))
		for o in [-0.12, 0.12]:
			var p: Vector3 = Vector3(m, 0, cz) + nrm * o
			B.box(p.x, 0.02, p.z, len, 0.01, 0.1, yel, lo)
		if posmod(int(m), 20) < 10:
			for o in [-3.0, 3.0]:
				var p: Vector3 = Vector3(m, 0, cz) + nrm * o
				B.box(p.x, 0.02, p.z, len * 0.5, 0.01, 0.12, wht, lo)
		for o in [-RHW + 0.3, RHW - 0.3]:
			var p: Vector3 = Vector3(m, 0, cz) + nrm * o
			B.box(p.x, 0.02, p.z, len, 0.01, 0.12, wht, lo)
		if bridge:
			for o in [-RHW - 0.4, RHW + 0.4]:
				var p: Vector3 = Vector3(m, 0, cz) + nrm * o
				var ro := opts.duplicate()
				ro["collide"] = false
				B.box(p.x, 0.0, p.z, len, 0.9, 0.5, conc, ro)
				B.add_col(Vector3(m - seg * 0.5, 0.0, p.z - 0.3), Vector3(m + seg * 0.5, 1.0, p.z + 0.3))
			if posmod(int(m), 40) < 10:
				for o in [-4.0, 4.0]:
					var p: Vector3 = Vector3(m, 0, cz) + nrm * o
					B.box(p.x, -6.0, p.z, 1.6, 4.8, 1.6, conc, {"collide": false, "lod": "mid"})
		elif absf(m) >= TOWN:
			# road over land: physical surface is the land itself; lamps + utility poles
			if posmod(int(m), 40) < 10:
				var s := 1.0 if posmod(int(floor(m / 40.0)), 2) == 0 else -1.0
				var p := Vector3(m, 0, cz) + nrm * s * (RHW + 1.6)
				_lamp(B, p.x, p.z, -nrm * s)
			if posmod(int(m + 20.0), 60) < 10:
				var p := Vector3(m, 0, cz) - nrm * (RHW + 3.5)
				_pole(B, p.x, p.z)
		x += seg

func _street(B: MeshBuilder, s: Dictionary, ck: Vector2i) -> void:
	var r: Rect2 = s.rect
	var cr := Rect2(ck.x * 50.0, ck.y * 50.0, 50.0, 50.0)
	if not r.intersects(cr):
		return
	var p := r.intersection(cr)
	var asph := Mats.m("asphalt")
	B.box(p.get_center().x, -0.02, p.get_center().y, p.size.x, 0.04, p.size.y, asph, {"collide": false, "lod": "main"})
	var lo := {"collide": false, "shadow": false, "lod": "main"}
	if not s.get("narrow", false):
		if s.axis == "z":
			B.box(p.get_center().x, 0.02, p.get_center().y, 0.12, 0.01, p.size.y, Mats.m("line_yellow"), lo)
		else:
			B.box(p.get_center().x, 0.02, p.get_center().y, p.size.x, 0.01, 0.12, Mats.m("line_yellow"), lo)

# ---- lots
func _lot(B: MeshBuilder, l: Dictionary, rng: RandomNumberGenerator, out: Dictionary) -> void:
	match l.kind:
		"shop", "clinic", "center", "office":
			_shop(B, l, rng, out)
		"house":
			_house(B, l, rng)
		"motel":
			_motel(B, l, rng, out)
		"gas":
			_gas(B, l, rng, out)
		"bar":
			_bar(B, l, rng, out)
		"marina":
			_marina(B, l, rng, out)
		"parking":
			_parking(B, l, rng)
		"trees":
			for k in 5:
				_palm(B, l.rect.position.x + rng.randf() * l.rect.size.x, l.rect.position.y + rng.randf() * l.rect.size.y, 6.0 + rng.randf() * 4.0, rng)

## town blocks get their sidewalk slab from the first lot in the block
func town_block_slab(B: MeshBuilder, ck: Vector2i) -> void:
	if absf(ck.x * 50.0 + 25.0) > TOWN:
		return
	var walk := Mats.m("sidewalk")
	for k in TOWN_X.size() - 1:
		var xa: float = TOWN_X[k] + RHW
		var xb: float = TOWN_X[k + 1] - RHW
		if int(floor((xa + xb) * 0.5 / 50.0)) != ck.x:
			continue
		for zr in [[TOWN_N + RHW, -RHW], [RHW, TOWN_S - RHW], [-112.0, TOWN_N - RHW], [TOWN_S + RHW, 118.0]]:
			var zc: float = (zr[0] + zr[1]) * 0.5
			if int(floor(zc / 50.0)) != ck.y:
				continue
			B.box((xa + xb) * 0.5, 0.0, zc, xb - xa, 0.15, zr[1] - zr[0], walk, {"layer": "ground", "shadow": false, "lod": "main"})
			# lamps + palms on the block edges along Route 1
			if absf(zr[1]) < 7.0 or absf(zr[0]) < 7.0:
				var ez: float = -RHW - 1.4 if zr[1] < 0.0 else RHW + 1.4
				var x := xa + 6.0
				var n := 0
				while x < xb - 3.0:
					if not _near_reserved(x, ez):
						if n % 2 == 0:
							_lamp(B, x, ez, Vector3(0, 0, signf(-ez)))
						else:
							_palm_seeded(B, x, ez - signf(ez) * 0.4, 7.0 + float(n % 3))
					x += 12.5
					n += 1

func _near_reserved(x: float, z: float) -> bool:
	for q in RESERVED:
		if q.grow(2.0).has_point(Vector2(x, z)):
			return true
	return false

func _facing_yaw(face: Vector2) -> float:
	return atan2(face.x, face.y)

func _shop(B: MeshBuilder, l: Dictionary, rng: RandomNumberGenerator, out: Dictionary) -> void:
	var fp := _footprint(l)
	var cx := fp.get_center().x
	var cz := fp.get_center().y
	var w := fp.size.x
	var d := fp.size.y
	var floors: int = l.floors
	var color: Color = l.color
	var paint := Mats.m("paint")
	B.box(cx, 0, cz, w, 4.2, d, Mats.m("shopfront"), {"color": Color(0.95, 0.94, 0.92), "collide": false})
	B.box(cx, 4.0, cz, w + 0.3, 0.3, d + 0.3, paint, {"color": Color(0.97, 0.96, 0.93), "collide": false})
	var top := 4.2
	if floors > 1:
		B.box(cx, 4.2, cz, w, (floors - 1) * 3.4, d, Mats.m("facade_stucco"), {"color": color, "collide": false})
		top = 4.2 + (floors - 1) * 3.4
	B.box(cx, top - 0.1, cz, w + 0.5, 0.45, d + 0.5, paint, {"color": Color(0.98, 0.97, 0.94), "collide": false})
	B.box(cx, top, cz, w, 0.1, d, Mats.m("roof_gravel"), {"collide": false})
	B.add_col(Vector3(fp.position.x, 0, fp.position.y), Vector3(fp.end.x, top, fp.end.y))
	# AC units on the roof
	for k in 1 + rng.randi() % 3:
		B.box(cx + (rng.randf() - 0.5) * (w - 3), top, cz + (rng.randf() - 0.5) * (d - 3), 1.5, 1.0, 1.1, paint, {"color": Color(0.73, 0.74, 0.76), "collide": false})
	# street side: awning + sign
	var f: Vector2 = l.face
	var yaw := _facing_yaw(f)
	var edge := Vector3(cx + f.x * (w * 0.5), 0, cz + f.y * (d * 0.5))
	var along := absf(f.y) > 0.5
	var aw := (w if along else d) - 2.0
	if rng.randf() < 0.75:
		var basis := Basis(Vector3.RIGHT, -f.y * 0.32) if along else Basis(Vector3.BACK, f.x * 0.32)
		var p := edge + Vector3(f.x, 0, f.y) * 0.85
		B.box(p.x, 2.78, p.z, aw if along else 1.7, 0.14, 1.7 if along else aw, Mats.m("awning"), {"basis": basis, "color": col(AWNING[rng.randi() % AWNING.size()]), "collide": false})
	var name: String = l.get("name", "")
	if name != "":
		out.labels.append({"text": name, "pos": edge + Vector3(f.x, 0, f.y) * 0.12 + Vector3(0, top - 1.2 if floors > 1 else 3.6, 0), "yaw": yaw, "size": 0.9, "color": Color("fff4d6")})
	else:
		var sp := edge + Vector3(f.x, 0, f.y) * 0.09 + Vector3(0, 3.55, 0)
		var sw := minf(4.0, aw - 1.0)
		var idx: int = l.get("sign", 0)
		B.quad(sp, sw, sw / 4.0, yaw, Mats.m("signs"), Vector2((idx % 4) / 4.0, (idx / 4) / 8.0), Vector2((idx % 4 + 1) / 4.0, (idx / 4 + 1) / 8.0))
	# a couple of parking spots + planters out front
	var front := edge + Vector3(f.x, 0, f.y) * 3.0
	if absf(cx) > TOWN:
		_palm(B, front.x + (-aw * 0.5 if along else 0.0), front.z + (0.0 if along else -aw * 0.5), 6.5 + rng.randf() * 3.0, rng)

func _house(B: MeshBuilder, l: Dictionary, rng: RandomNumberGenerator) -> void:
	var fp := _footprint(l)
	var cx := fp.get_center().x
	var cz := fp.get_center().y
	var w := fp.size.x
	var d := fp.size.y
	var stilt: bool = l.get("stilt", false)
	var y0 := 2.6 if stilt else 0.0
	var floors: int = l.floors
	var body_h := 3.0 * floors + 0.4
	var paint := Mats.m("paint")
	var wood := Mats.m("wood_planks")
	var color: Color = l.color
	if stilt:
		for sx in [-1.0, 0.0, 1.0]:
			for sz in [-1.0, 1.0]:
				B.box(cx + sx * (w * 0.5 - 0.3), 0, cz + sz * (d * 0.5 - 0.3), 0.35, y0, 0.35, paint, {"color": Color(0.92, 0.92, 0.9), "collide": false})
		B.add_col(Vector3(fp.position.x, 0, fp.position.y), Vector3(fp.end.x, 1.9, fp.end.y), {"solid": false})
		# stairs up to the porch
		var f: Vector2 = l.face
		var sp := Vector3(cx + f.x * (w * 0.5 + 1.6), 0, cz + f.y * (d * 0.5 + 1.6))
		for k in 6:
			B.box(sp.x - f.x * k * 0.3, k * 0.42, sp.z - f.y * k * 0.3, 1.2 if absf(f.y) > 0.5 else 0.5, 0.12, 0.5 if absf(f.y) > 0.5 else 1.2, wood, {"collide": false, "lod": "detail"})
	B.box(cx, y0, cz, w, body_h, d, Mats.m("facade_stucco"), {"color": color, "collide": false, "tile": Vector2(4.0, 3.0)})
	B.add_col(Vector3(fp.position.x, y0, fp.position.y), Vector3(fp.end.x, y0 + body_h, fp.end.y))
	if not stilt:
		B.add_col(Vector3(fp.position.x, 0, fp.position.y), Vector3(fp.end.x, body_h, fp.end.y))
	# gable roof: two sloped slabs along the long side
	var rc_ := col(ROOFS[rng.randi() % ROOFS.size()])
	var top := y0 + body_h
	var long_x := w >= d
	var span := (d if long_x else w) * 0.5 + 0.5
	var slope := 0.5
	var rise := span * tan(slope)
	for s in [-1.0, 1.0]:
		var basis := Basis(Vector3.RIGHT, s * slope) if long_x else Basis(Vector3.BACK, -s * slope)
		var off: float = span * 0.5 * s
		var p := Vector3(cx + (0.0 if long_x else off), top + rise * 0.5 - 0.15, cz + (off if long_x else 0.0))
		B.box(p.x, p.y, p.z, (w + 0.8) if long_x else (span / cos(slope) + 0.1), 0.16, (span / cos(slope) + 0.1) if long_x else (d + 0.8), paint, {"basis": basis, "color": rc_, "collide": false})
	# porch / deck
	var f2: Vector2 = l.face
	var pp := Vector3(cx + f2.x * (w * 0.5 + 1.0), y0, cz + f2.y * (d * 0.5 + 1.0))
	B.box(pp.x, y0, pp.z, (w if absf(f2.y) > 0.5 else 2.0), 0.15, (2.0 if absf(f2.y) > 0.5 else d), wood, {"collide": false, "lod": "detail"})
	# canal dock + boat
	if l.has("canal_x"):
		var cxe: float = l.canal_x
		var into := 1.0 if l.dock > 0.0 else -1.0
		B.box(cxe + into * 1.3, 0.0, cz, 2.6, 0.25, 12.0, wood, {"collide": false, "lod": "detail"})
		if rng.randf() < 0.7:
			_boat(B, Vector3(cxe + into * 4.2, 0, cz), 0.0, 6.0 + rng.randf() * 3.0, rng)
	# yard palm
	if rng.randf() < 0.6:
		_palm(B, fp.position.x - 2.0, fp.position.y + rng.randf() * d, 5.5 + rng.randf() * 3.0, rng)

func _motel(B: MeshBuilder, l: Dictionary, rng: RandomNumberGenerator, out: Dictionary) -> void:
	var r: Rect2 = l.rect
	var f: Vector2 = l.face
	var wood := Mats.m("wood_planks")
	var paint := Mats.m("paint")
	var n := 7
	for k in n:
		var cx := r.position.x + 8.0 + k * (r.size.x - 16.0) / (n - 1)
		var cz := r.get_center().y + 6.0
		var c := col(PASTEL[(k * 3 + 1) % PASTEL.size()])
		B.box(cx, 0.4, cz, 7.0, 3.0, 7.0, Mats.m("facade_stucco"), {"color": c, "collide": false})
		B.box(cx, 0, cz, 7.4, 0.4, 7.4, wood, {"collide": false})
		B.add_col(Vector3(cx - 3.5, 0, cz - 3.5), Vector3(cx + 3.5, 3.4, cz + 3.5))
		for s in [-1.0, 1.0]:
			B.box(cx, 3.6, cz + s * 1.8, 8.0, 0.14, 4.0, paint, {"basis": Basis(Vector3.RIGHT, s * 0.45), "color": Color(0.85, 0.82, 0.74), "collide": false})
	out.labels.append({"text": l.name, "pos": Vector3(r.get_center().x, 5.0, r.position.y + (0.5 if f.y < 0.0 else r.size.y - 0.5)), "yaw": _facing_yaw(f), "size": 1.3, "color": Color("ffd27a")})
	B.box(r.get_center().x, 0, r.position.y + (1.0 if f.y < 0.0 else r.size.y - 1.0), 0.3, 4.4, 0.3, Mats.m("metal_brushed"), {"collide": false})
	for k in 4:
		_palm(B, r.position.x + rng.randf() * r.size.x, r.get_center().y - 6.0 + rng.randf() * 4.0, 7.0 + rng.randf() * 3.0, rng)

func _gas(B: MeshBuilder, l: Dictionary, rng: RandomNumberGenerator, out: Dictionary) -> void:
	var r: Rect2 = l.rect
	var f: Vector2 = l.face
	var paint := Mats.m("paint")
	var cx := r.get_center().x
	var cz := r.get_center().y
	B.box(cx, 0.0, cz, r.size.x, 0.12, r.size.y, Mats.m("concrete"), {"collide": false, "layer": "ground", "lod": "main", "color": Color(0.8, 0.8, 0.78)})
	# canopy on four columns over the pumps
	var pz := cz + f.y * 5.0
	B.box(cx, 4.6, pz, 18.0, 0.6, 9.0, paint, {"color": Color(0.96, 0.96, 0.96), "collide": false})
	B.box(cx, 4.5, pz, 18.2, 0.25, 9.2, paint, {"color": Color("e2434b"), "collide": false})
	for sx in [-7.0, 7.0]:
		for sz in [-3.0, 3.0]:
			B.box(cx + sx, 0, pz + sz, 0.4, 4.6, 0.4, paint, {"color": Color(0.95, 0.95, 0.95), "collide": false})
			B.add_col(Vector3(cx + sx - 0.25, 0, pz + sz - 0.25), Vector3(cx + sx + 0.25, 4.6, pz + sz + 0.25))
	for sx in [-3.5, 3.5]:
		B.box(cx + sx, 0.1, pz, 1.0, 1.7, 0.6, paint, {"color": Color(0.9, 0.2, 0.22), "collide": false})
		B.add_col(Vector3(cx + sx - 0.6, 0, pz - 0.4), Vector3(cx + sx + 0.6, 1.8, pz + 0.4))
	# little mart at the back
	var fp := _footprint(l)
	B.box(fp.get_center().x, 0, fp.get_center().y, fp.size.x, 4.0, fp.size.y, Mats.m("shopfront"), {"color": Color(0.95, 0.95, 0.95), "collide": false})
	B.box(fp.get_center().x, 4.0, fp.get_center().y, fp.size.x + 0.3, 0.3, fp.size.y + 0.3, paint, {"color": Color("e2434b"), "collide": false})
	B.add_col(Vector3(fp.position.x, 0, fp.position.y), Vector3(fp.end.x, 4.3, fp.end.y))
	# price sign pole by the road
	var sp := Vector3(r.position.x + 2.0, 0, cz + f.y * (r.size.y * 0.5 - 1.0))
	B.box(sp.x, 0, sp.z, 0.3, 6.0, 0.3, Mats.m("metal_brushed"), {"collide": false})
	B.box(sp.x, 6.0, sp.z, 0.4, 2.0, 2.4, paint, {"color": Color("e2434b"), "collide": false})
	out.labels.append({"text": l.name, "pos": Vector3(cx, 4.6, pz + f.y * 4.62), "yaw": _facing_yaw(f), "size": 1.4, "color": Color.WHITE})

func _bar(B: MeshBuilder, l: Dictionary, rng: RandomNumberGenerator, out: Dictionary) -> void:
	var fp := _footprint(l)
	var cx := fp.get_center().x
	var cz := fp.get_center().y
	var wood := Mats.m("wood_planks")
	var paint := Mats.m("paint")
	B.box(cx, 0, cz, fp.size.x, 3.8, fp.size.y, wood, {"color": Color(0.75, 0.6, 0.45), "collide": false})
	B.add_col(Vector3(fp.position.x, 0, fp.position.y), Vector3(fp.end.x, 3.8, fp.end.y))
	# thatched / tin roof
	for s in [-1.0, 1.0]:
		B.box(cx, 4.3, cz + s * fp.size.y * 0.25, fp.size.x + 1.4, 0.2, fp.size.y * 0.55, paint, {"basis": Basis(Vector3.RIGHT, s * 0.35), "color": Color("b89a6a"), "collide": false})
	var f: Vector2 = l.face
	var deck_side: float = l.get("deck", -f.y)
	var dz := cz + deck_side * (fp.size.y * 0.5 + 4.0)
	B.box(cx, 0.0, dz, fp.size.x, 0.3, 8.0, wood, {"collide": false, "layer": "ground", "lod": "main"})
	for k in 5:
		var tx := fp.position.x + 3.0 + k * (fp.size.x - 6.0) / 4.0
		B.cylinder(tx, 0.3, dz, 0.5, 0.75, wood, Color.WHITE, 8, -1.0, {"lod": "detail"})
		B.cylinder(tx, 1.05, dz, 0.05, 1.6, Mats.m("metal_brushed"), Color.WHITE, 4, -1.0, {"lod": "detail"})
		B.cylinder(tx, 2.6, dz, 1.4, 0.5, paint, col(AWNING[k % AWNING.size()]), 8, 0.0, {"lod": "detail"})
	out.labels.append({"text": l.name, "pos": Vector3(cx, 3.2, cz + f.y * (fp.size.y * 0.5 + 0.12)), "yaw": _facing_yaw(f), "size": 1.0, "color": Color("ffd27a")})
	_palm(B, fp.position.x - 2.5, cz, 8.0, rng)
	_palm(B, fp.end.x + 2.5, cz + 2.0, 7.0, rng)

func _marina(B: MeshBuilder, l: Dictionary, rng: RandomNumberGenerator, out: Dictionary) -> void:
	var fp := _footprint(l)
	var metal := Mats.m("metal_brushed")
	var paint := Mats.m("paint")
	# dry-stack boat racks (open steel frame with boats on the shelves)
	var cx := fp.get_center().x
	var cz := fp.get_center().y
	B.box(cx, 0, cz, fp.size.x, 0.1, fp.size.y, Mats.m("concrete"), {"collide": false, "layer": "ground", "lod": "main"})
	for k in 6:
		var x := fp.position.x + 2.0 + k * (fp.size.x - 4.0) / 5.0
		for s in [-1.0, 1.0]:
			B.box(x, 0, cz + s * 3.5, 0.3, 9.0, 0.3, metal, {"collide": false})
	B.add_col(Vector3(fp.position.x, 0, cz - 3.8), Vector3(fp.end.x, 9.0, cz + 3.8))
	for lvl in 3:
		B.box(cx, 2.2 + lvl * 2.8, cz, fp.size.x, 0.2, 7.4, metal, {"collide": false})
		for k in 5:
			var x := fp.position.x + 4.0 + k * (fp.size.x - 8.0) / 4.0
			_boat(B, Vector3(x, 2.4 + lvl * 2.8, cz), PI / 2, 6.0, rng)
	B.box(cx, 9.0, cz, fp.size.x + 0.6, 0.2, 8.4, paint, {"color": Color(0.85, 0.87, 0.88), "collide": false})
	out.labels.append({"text": l.name, "pos": Vector3(cx, 7.6, cz + 4.0), "yaw": 0.0, "size": 1.6, "color": Color("7fd4ff")})
	# finger docks in the basin + moored boats
	for bs in basins:
		var br: Rect2 = bs.rect
		if br.get_center().distance_to(fp.get_center()) > 80.0:
			continue
		var wood := Mats.m("wood_planks")
		B.box(br.get_center().x, 0.0, br.end.y - 1.5, br.size.x - 4.0, 0.25, 3.0, wood, {"collide": false, "lod": "main"})
		var k := 0
		var x := br.position.x + 8.0
		while x < br.end.x - 6.0:
			B.box(x, 0.0, br.end.y - 12.0, 1.8, 0.25, 18.0, wood, {"collide": false, "lod": "main"})
			if k % 2 == 0 or rng.randf() < 0.5:
				_boat(B, Vector3(x + 3.2, 0, br.end.y - 12.0), 0.0, 8.0 + rng.randf() * 4.0, rng)
			x += 9.0
			k += 1

func _parking(B: MeshBuilder, l: Dictionary, rng: RandomNumberGenerator) -> void:
	var r: Rect2 = l.rect
	B.box(r.get_center().x, 0.0, r.get_center().y, r.size.x, 0.06, r.size.y, Mats.m("asphalt"), {"collide": false, "lod": "main"})
	var x := r.position.x + 2.5
	while x < r.end.x - 1.0:
		B.box(x, 0.06, r.get_center().y, 0.12, 0.01, r.size.y * 0.6, Mats.m("line_white"), {"collide": false, "shadow": false, "lod": "main"})
		x += 2.8
	if rng.randf() < 0.7:
		_palm(B, r.position.x + 1.0, r.position.y + 1.0, 7.0, rng)

# ---- landmarks
func _mark(B: MeshBuilder, m: Dictionary, rng: RandomNumberGenerator, out: Dictionary) -> void:
	var p: Vector3 = m.pos
	var paint := Mats.m("paint")
	var wood := Mats.m("wood_planks")
	match m.kind:
		"whale":
			# Wonder Whale: a big friendly blue whale by the highway
			var blue := Color("3d7fd1")
			B.box(p.x, 0, p.z, 4.0, 1.2, 4.0, Mats.m("concrete"), {"collide": false})
			B.add_col(Vector3(p.x - 2, 0, p.z - 2), Vector3(p.x + 2, 6, p.z + 2))
			for k in 7:
				var t := float(k) / 6.0
				var r := 2.6 * sin(PI * (0.15 + 0.85 * t)) + 0.6
				B.cylinder(p.x - 7.0 + t * 14.0, 1.2 + 2.6 - r * 0.5, p.z, r, r, paint, blue, 10, -1.0, {"lod": "main"})
			B.box(p.x - 8.5, 4.2, p.z, 0.5, 2.4, 3.6, paint, {"color": blue, "collide": false, "basis": Basis(Vector3.FORWARD, 0.5)})
			B.box(p.x + 5.5, 3.0, p.z + 0.9, 0.3, 0.3, 0.05, paint, {"color": Color.BLACK, "collide": false})
			out.labels.append({"text": "WONDER WHALE", "pos": p + Vector3(0, 1.0, 2.1), "yaw": 0.0, "size": 0.7, "color": Color.WHITE})
		"tower":
			var metal := Mats.m("metal_brushed")
			for k in 4:
				var ang := PI * 0.5 * k + PI * 0.25
				B.cylinder(p.x + cos(ang) * 1.4, 0, p.z + sin(ang) * 1.4, 0.12, 34.0, metal, Color(0.8, 0.8, 0.8), 4, 0.06, {"lod": "mid"})
			for h in [10.0, 20.0, 29.0]:
				B.box(p.x, h, p.z, 2.6, 0.12, 2.6, metal, {"collide": false, "lod": "mid"})
			B.box(p.x, 31.0, p.z, 0.6, 3.0, 0.6, paint, {"color": Color("e2434b"), "collide": false, "lod": "mid"})
			B.add_col(Vector3(p.x - 1.6, 0, p.z - 1.6), Vector3(p.x + 1.6, 34, p.z + 1.6))
		"sign":
			for s in [-2.6, 2.6]:
				var q := p + Vector3(0, 0, s) if absf(m.yaw) > 0.1 else p + Vector3(s, 0, 0)
				B.box(q.x, 0, q.z, 0.3, 3.4, 0.3, wood, {"collide": false})
			B.box(p.x, 2.2, p.z, 0.3 if absf(m.yaw) > 0.1 else 6.0, 1.3, 6.0 if absf(m.yaw) > 0.1 else 0.3, paint, {"color": Color("1e6fb8"), "collide": false})
			out.labels.append({"text": m.text, "pos": p + Vector3(0, 2.85, 0) + U.fwd(m.yaw) * 0.2, "yaw": m.yaw, "size": 0.75, "color": Color.WHITE})
		"barrier":
			for o in [-4.5, -1.5, 1.5, 4.5]:
				B.box(p.x, 0.0, p.z + o, 0.6, 1.0, 2.6, paint, {"color": Color("f2f2ee"), "collide": false})
				B.box(p.x, 0.5, p.z + o, 0.62, 0.25, 2.62, paint, {"color": Color("e2434b"), "collide": false})
			B.add_col(Vector3(p.x - 0.4, 0, p.z - 6.5), Vector3(p.x + 0.4, 2.0, p.z + 6.5))
			out.labels.append({"text": m.text, "pos": p + Vector3(signf(-p.x) * 0.35, 1.9, 0), "yaw": PI / 2 if p.x > 0 else -PI / 2, "size": 0.7, "color": Color("ffd23f")})
		"stilt_house":
			var r: Rect2 = m.rect
			var cx := r.get_center().x
			var cz := r.get_center().y
			# Jason's boat tied up alongside + a bait cooler and chairs on the deck
			_boat(B, Vector3(cx + 13.4, 0, cz + 2.0), 0.0, 9.0, rng)
			for k in 2:
				B.box(cx + 5.0 + k * 1.4, 0.25, cz + 9.4, 0.7, 0.8, 0.7, paint, {"color": Color("2e6fd1"), "collide": false, "lod": "detail"})
			B.box(cx - 5.0, 0.25, cz + 9.6, 1.0, 0.6, 0.6, paint, {"color": Color("f2f2ee"), "collide": false, "lod": "detail"})

func _scatter(B: MeshBuilder, ck: Vector2i, rng: RandomNumberGenerator) -> void:
	# palms on open land, mangrove/sea-grape along the shore
	var pc = per_chunk.get(ck)
	var tries := 26
	for k in tries:
		var x := ck.x * 50.0 + rng.randf() * 50.0
		var z := ck.y * 50.0 + rng.randf() * 50.0
		var t := cell_type(x, z)
		if t == WATER or t == DOCK or absf(z - rc(x)) < RHW + 3.0 or absf(x) < TOWN + 5.0:
			continue
		if _street_at(x, z) != null or _on_lot(pc, x, z):
			continue
		var shore := cell_type(x + 6.0, z) == WATER or cell_type(x - 6.0, z) == WATER or cell_type(x, z + 6.0) == WATER or cell_type(x, z - 6.0) == WATER
		if shore:
			_mangrove(B, x, z, rng)
		elif rng.randf() < 0.45:
			_palm(B, x, z, 6.0 + rng.randf() * 4.0, rng)
		elif rng.randf() < 0.5:
			_bush(B, x, z, rng)

func _on_lot(pc, x: float, z: float) -> bool:
	if pc == null:
		return false
	for l in pc.lots:
		if l.rect.grow(2.0).has_point(Vector2(x, z)):
			return true
	return false

# ---- props
func _palm(B: MeshBuilder, x: float, z: float, h: float, rng: RandomNumberGenerator) -> void:
	var lean := (rng.randf() - 0.5) * 0.14
	var dir := rng.randf() * TAU
	var trunk := Mats.m("trunk")
	for i in 5:
		var t := float(i) / 5.0
		var s := 0.42 - t * 0.12
		B.box(x + cos(dir) * lean * t * h * t, i * (h / 5.0), z + sin(dir) * lean * t * h * t, s, h / 5.0 + 0.05, s, trunk, {"basis": Basis(Vector3.UP, i * 0.4), "collide": false})
	var top := Vector3(x + cos(dir) * lean * h, h, z + sin(dir) * lean * h)
	var leaf := Mats.m("leaf")
	for i in 7:
		var basis := Basis(Vector3.UP, TAU * i / 7.0 + rng.randf() * 0.3) * Basis(Vector3.RIGHT, 0.35 + rng.randf() * 0.35)
		var c := top + basis * Vector3(0, 0, 1.5)
		B.box(c.x, c.y - 0.02, c.z, 0.7, 0.04, 3.2, leaf, {"basis": basis, "color": col([0x3f8f3a, 0x4ea341, 0x5aa84a, 0x377f33][i % 4]), "collide": false})
	B.add_col(Vector3(x - 0.25, 0, z - 0.25), Vector3(x + 0.25, h, z + 0.25))

func _palm_seeded(B: MeshBuilder, x: float, z: float, h: float) -> void:
	var r := RandomNumberGenerator.new()
	r.seed = int(x * 31.0 + z * 17.0)
	_palm(B, x, z, h, r)

func _mangrove(B: MeshBuilder, x: float, z: float, rng: RandomNumberGenerator) -> void:
	var leaf := Mats.m("leaf")
	var g := col([0x2f6b33, 0x356f2f, 0x2a5f2c][rng.randi() % 3])
	var r := 1.6 + rng.randf() * 1.4
	B.cylinder(x, 0.0, z, r, 1.0 + rng.randf() * 0.6, leaf, g, 7, r * 0.55, {"lod": "mid"})
	B.cylinder(x + 0.6, 1.0, z - 0.4, r * 0.7, 0.9, leaf, g.lightened(0.08), 7, 0.0, {"lod": "mid"})

func _bush(B: MeshBuilder, x: float, z: float, rng: RandomNumberGenerator) -> void:
	var r := 0.8 + rng.randf() * 0.9
	B.cylinder(x, 0.0, z, r, r * 1.1, Mats.m("leaf"), col([0x4a8a3c, 0x3f7f35, 0x5a9a48][rng.randi() % 3]), 6, r * 0.45, {"lod": "detail"})

func _lamp(B: MeshBuilder, x: float, z: float, toward: Vector3) -> void:
	var metal := Mats.m("metal_brushed")
	B.box(x, 0.0, z, 0.18, 7.0, 0.18, metal, {"collide": false})
	B.add_col(Vector3(x - 0.15, 0, z - 0.15), Vector3(x + 0.15, 6, z + 0.15))
	var h := Vector3(x, 0, z) + toward * 1.6
	B.box((x + h.x) * 0.5, 7.0, (z + h.z) * 0.5, maxf(0.12, absf(toward.x) * 1.8), 0.12, maxf(0.12, absf(toward.z) * 1.8), metal, {"collide": false})
	B.box(h.x, 6.8, h.z, 0.6, 0.18, 0.6, Mats.m("lamp_glow"), {"collide": false, "shadow": false})

func _pole(B: MeshBuilder, x: float, z: float) -> void:
	var wood := Mats.m("trunk")
	B.box(x, 0.0, z, 0.3, 9.0, 0.3, wood, {"collide": false, "lod": "mid"})
	B.box(x, 8.2, z, 2.4, 0.15, 0.15, wood, {"collide": false, "lod": "mid"})
	B.add_col(Vector3(x - 0.2, 0, z - 0.2), Vector3(x + 0.2, 8, z + 0.2))

func _boat(B: MeshBuilder, p: Vector3, yaw: float, len: float, rng: RandomNumberGenerator) -> void:
	var paint := Mats.m("paint_gloss")
	var hull := col(BOATS[rng.randi() % BOATS.size()])
	var basis := Basis(Vector3.UP, yaw)
	var y := p.y if p.y > 0.0 else SEA_Y - 0.2
	B.box(p.x, y, p.z, 2.2, 1.0, len, paint, {"basis": basis, "color": hull, "collide": false, "lod": "detail"})
	var bow := p + basis * Vector3(0, 0, len * 0.5 + 0.6)
	B.box(bow.x, y + 0.2, bow.z, 1.4, 0.8, 1.4, paint, {"basis": basis * Basis(Vector3.UP, PI / 4), "color": hull, "collide": false, "lod": "detail"})
	var cab := p + basis * Vector3(0, 0, -len * 0.1)
	B.box(cab.x, y + 1.0, cab.z, 1.8, 0.9, len * 0.3, paint, {"basis": basis, "color": Color(0.95, 0.95, 0.95), "collide": false, "lod": "detail"})

# ================================================================= routes for AI / spawning
## A point on a sidewalk / road shoulder within [rmin, rmax] of p (for people).
func ped_spot(p: Vector3, rmin: float, rmax: float, rng: RandomNumberGenerator) -> Vector3:
	for k in 12:
		var x := clampf(p.x + rng.randf_range(-rmax, rmax), X0 + 60.0, X1 - 60.0)
		var side := -1.0 if rng.randf() < 0.5 else 1.0
		var z := rc(x) + side * (RHW + (1.6 if absf(x) < TOWN else 2.6))
		if rng.randf() < 0.35 and absf(x) < TOWN:
			# a town side street sidewalk instead
			var sx: float = TOWN_X[rng.randi() % TOWN_X.size()] + side * (RHW + 1.5)
			z = rng.randf_range(-100.0, 105.0)
			x = sx
		var q := Vector3(x, 0, z)
		var d := U.d2(q, p)
		if d >= rmin and d <= rmax and walkable(x, z) and not on_route(x, z):
			return q
	return Vector3.INF

## Lane point on Route 1: dir +1 = eastbound (south lane), -1 = westbound (north lane).
func lane_point(x: float, dir: float) -> Vector3:
	return Vector3(x, 0, rc(x) + (3.0 if dir > 0.0 else -3.0))
