class_name Roads
extends RefCounted
## Road graph for police/AI route planning: Route 1 down the length of Key Lento (a node
## every ~40 m), the town street grid and the side streets into the neighbourhoods and
## marinas. Planned with Godot's native AStar3D. Also lane helpers + town traffic loops.

static var gen: KeysGen
static var nodes: Array = []   # Vector2(x, z)
static var astar := AStar3D.new()
static var segs: Array = []    # [Vector2 a, Vector2 b] for closest_road_point
const R1_END := 1262.0

static func _add(p: Vector2) -> int:
	for i in nodes.size():
		if nodes[i].distance_squared_to(p) < 1.0:
			return i
	nodes.append(p)
	astar.add_point(nodes.size() - 1, Vector3(p.x, 0, p.y))
	return nodes.size() - 1

static func _link(a: int, b: int) -> void:
	if a != b and not astar.are_points_connected(a, b):
		astar.connect_points(a, b)
		segs.append([nodes[a], nodes[b]])

static func build(p_gen: KeysGen) -> void:
	gen = p_gen
	nodes.clear()
	segs.clear()
	astar.clear()
	# junction x positions along Route 1
	var xs := {}
	var x := -R1_END
	while x <= R1_END:
		xs[snappedf(x, 1.0)] = true
		x += 40.0
	for tx in KeysGen.TOWN_X:
		xs[tx] = true
	var side := []   # [x on route, Vector2 far end]
	for s in gen.streets:
		var r: Rect2 = s.rect
		if s.axis != "z" or absf(r.get_center().x) < KeysGen.TOWN:
			continue
		var sx := r.get_center().x
		xs[snappedf(sx, 1.0)] = true
		var c := gen.rc(sx)
		var far_z := r.position.y if absf(r.position.y - c) > absf(r.end.y - c) else r.end.y
		side.append([snappedf(sx, 1.0), Vector2(sx, far_z - signf(far_z - c) * 3.0)])
	var keys := xs.keys()
	keys.sort()
	var prev := -1
	for kx in keys:
		var i := _add(Vector2(kx, gen.rc(kx)))
		if prev >= 0:
			_link(prev, i)
		prev = i
	for sd in side:
		_link(_add(Vector2(sd[0], gen.rc(sd[0]))), _add(sd[1]))
	# town grid: cross streets from z -110 to 116, back streets at TOWN_N / TOWN_S
	var zs := [-108.0, KeysGen.TOWN_N, 0.0, KeysGen.TOWN_S, 114.0]
	for tx in KeysGen.TOWN_X:
		for k in zs.size() - 1:
			_link(_add(Vector2(tx, zs[k])), _add(Vector2(tx, zs[k + 1])))
	for z in [KeysGen.TOWN_N, KeysGen.TOWN_S]:
		for k in KeysGen.TOWN_X.size() - 1:
			_link(_add(Vector2(KeysGen.TOWN_X[k], z)), _add(Vector2(KeysGen.TOWN_X[k + 1], z)))

static func nearest_node(p: Vector3) -> int:
	return astar.get_closest_point(Vector3(p.x, 0, p.z))

static func closest_road_point(p: Vector3) -> Vector3:
	var q := Vector2(p.x, p.z)
	var best := Vector2.ZERO
	var bd := INF
	for sg in segs:
		var a: Vector2 = sg[0]
		var b: Vector2 = sg[1]
		if absf(a.x - q.x) > 80.0 and absf(b.x - q.x) > 80.0 and signf(a.x - q.x) == signf(b.x - q.x):
			continue
		var c := Geometry2D.get_closest_point_to_segment(q, a, b)
		var d := c.distance_squared_to(q)
		if d < bd:
			bd = d
			best = c
	return Vector3(best.x, 0, best.y)

static func plan(from: Vector3, to: Vector3) -> Array:
	var s := nearest_node(from)
	var e := nearest_node(to)
	var ids := astar.get_id_path(s, e)
	var out := []
	for id in ids:
		out.append(Vector3(nodes[id].x, 0, nodes[id].y))
	if out.size() > 1:
		var a: Vector3 = out[0]
		var b: Vector3 = out[1]
		if U.d2(b, from) < U.d2(b, a):
			out.pop_front()
	out.append(closest_road_point(to))
	return out

static func far_node(from: Vector3, min_d: float, max_d: float) -> Vector3:
	var c := []
	for nd in nodes:
		var d: float = Vector2(nd.x - from.x, nd.y - from.z).length()
		if d >= min_d and d <= max_d:
			c.append(nd)
	var pick: Vector2 = c[randi() % c.size()] if not c.is_empty() else nodes[randi() % nodes.size()]
	return Vector3(pick.x, 0, pick.y)

## Route 1 node ahead of p in the given travel direction (+1 east, -1 west), for
## dispatching units that come up the highway towards you.
static func route_point(x: float, lane := 0.0) -> Vector3:
	return Vector3(x, 0, gen.rc(x) + lane)

## Town traffic loops (clockwise around blocks, driven in the right-hand lane).
const LOOPS := [
	[[-50, -60], [50, -60], [50, 0], [-50, 0]],
	[[0, 0], [0, 65], [100, 65], [100, 0]],
	[[-150, -60], [-50, -60], [-50, 0], [-150, 0]],
	[[100, -60], [200, -60], [200, 0], [100, 0]],
	[[-200, 0], [-200, 65], [-100, 65], [-100, 0]],
]

static func lane_loop(loop: Array) -> Array:
	var n := loop.size()
	var pts := []
	for i in n:
		var p: Array = loop[(i - 1 + n) % n]
		var c: Array = loop[i]
		var q: Array = loop[(i + 1) % n]
		var din := atan2(c[0] - p[0], c[1] - p[1])
		var dout := atan2(q[0] - c[0], q[1] - c[1])
		var r := U.right(din) + U.right(dout)
		pts.append(Vector3(c[0] + r.x * 3.0, 0, c[1] + r.z * 3.0))
	return pts
