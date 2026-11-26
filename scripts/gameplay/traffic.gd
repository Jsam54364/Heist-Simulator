extends Node
## Ambient traffic driving lane loops around the blocks, braking for cars and people
## ahead, plus vehicle-vs-pedestrian contact (push-out and run-overs).

func spawn() -> void:
	var li := 0
	for loop in Roads.LOOPS:
		var pts: Array = Roads.lane_loop(loop)
		var a: Vector3 = pts[0]
		var b: Vector3 = pts[1]
		var t := 0.3 + (li % 3) * 0.15
		var p := a.lerp(b, t)
		var car: Vehicle = Game.main.spawn_car("civ", p, U.ang_to(a, b))
		car.ai = {"kind": "traffic", "pts": pts, "idx": 1}
		var d: Character = Game.main.spawn_char("driver", p)
		d.in_car = car
		d.set_hidden(true)
		car.npc_driver = d
		li += 1

func update(dt: float) -> void:
	var P = Game.player
	for car in Game.cars:
		if car.ai.get("kind", "") != "traffic" or car.driver == "player":
			continue
		if car.npc_driver == null:
			car.release()
			continue
		var ai: Dictionary = car.ai
		var tgt: Vector3 = ai.pts[ai.idx]
		if U.d2(car.global_position, tgt) < 5.0:
			ai.idx = (ai.idx + 1) % ai.pts.size()
		var f: Vector3 = car.fwd_dir()
		var blocked := false
		for o in Game.cars:
			if o == car:
				continue
			var dv: Vector3 = o.global_position - car.global_position
			var lf := dv.x * f.x + dv.z * f.z
			var lr := absf(dv.x * f.z - dv.z * f.x)
			if lf > 0.0 and lf < 10.0 and lr < 1.85:
				blocked = true
				break
		if not blocked:
			for c in Game.chars:
				if c.hidden or c.dead:
					continue
				var dv: Vector3 = c.global_position - car.global_position
				var lf := dv.x * f.x + dv.z * f.z
				var lr := absf(dv.x * f.z - dv.z * f.x)
				if lf > 0.0 and lf < 7.0 and lr < 1.6:
					blocked = true
					break
		if Game.wanted.stars >= 3 and U.d2(P.global_position, car.global_position) < 30.0:
			blocked = false
		var nxt: Vector3 = ai.pts[(ai.idx + 1) % ai.pts.size()]
		car.drive_to(ai.pts[ai.idx], 0.0 if blocked else 12.0, dt, {"arrive": false, "stop": blocked, "next": nxt})

func contacts() -> void:
	# cars ignore people physically (so a cop standing in the road can't flip a truck);
	# people get pushed out of car footprints and knocked down by fast cars
	for car in Game.cars:
		var sp: float = car.linear_velocity.length()
		var f: Vector3 = car.fwd_dir()
		f.y = 0
		f = f.normalized()
		var r := Vector3(-f.z, 0, f.x)
		var cp: Vector3 = car.global_position
		for c in Game.chars:
			if c.hidden or c.in_car != null:
				continue
			var dv: Vector3 = c.global_position - cp
			if absf(dv.x) > 5.0 or absf(dv.z) > 5.0:
				continue
			var lf := dv.x * f.x + dv.z * f.z
			var lr := dv.x * r.x + dv.z * r.z
			var hl: float = car.L / 2 + 0.3
			var hw: float = car.W / 2 + 0.3
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
