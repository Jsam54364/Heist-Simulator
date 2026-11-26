class_name Roads
extends RefCounted
## Road graph for police/AI route planning plus the traffic loops.

const END := 146.0
static var nodes: Array = []   # Vector2(x, z)
static var adj: Array = []

static func _idx(x: float, z: float) -> int:
	for i in nodes.size():
		if nodes[i].x == x and nodes[i].y == z:
			return i
	nodes.append(Vector2(x, z))
	adj.append([])
	return nodes.size() - 1

static func _link(a: int, b: int) -> void:
	if not adj[a].has(b):
		adj[a].append(b)
		adj[b].append(a)

static func build() -> void:
	nodes.clear()
	adj.clear()
	var zs := [-END] + Game.ROAD_Z + [END]
	for x in Game.ROAD_X:
		for k in zs.size() - 1:
			_link(_idx(x, zs[k]), _idx(x, zs[k + 1]))
	var xs := [-END] + Game.ROAD_X
	for z in Game.ROAD_Z:
		for k in xs.size() - 1:
			_link(_idx(xs[k], z), _idx(xs[k + 1], z))

static func nearest_node(p: Vector3) -> int:
	var best := 0
	var bd := 1e9
	for i in nodes.size():
		var d: float = Vector2(nodes[i].x - p.x, nodes[i].y - p.z).length()
		if d < bd:
			bd = d
			best = i
	return best

static func closest_road_point(p: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var bd := 1e9
	for x in Game.ROAD_X:
		var q := Vector3(x, 0, clampf(p.z, -END, END))
		var d := Vector2(q.x - p.x, q.z - p.z).length()
		if d < bd:
			bd = d
			best = q
	for z in Game.ROAD_Z:
		var q := Vector3(clampf(p.x, -END, Game.ROAD_SPAN_X[1]), 0, z)
		var d := Vector2(q.x - p.x, q.z - p.z).length()
		if d < bd:
			bd = d
			best = q
	return best

static func plan(from: Vector3, to: Vector3) -> Array:
	var s := nearest_node(from)
	var e := nearest_node(to)
	var n := nodes.size()
	var dist := []
	var prev := []
	var done := []
	dist.resize(n); prev.resize(n); done.resize(n)
	dist.fill(1e9); prev.fill(-1); done.fill(false)
	dist[s] = 0.0
	while true:
		var u := -1
		for i in n:
			if not done[i] and (u < 0 or dist[i] < dist[u]):
				u = i
		if u < 0 or dist[u] >= 1e9:
			break
		done[u] = true
		if u == e:
			break
		for v in adj[u]:
			var d: float = dist[u] + (nodes[u] - nodes[v]).length()
			if d < dist[v]:
				dist[v] = d
				prev[v] = u
	var out := []
	var k := e
	while k != -1:
		out.push_front(Vector3(nodes[k].x, 0, nodes[k].y))
		k = prev[k]
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

const LOOPS := [
	[[-50, -50], [50, -50], [50, 0], [-50, 0]],
	[[0, 0], [0, 50], [50, 50], [50, 0]],
	[[-100, -100], [100, -100], [100, 100], [-100, 100]],
	[[100, -100], [150, -100], [150, 100], [100, 100]],
	[[-100, 50], [-50, 50], [-50, 100], [-100, 100]],
	[[0, -100], [0, -50], [-100, -50], [-100, -100]],
	[[100, 100], [100, -100], [-100, -100], [-100, 100]],
	[[50, 50], [100, 50], [100, 0], [50, 0]],
	[[150, -50], [150, 50], [100, 50], [100, -50]],
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
