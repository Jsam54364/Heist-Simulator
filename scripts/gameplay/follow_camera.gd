class_name FollowCamera
extends Camera3D
## Third-person camera: over-the-shoulder on foot (tighter when aiming / indoors),
## chase cam in vehicles that swings behind the direction of travel, sphere-cast
## collision so walls never come between camera and player, speed-based FOV, shake.

var yaw := -PI / 2
var pitch := 0.25
var last_look := -99.0
var shake := 0.0
var _init_done := false
var _pivot_smooth := Vector3.ZERO
var _probe := SphereShape3D.new()
var _kick := 0.0          # recoil still to recover (radians of pitch)
var _ads := 0.0           # 0..1 eased aim-down-sights blend
var _crouch := 0.0

func _ready() -> void:
	fov = 62.0
	near = 0.08
	far = 600.0
	_probe.radius = 0.22

func look(dx: float, dy: float) -> void:
	if dx != 0.0 or dy != 0.0:
		last_look = Game.t
	var k := lerpf(1.0, 0.55, _ads)   # finer aim while zoomed
	yaw -= dx * 0.0045 * k
	pitch = clampf(pitch + dy * 0.0035 * k, -0.35, 1.15)

## recoil: the view kicks up, then most of it settles back
func recoil(up: float, side: float) -> void:
	pitch = clampf(pitch - up, -0.35, 1.15)
	yaw += side
	_kick += up * 0.7

func update_cam(dt: float) -> void:
	var P = Game.player
	if P == null:
		return
	var car = P.in_car
	var csp: float = car.linear_velocity.length() if car else 0.0
	if car:
		var want_yaw: float = car.yaw()
		if car.speed() > 4.0:
			var v: Vector3 = car.linear_velocity
			want_yaw = atan2(v.x, v.z)
		if Game.t - last_look > 1.2:
			yaw += U.ang_diff(yaw, want_yaw) * minf(1.0, dt * (1.6 + csp * 0.07))
			pitch += (0.2 - pitch) * minf(1.0, dt * 1.5)
	if _kick > 0.0:
		var back := minf(_kick, dt * 0.22)
		_kick -= back
		if Game.t - P.last_shot > 0.12:
			pitch = clampf(pitch + back, -0.35, 1.15)
	_ads = move_toward(_ads, 1.0 if (P.ads and not car) else 0.0, dt * 6.0)
	_crouch = move_toward(_crouch, 1.0 if (P.crouching and not car) else 0.0, dt * 5.0)
	var ae := _ads * _ads * (3.0 - 2.0 * _ads)
	var target: Vector3
	if car:
		target = car.get_global_transform_interpolated().origin + Vector3(0, 1.8, 0)
		target.y = maxf(target.y, Game.ground_y(target.x, target.z) + 1.8)
	else:
		var gp: Vector3 = P.get_global_transform_interpolated().origin
		target = Vector3(gp.x, Game.ground_y(gp.x, gp.z) + 1.55 - _crouch * 0.42 + P.air_y * 0.65, gp.z)
	if not _init_done:
		_pivot_smooth = target
	_pivot_smooth = _pivot_smooth.lerp(target, minf(1.0, dt * (14.0 if car else 22.0)))
	var b = Game.cur_building
	var indoor: bool = b != null and not b.garage
	var dist: float
	if car:
		dist = 7.0 + minf(4.0, csp * 0.09) + (3.0 if car.kind == "truck" else 0.0)
	elif P.weapon:
		dist = lerpf(2.2 if indoor else 2.7, 1.45, ae)
	else:
		dist = 3.1 if indoor else 4.2
	var shoulder: float = 0.0 if car else lerpf(0.7 if P.weapon else 0.45, 0.62, ae)
	var f := U.fwd(yaw)
	var r := U.right(yaw)
	var piv := _pivot_smooth + r * shoulder
	var want := piv - f * dist * cos(pitch)
	want.y = piv.y + dist * sin(pitch) + (0.9 if car else 0.0)
	if b != null:
		want.y = minf(want.y, 3.6 if b.garage else 3.6)
	# collision (shape cast from pivot to desired position)
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _probe
	q.transform = Transform3D(Basis(), piv)
	q.motion = want - piv
	q.collision_mask = Game.L_WORLD
	var res := space.cast_motion(q)
	if res.size() == 2 and res[0] < 1.0:
		want = piv.lerp(want, maxf(0.1, res[0]))
	if not _init_done:
		global_position = want
		_init_done = true
	global_position = global_position.lerp(want, minf(1.0, dt * (9.0 if car else 18.0)))
	var fov_t := 62.0 + (clampf(csp * 0.42, 0.0, 17.0) if car else 0.0)
	if not car:
		fov_t = lerpf(fov_t + (4.0 if P.sprinting else 0.0), 44.0, ae)
	fov += (fov_t - fov) * minf(1.0, dt * (12.0 if _ads > 0.0 and _ads < 1.0 else 3.0))
	if shake > 0.0:
		global_position += Vector3(randf() - 0.5, randf() - 0.5, 0) * shake * 0.5
		shake = maxf(0.0, shake - dt * 2.5)
	var lk := piv + f * 2.0
	lk.y = piv.y + (0.4 if car else 0.0) - sin(pitch) * 0.6
	if global_position.distance_to(lk) > 0.01:
		look_at(lk, Vector3.UP)

func snap() -> void:
	_init_done = false
