class_name NavGrid
extends RefCounted
## 0.5 m walkability grid on Godot's native AStarGrid2D (fast A* in C++).
## Rasterised from the collider list; doors update their cells when opened/closed.

const CELL := 0.5
const INFL := 0.3
var astar := AStarGrid2D.new()
var ox: float
var oz: float
var nx: int
var nz: int
var cols: Array

func _init(colliders: Array) -> void:
	cols = colliders
	ox = Game.WORLD.min_x - 2.0
	oz = Game.WORLD.min_z - 2.0
	nx = int(ceil((Game.WORLD.shore + 4.0 - ox) / CELL))
	nz = int(ceil((Game.WORLD.max_z + 2.0 - oz) / CELL))
	astar.region = Rect2i(0, 0, nx, nz)
	astar.cell_size = Vector2(CELL, CELL)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	raster(ox, ox + nx * CELL, oz, oz + nz * CELL)

func ci(x: float) -> int: return int(floor((x - ox) / CELL))
func cj(z: float) -> int: return int(floor((z - oz) / CELL))
func wx(i: int) -> float: return ox + (i + 0.5) * CELL
func wz(j: int) -> float: return oz + (j + 0.5) * CELL

static func walk_col(c: Dictionary) -> bool:
	return c.solid and not c.get("disabled", false) and not c.ground and c.min.y < 1.6 and c.max.y > 0.3

func raster(min_x: float, max_x: float, min_z: float, max_z: float) -> void:
	var i0 := maxi(0, ci(min_x))
	var i1 := mini(nx - 1, ci(max_x))
	var j0 := maxi(0, cj(min_z))
	var j1 := mini(nz - 1, cj(max_z))
	astar.fill_solid_region(Rect2i(i0, j0, i1 - i0 + 1, j1 - j0 + 1), false)
	for c in cols:
		if not walk_col(c):
			continue
		var cmin: Vector3 = c.min
		var cmax: Vector3 = c.max
		if cmax.x + INFL < min_x or cmin.x - INFL > max_x or cmax.z + INFL < min_z or cmin.z - INFL > max_z:
			continue
		var a0 := maxi(i0, ci(cmin.x - INFL))
		var a1 := mini(i1, ci(cmax.x + INFL))
		var b0 := maxi(j0, cj(cmin.z - INFL))
		var b1 := mini(j1, cj(cmax.z + INFL))
		# cell centres inside the inflated box
		while a0 <= a1 and wx(a0) < cmin.x - INFL: a0 += 1
		while a1 >= a0 and wx(a1) > cmax.x + INFL: a1 -= 1
		while b0 <= b1 and wz(b0) < cmin.z - INFL: b0 += 1
		while b1 >= b0 and wz(b1) > cmax.z + INFL: b1 -= 1
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
	for r in range(1, 7):
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
	for n in 500:
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

## Returns an Array of Vector3 waypoints (y = 0), or [] when unreachable.
func find_path(from: Vector3, to: Vector3) -> Array:
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
	var c := nearest_free(ci(p.x), cj(p.z))
	if c.x < 0 or (c.x == ci(p.x) and c.y == cj(p.z)):
		return Vector3(p.x, 0, p.z)
	return Vector3(wx(c.x), 0, wz(c.y))
