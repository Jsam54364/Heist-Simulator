extends Node
## Ambient population. Traffic: a few cars circling the town blocks, plus a ring of cars on
## Route 1 that spawn out of sight 160-230 m from you, cruise the highway in their lane,
## U-turn at the closed bridges and despawn behind you - so the whole 2.6 km key feels
## busy while only ~14 cars exist. Pedestrians work the same way on the sidewalks.
## Cars brake for cars and people ahead; vehicle-vs-pedestrian contact (push-out and
## run-overs) lives here too.

const ROUTE_CARS := 9
const PEDS := 16
const SPAWN_MIN := 160.0
const SPAWN_MAX := 230.0
const DESPAWN := 290.0
const PED_DESPAWN := 150.0
var rng := RandomNumberGenerator.new()
var pop_t := 0.0

func spawn() -> void:
	rng.randomize()
	var li := 0
	for loop in Roads.LOOPS:
		var pts: Array = Roads.lane_loop(loop)
		var a: Vector3 = pts[0]
		var b: Vector3 = pts[1]
		var p := a.lerp(b, 0.3 + (li % 3) * 0.15)
		_make_car(p, U.ang_to(a, b), {"kind": "traffic", "pts": pts, "idx": 1})
		li += 1

func _make_car(p: Vector3, yaw: float, ai: Dictionary) -> Vehicle:
	var car: Vehicle = Game.main.spawn_car("civ", p, yaw)
	car.ai = ai
	var d: Character = Game.main.spawn_char("driver", p)
	d.in_car = car
	d.set_hidden(true)
	car.npc_driver = d
	return car

func _focus() -> Vector3:
	var P = Game.player
	return P.in_car.global_position if P.in_car else P.global_position

## Keep the ring populated: spawn route cars / people out of sight, remove far ones.
func populate(dt: float) -> void:
	pop_t -= dt
	if pop_t > 0.0:
		return
	pop_t = 0.5
	var f := _focus()
	var gen: KeysGen = Game.main.world_gen
	var n_route := 0
	for car in Game.cars.duplicate():
		if car.ai.get("kind", "") != "route" or car.driver == "player":
			continue
		if U.d2(car.global_position, f) > DESPAWN and not car.personal:
			Game.main.remove_car(car)
		else:
			n_route += 1
	if n_route < ROUTE_CARS:
		for k in 4:
			var x := f.x + (1.0 if rng.randf() < 0.5 else -1.0) * rng.randf_range(SPAWN_MIN, SPAWN_MAX)
			if absf(x) > Roads.R1_END - 20.0:
				continue
			var dir := 1.0 if rng.randf() < 0.5 else -1.0
			var p := gen.lane_point(x, dir)
			if U.d2(p, f) < SPAWN_MIN * 0.8 or _car_near(p, 14.0):
				continue
			_make_car(p, PI / 2 if dir > 0.0 else -PI / 2, {"kind": "route", "dir": dir, "speed": rng.randf_range(13.0, 19.0)})
			break
	# people
	var n_ped := 0
	for c in Game.chars.duplicate():
		if c.role != "pedestrian":
			continue
		if U.d2(c.global_position, f) > PED_DESPAWN and c.mem.get("panic", 0.0) <= 0.0:
			Game.main.remove_char(c)
		else:
			n_ped += 1
	if n_ped < PEDS:
		var p: Vector3 = gen.ped_spot(f, 45.0, 110.0, rng)
		if p != Vector3.INF and Game.main.streamer.generated(p):
			Game.main.spawn_pedestrian(p)

func _car_near(p: Vector3, r: float) -> bool:
	for o in Game.cars:
		if U.d2(o.global_position, p) < r:
			return true
	return false

func update(dt: float) -> void:
	populate(dt)
	var P = Game.player
	for car in Game.cars:
		var kind: String = car.ai.get("kind", "")
		if (kind != "traffic" and kind != "route") or car.driver == "player":
			continue
		if car.npc_driver == null or car.npc_driver.mem.get("bailed", false):
			car.release()
			continue
		var ai: Dictionary = car.ai
		if kind == "traffic":
			var tgt: Vector3 = ai.pts[ai.idx]
			if U.d2(car.global_position, tgt) < 5.0:
				ai.idx = (ai.idx + 1) % ai.pts.size()
		var f: Vector3 = car.fwd_dir()
		# the "anything ahead of me?" scan is the expensive part: refresh it every 3rd tick
		ai.scan_n = ai.get("scan_n", randi() % 3) + 1
		if ai.scan_n < 3 and ai.has("blocked"):
			_drive(car, ai, ai.blocked, dt, P)
			continue
		ai.scan_n = 0
		var blocked := false
		for o in Game.cars:
			if o == car:
				continue
			var dv: Vector3 = o.global_position - car.global_position
			var lf := dv.x * f.x + dv.z * f.z
			var lr := absf(dv.x * f.z - dv.z * f.x)
			if lf > 0.0 and lf < 11.0 and lr < 1.85:
				blocked = true
				break
		if not blocked:
			for c in Game.chars:
				if c.hidden or c.dead:
					continue
				var dv: Vector3 = c.global_position - car.global_position
				var lf := dv.x * f.x + dv.z * f.z
				var lr := absf(dv.x * f.z - dv.z * f.x)
				if lf > 0.0 and lf < 7.5 and lr < 1.6:
					blocked = true
					break
		# drivers react to danger: gunfire / a wanted chase nearby -> floor it or bail out
		var d: Character = car.npc_driver
		var panic: float = d.mem.get("panic", 0.0)
		if panic > 0.0:
			d.mem.panic = panic - dt * 3.0
			blocked = false
		elif Game.wanted.stars >= 3 and U.d2(P.global_position, car.global_position) < 30.0:
			blocked = false
		ai.blocked = blocked
		_drive(car, ai, blocked, dt, P)

func _route_target(car: Vehicle, ai: Dictionary) -> Array:
	var gen: KeysGen = Game.main.world_gen
	var x: float = car.global_position.x
	var dir: float = ai.dir
	# U-turn at the closed bridges
	if (dir > 0.0 and x > Roads.R1_END - 30.0) or (dir < 0.0 and x < -Roads.R1_END + 30.0):
		ai.dir = -dir
		dir = -dir
	var look := 14.0 + absf(car.speed()) * 0.6
	return [gen.lane_point(x + dir * look, dir), gen.lane_point(x + dir * (look + 20.0), dir)]

func _drive(car: Vehicle, ai: Dictionary, blocked: bool, dt: float, P) -> void:
	var panic: bool = car.npc_driver.mem.get("panic", 0.0) > 0.0
	var vmax: float = ai.get("speed", 12.0) * (1.5 if panic else 1.0)
	# physics LOD: far from the camera/player the car rides its lane kinematically
	var cam_p: Vector3 = Game.main.camera.global_position
	var far: bool = U.d2(cam_p, car.global_position) > 125.0 and U.d2(P.global_position, car.global_position) > 125.0
	far = far or not Game.main.streamer.generated(car.global_position)
	car.set_rail(far, 0.0 if blocked else vmax)
	var tgt: Vector3
	var nxt: Vector3
	if ai.kind == "route":
		var t := _route_target(car, ai)
		tgt = t[0]
		nxt = t[1]
	else:
		tgt = ai.pts[ai.idx]
		nxt = ai.pts[(ai.idx + 1) % ai.pts.size()]
	if car.rail:
		_rail_step(car, tgt, 0.0 if blocked else vmax, dt)
		return
	car.drive_to(tgt, 0.0 if blocked else vmax, dt, {"arrive": false, "stop": blocked, "next": nxt})

func contacts() -> void:
	# cars ignore people physically (so a cop standing in the road can't flip a truck);
	# people get pushed out of car footprints and knocked down by fast cars.
	# Parked/sleeping/kinematic-rail cars can't run anyone over, so they're skipped.
	for car in Game.cars:
		if car.rail or car.sleeping:
			continue
		var sp: float = car.linear_velocity.length()
		if sp < 0.8:
			continue
		var f: Vector3 = car.fwd_dir()
		f.y = 0
		f = f.normalized()
		var r := Vector3(-f.z, 0, f.x)
		var cp: Vector3 = car.global_position
		for c in Game.chars:
			if c.hidden or c.in_car != null:
				continue
			var dv: Vector3 = c.global_position - cp
			if absf(dv.x) > 9.0 or absf(dv.z) > 9.0:
				continue
			var lf := dv.x * f.x + dv.z * f.z
			var lr := dv.x * r.x + dv.z * r.z
			var hl: float = car.L / 2 + 0.3
			var hw: float = car.W / 2 + 0.3
			# people see a fast car coming at them and dive out of the way
			if sp > 7.0 and lf > hl and lf < hl + sp * 0.9 and absf(lr) < hw + 0.6 and not c.dead and not c.ko and c != Game.player:
				Game.main.npc_ai.dodge(c, car, signf(lr) if lr != 0.0 else 1.0)
			if absf(lf) < hl and absf(lr) < hw:
				var push := hw - absf(lr)
				var push_f := hl - absf(lf)
				var np: Vector3 = c.global_position
				if push < push_f:
					np += r * (signf(lr) if lr != 0.0 else 1.0) * push
				else:
					np += f * (signf(lf) if lf != 0.0 else 1.0) * push_f
				c.global_position = np
				if sp > 6.0 and not c.dead and not c.ko and Game.t - c.mem.get("hit_by_car_t", -9.0) > 1.0:
					c.mem.hit_by_car_t = Game.t
					Game.main.on_run_over(c, car, sp)

func _rail_step(car: Vehicle, tgt: Vector3, speed: float, dt: float) -> void:
	var p := car.global_position
	var to := Vector3(tgt.x - p.x, 0, tgt.z - p.z)
	var dist := to.length()
	if dist < 0.01:
		return
	var dir := to / dist
	var yaw := car.yaw()
	yaw += U.ang_diff(yaw, atan2(dir.x, dir.z)) * minf(1.0, dt * 3.0)
	var np := p + U.fwd(yaw) * minf(speed * dt, dist)
	car.global_transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(np.x, maxf(p.y, 0.06), np.z))
