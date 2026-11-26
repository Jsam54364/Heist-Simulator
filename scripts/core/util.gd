class_name U
## Small shared helpers. Yaw convention: forward = (sin yaw, 0, cos yaw), models face +Z.

static func fwd(yaw: float) -> Vector3:
	return Vector3(sin(yaw), 0.0, cos(yaw))

static func right(yaw: float) -> Vector3:
	return Vector3(-cos(yaw), 0.0, sin(yaw))

static func ang_to(a: Vector3, b: Vector3) -> float:
	return atan2(b.x - a.x, b.z - a.z)

static func ang_diff(a: float, b: float) -> float:
	return wrapf(b - a, -PI, PI)

static func d2(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

static func money(n: float) -> String:
	var s := str(int(round(absf(n))))
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return ("-$" if n < 0 else "$") + out

static func fmt_time(s: float) -> String:
	var t := int(maxf(0.0, s))
	return "%d:%02d" % [t / 60, t % 60]

static func in_bounds(p: Vector3, b: Rect2, pad := 0.0) -> bool:
	## b is an x/z rectangle: position = (minX, minZ), size = (w, d)
	return p.x >= b.position.x - pad and p.x <= b.end.x + pad and p.z >= b.position.y - pad and p.z <= b.end.y + pad

static func approach(v: float, target: float, delta: float) -> float:
	return maxf(target, v - delta) if v > target else minf(target, v + delta)

static func rand_range(a: float, b: float) -> float:
	return a + randf() * (b - a)
