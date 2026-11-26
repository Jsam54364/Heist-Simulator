class_name NavGrid
extends RefCounted
## 0.5 m walkability grid on Godot's native AStarGrid2D (fast A* in C++), covering a
## 192 m window that follows the player around the island (a grid over the whole 2.6 km
## key would be 7 million cells). Rasterised from the colliders of the chunks under the
## window plus the land/water mask; doors update their cells when opened/closed.
## People outside the window path in straight lines (they're on far LOD anyway).

const CELL := 0.5
const INFL := 0.3
const SPAN := 192.0
const RECENTER := 48.0
var astar := AStarGrid2D.new()
var ox: float
var oz: float
var nx: int
var nz: int
var B: MeshBuilder
var gen: KeysGen
var center := Vector2(INF, INF)
var dirty := false
var last_raster_ms := 0.0

func _init(builder: MeshBuilder, p_gen: KeysGen) -> void:
	B = builder
	gen = p_gen
	nx = int(SPAN / CELL)
	nz = nx
	astar.region = Rect2i(0, 0, nx, nz)
	astar.cell_size = Vector2(CELL, CELL)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()

## Called every tick by Main with the player position. Rebuilds the window when the player
## has moved far enough, or when new chunks under it finished generating.
func follow(p: Vector3, vel := Vector3.ZERO) -> void:
	# on foot: keep the window centred on you. Driving fast: centre it well ahead of the
	# car so the (few-ms) rebuild happens far less often
	var fast := Vector2(vel.x, vel.z).length() > 8.0
	var limit := SPAN * 0.5 - 24.0 if fast else RECENTER
	if Vector2(p.x, p.z).distance_to(center) > limit or dirty:
		if not dirty:
			var c := p + (Vector3(vel.x, 0, vel.z).normalized() * 60.0 if fast else Vector3.ZERO)
			center = Vector2(snappedf(c.x, 8.0), snappedf(c.z, 8.0))
		dirty = false
		ox = center.x - SPAN * 0.5
		oz = center.y - SPAN * 0.5
		var t0 := Time.get_ticks_usec()
		raster(ox, ox + SPAN, oz, oz + SPAN)
		last_raster_ms = (Time.get_ticks_usec() - t0) / 1000.0

func on_chunk(ck: Vector2i) -> void:
	if MeshBuilder.chunk_rect(ck).intersects(Rect2(ox, oz, SPAN, SPAN)):
		dirty = true

func ci(x: float) -> int: return int(floor((x - ox) / CELL))
func cj(z: float) -> int: return int(floor((z - oz) / CELL))
func wx(i: int) -> float: return ox + (i + 0.5) * CELL
func wz(j: int) -> float: return oz + (j + 0.5) * CELL
func inside(p: Vector3) -> bool:
	return p.x > ox + 1.0 and p.x < ox + SPAN - 1.0 and p.z > oz + 1.0 and p.z < oz + SPAN - 1.0

static func walk_col(c: Dictionary) -> bool:
	return (c.solid and not c.get("disabled", false) and not c.ground and c.min.y < 1.6 and c.max.y > 0.3) or c.get("shore", false)

func raster(min_x: float, max_x: float, min_z: float, max_z: float) -> void:
	var i0 := maxi(0, ci(min_x))
	var i1 := mini(nx - 1, ci(max_x))
	var j0 := maxi(0, cj(min_z))
	var j1 := mini(nz - 1, cj(max_z))
	if i1 < i0 or j1 < j0:
		return
	astar.fill_solid_region(Rect2i(i0, j0, i1 - i0 + 1, j1 - j0 + 1), false)
	# water (5 m mask cells -> 10x10 nav cells), merged into horizontal runs
	if gen:
		var z := floorf(min_z / KeysGen.CELL) * KeysGen.CELL
		while z < max_z:
			var x := floorf(min_x / KeysGen.CELL) * KeysGen.CELL
			var run0 := INF
			while x <= max_x + KeysGen.CELL:
				var water := x <= max_x and not gen.walkable(x + 2.5, z + 2.5)
				if water and run0 == INF:
					run0 = x
				elif not water and run0 != INF:
					_solid_rect(run0, x, z, z + KeysGen.CELL, i0, i1, j0, j1, 0.0)
					run0 = INF
				x += KeysGen.CELL
			z += KeysGen.CELL
	var c0 := MeshBuilder.chunk_of(Vector3(min_x - 2.0, 0, min_z - 2.0))
	var c1 := MeshBuilder.chunk_of(Vector3(max_x + 2.0, 0, max_z + 2.0))
	for cx in range(c0.x, c1.x + 1):
		for cz in range(c0.y, c1.y + 1):
			for c in B.cols_by_chunk.get(Vector2i(cx, cz), []):
				if not walk_col(c):
					continue
				var cmin: Vector3 = c.min
				var cmax: Vector3 = c.max
				if cmax.x + INFL < min_x or cmin.x - INFL > max_x or cmax.z + INFL < min_z or cmin.z - INFL > max_z:
					continue
				_solid_rect(cmin.x, cmax.x, cmin.z, cmax.z, i0, i1, j0, j1, INFL)

func _solid_rect(x0: float, x1: float, z0: float, z1: float, i0: int, i1: int, j0: int, j1: int, infl: float) -> void:
	var a0 := maxi(i0, ci(x0 - infl))
	var a1 := mini(i1, ci(x1 + infl))
	var b0 := maxi(j0, cj(z0 - infl))
	var b1 := mini(j1, cj(z1 + infl))
	# cell centres inside the inflated box
	while a0 <= a1 and wx(a0) < x0 - infl: a0 += 1
	while a1 >= a0 and wx(a1) > x1 + infl: a1 -= 1
	while b0 <= b1 and wz(b0) < z0 - infl: b0 += 1
	while b1 >= b0 and wz(b1) > z1 + infl: b1 -= 1
	if a1 >= a0 and b1 >= b0:
		astar.fill_solid_region(Rect2i(a0, b0, a1 - a0 + 1, b1 - b0 + 1), true)

func update_col(c: Dictionary) -> void:
	var cmin: Vector3 = c.min
	var cmax: Vector3 = c.max
	raster(cmin.x - 1, cmax.x + 1, cmin.z - 1, cmax.z + 1)

func blocked(i: int, j: int) -> bool:
	return i < 0 or j < 0 or i >= nx or j >= nz or astar.is_point_solid(Vector2i(i, j))

func nearest_free(i: int, j: int) -> Vector2i:
	if not blocked(i, j):
		return Vector2i(i, j)
	for r in range(1, 9):
		for dj in range(-r, r + 1):
			for di in range(-r, r + 1):
				if absi(di) != r and absi(dj) != r:
					continue
				if not blocked(i + di, j + dj):
					return Vector2i(i + di, j + dj)
	return Vector2i(-1, -1)

func line_free(a: Vector2i, b: Vector2i) -> bool:
	var dx := absi(b.x - a.x)
	var dy := absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx - dy
	var i := a.x
	var j := a.y
	for n in 600:
		if blocked(i, j):
			return false
		if i == b.x and j == b.y:
			return true
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			i += sx
		if e2 < dx:
			err += dx
			j += sy
	return false

## World-space line-of-walk test (used by NPCs to pick flee spots they can actually reach).
func clear_line(a: Vector3, b: Vector3) -> bool:
	if not inside(a) or not inside(b):
		return true
	return line_free(Vector2i(ci(a.x), cj(a.z)), Vector2i(ci(b.x), cj(b.z)))

## Returns an Array of Vector3 waypoints (y = 0), or [] when unreachable.
## A* searches allowed per physics tick (main resets it). Characters that miss out keep
## following their old path and retry next tick, so a crowd replanning at once can't
## stall a frame.
var budget := 3
var calls := 0
func take_budget() -> bool:
	if budget <= 0:
		return false
	budget -= 1
	return true

func find_path(from: Vector3, to: Vector3) -> Array:
	calls += 1
	if not inside(from) or not inside(to):
		return [Vector3(to.x, 0, to.z)]
	var s := nearest_free(ci(from.x), cj(from.z))
	var e := nearest_free(ci(to.x), cj(to.z))
	if s.x < 0 or e.x < 0:
		return []
	if line_free(s, e):
		return [Vector3(to.x, 0, to.z)]
	var ids := astar.get_id_path(s, e, true)
	if ids.is_empty():
		return []
	var out := []
	var a := 0
	while a < ids.size() - 1:
		var b := mini(ids.size() - 1, a + 40)
		while b > a + 1 and not line_free(ids[a], ids[b]):
			b -= 1
		out.append(Vector3(wx(ids[b].x), 0, wz(ids[b].y)))
		a = b
	if not out.is_empty():
		out[out.size() - 1] = Vector3(to.x, 0, to.z)
	return out

## World-space version of nearest_free: the closest walkable point to p.
func free_point(p: Vector3) -> Vector3:
	if not inside(p):
		return land_point(p)
	var c := nearest_free(ci(p.x), cj(p.z))
	if c.x < 0 or (c.x == ci(p.x) and c.y == cj(p.z)):
		return land_point(p)
	return Vector3(wx(c.x), 0, wz(c.y))

## Closest point on land (people can't stand in the sea).
func land_point(p: Vector3) -> Vector3:
	if gen == null or gen.walkable(p.x, p.z):
		return Vector3(p.x, 0, p.z)
	for r in range(1, 40):
		for k in 16:
			var a := TAU * k / 16.0
			var q := Vector3(p.x + cos(a) * r * 2.0, 0, p.z + sin(a) * r * 2.0)
			if gen.walkable(q.x, q.z) and gen.walkable(q.x + cos(a) * 2.0, q.z + sin(a) * 2.0):
				return q + Vector3(cos(a), 0, sin(a)) * 1.5
	return Vector3(p.x, 0, gen.rc(p.x))
