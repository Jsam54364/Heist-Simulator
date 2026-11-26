extends Node
## Wanted level, police dispatch (cars that drive the road graph, deploy officers,
## chase you), the search circle, recognition by patrols, busts and the helicopter.
## Port of police.js.

var units: Array = []
var heli := {"node": null, "rotor": null, "spot": null, "leaving": false}
var perc_t := 0.0
var susp := 0.0

func W() -> Dictionary:
	return Game.wanted

func raise_stars(n: int, pos: Vector3, reason := "") -> void:
	var w := W()
	n = mini(5, n)
	if n <= w.stars:
		if w.stars > 0 and w.seen_ago > 3.0:
			w.last = pos
		return
	var was: int = w.stars
	w.stars = n
	w.last = pos
	w.seen_ago = 0.0
	w.clear = 0.0
	w.searching = false
	if reason != "":
		Game.notify("%s %s" % ["*".repeat(n), reason], "bad")
	if was == 0:
		Sfx.play("bad", 0.7)

func clear_stars(msg := "") -> void:
	var w := W()
	if w.stars == 0:
		return
	w.stars = 0
	w.clear = 0.0
	Game.notify(msg if msg != "" else "You lost the police", "good")
	Sfx.play("good")
	for u in units:
		u.state = "leave"
		u.route = []

func search_radius() -> float:
	return 30.0 + W().stars * 18.0

func spawn_unit() -> Dictionary:
	var P = Game.player
	var from: Vector3 = P.in_car.global_position if P.in_car else P.global_position
	var n := Roads.far_node(from, 65.0, 140.0)
	var car: Vehicle = Game.main.spawn_car("police", n, U.ang_to(n, W().last))
	car.siren = true
	car.ai = {"kind": "police"}
	var cops := []
	for i in 2:
		var c: Character = Game.main.spawn_char("cop", n, {"hp": 60.0})
		c.in_car = car
		c.set_hidden(true)
		cops.append(c)
	var u := {"car": car, "cops": cops, "state": "respond", "route": [], "ri": 0, "replan": 0.0}
	for c in cops:
		c.mem.unit = u
	units.append(u)
	return u

func remove_unit(u: Dictionary) -> void:
	for c in u.cops:
		if is_instance_valid(c):
			Game.main.remove_char(c)
	var car = u.car
	if is_instance_valid(car) and Game.player.in_car != car:
		Game.main.remove_car(car)
	units.erase(u)

func unit_target() -> Vector3:
	var w := W()
	if w.searching:
		w.search_pick -= get_physics_process_delta_time()
		if w.search_pick <= 0.0:
			var rr := search_radius() * 0.8
			var a := randf() * TAU
			var r := sqrt(randf()) * rr
			w.search_pt = w.last + Vector3(cos(a) * r, 0, sin(a) * r)
			w.search_pick = 7.0
		return w.search_pt
	var P = Game.player
	return P.in_car.global_position if P.in_car else P.global_position

func follow_route(u: Dictionary, dt: float, vmax: float) -> void:
	var car: Vehicle = u.car
	if u.route.is_empty() or u.ri >= u.route.size():
		car.drive_to(car.global_position, 0, dt, {"stop": true})
		return
	var wp: Vector3 = u.route[u.ri]
	var last: bool = u.ri == u.route.size() - 1
	var opts := {"arrive": last}
	if not last:
		opts.next = u.route[u.ri + 1]
	if car.drive_to(wp, vmax, dt, opts) < (3.0 if last else 6.0):
		u.ri += 1

func update_unit(u: Dictionary, dt: float) -> void:
	var P = Game.player
	var car: Vehicle = u.car
	if not is_instance_valid(car):
		units.erase(u)
		return
	var ppos: Vector3 = P.in_car.global_position if P.in_car else P.global_position
	var alive: Array = u.cops.filter(func(c): return is_instance_valid(c) and not c.dead and not c.ko)
	if alive.is_empty() and u.state != "leave":
		u.state = "abandoned"
	var dcar := U.d2(car.global_position, ppos)
	if car.driver == "player" or car.removed:
		for c in alive:
			if c.in_car == null:
				cop_on_foot(c, dt)
		if alive.is_empty() or (W().stars == 0 and alive.all(func(c): return U.d2(c.global_position, ppos) > 40.0)):
			for c in u.cops:
				if is_instance_valid(c) and c.in_car != car:
					Game.main.remove_char(c)
			units.erase(u)
		return
	if u.state == "patrol":
		car.siren = false
		if W().stars > 0:
			u.state = "respond"
			u.route = []
		else:
			if u.route.is_empty() or u.ri >= u.route.size():
				u.route = Roads.plan(car.global_position, Roads.far_node(car.global_position, 40.0, 160.0))
				u.ri = 0
			follow_route(u, dt, 11.0)
			return
	if u.state in ["leave", "abandoned"]:
		var all_in := true
		for c in alive:
			if c.in_car != null:
				continue
			all_in = false
			if c.nav_move(car.global_position, 4.0, dt) < 2.2:
				c.in_car = car
				c.set_hidden(true)
		if u.state == "abandoned" or dcar > 90.0:
			if dcar > 45.0 or (u.state == "abandoned" and dcar > 25.0):
				remove_unit(u)
			return
		car.siren = false
		if all_in:
			if u.route.is_empty():
				u.route = Roads.plan(car.global_position, Roads.far_node(car.global_position, 120.0, 400.0))
				u.ri = 0
			follow_route(u, dt, 14.0)
			if dcar > 70.0:
				remove_unit(u)
		else:
			car.drive_to(car.global_position, 0, dt, {"stop": true})
		return
	car.siren = true
	var tgt := unit_target()
	var any_out: bool = alive.any(func(c): return c.in_car == null)
	var any_in: bool = alive.any(func(c): return c.in_car != null)
	if u.state in ["respond", "chase"]:
		var see_p: bool = dcar < 50.0 and Game.main.los(car.global_position + Vector3(0, 1.3, 0), ppos + Vector3(0, 1.0, 0))
		if P.in_car and see_p and not W().searching:
			u.state = "chase"
			var pc: Vehicle = P.in_car
			var lead: Vector3 = ppos + pc.fwd_dir() * clampf(pc.speed() * 0.5, -3.0, 8.0)
			car.drive_to(lead, 30.0, dt, {"arrive": false})
		else:
			u.state = "respond"
			u.replan -= dt
			if u.route.is_empty() or u.replan <= 0.0:
				u.route = Roads.plan(car.global_position, tgt)
				u.ri = 0
				u.replan = 2.5
			var dt_g := U.d2(car.global_position, tgt)
			if dt_g < (8.0 if P.in_car else 20.0) or u.ri >= u.route.size():
				if P.in_car == null or W().searching:
					u.state = "deploy"
				else:
					car.drive_to(tgt, 20.0, dt, {"arrive": false})
			else:
				follow_route(u, dt, 26.0)
	if u.state == "deploy":
		car.drive_to(car.global_position, 0, dt, {"stop": true})
		if absf(car.speed()) < 1.0:
			var i := 0
			for c in u.cops:
				if not is_instance_valid(c) or c.in_car == null or c.dead:
					continue
				c.in_car = null
				c.set_hidden(false)
				var side := U.right(car.yaw()) * (1.6 if i else -1.6)
				c.teleport(car.global_position + side)
				i += 1
			u.state = "onfoot"
	if u.state == "onfoot":
		car.drive_to(car.global_position, 0, dt, {"stop": true})
		if (P.in_car and dcar > 22.0) or U.d2(car.global_position, tgt) > 70.0:
			var all_in := true
			for c in alive:
				if c.in_car != null:
					continue
				all_in = false
				if c.nav_move(car.global_position, 5.5, dt) < 2.4:
					c.in_car = car
					c.set_hidden(true)
			if all_in:
				u.state = "respond"
				u.route = []
		else:
			for c in alive:
				if c.in_car == null:
					cop_on_foot(c, dt)
			if not any_out and any_in:
				u.state = "respond"

func cop_on_foot(c: Character, dt: float) -> void:
	var P = Game.player
	var w := W()
	c.dist_p = U.d2(c.global_position, P.global_position)
	c.perc_t -= dt
	if c.perc_t <= 0.0:
		c.perc_t = 0.2
		c.sees = not P.dead and P.in_car == null and c.can_see(P.global_position, 45.0, -0.3)
	c.show_gun = true
	if P.in_car or P.dead:
		c.pose = "stand"
		c.speed_now = 0.0
		return
	if c.sees and w.stars >= 2 and c.dist_p < 32.0:
		c.pose = "aim"
		c.speed_now = 0.0
		c.face_to(P.global_position, dt, 8.0)
		c.cd -= dt
		if c.cd <= 0.0:
			c.cd = randf_range(0.8, 1.3)
			var hc := clampf(0.5 - c.dist_p * 0.011 - (0.15 if P.speed_now > 4.0 else 0.0) - (0.05 if Game.tools.armor else 0.0), 0.08, 0.55)
			Game.main.npc_ai.npc_shoot(c, P, hc, 8.0)
		if c.dist_p > 14.0:
			c.nav_move(P.global_position, 2.5, dt)
		return
	if c.sees and w.stars == 1:
		c.pose = "aim"
		if c.dist_p > 1.3:
			c.nav_move(P.global_position, 3.6, dt, 0.5)
		else:
			c.speed_now = 0.0
		if P.aim_target == c:
			raise_stars(2, P.global_position, "Threatening an officer")
		return
	c.pose = "stand"
	c.nav_move(w.search_pt if w.searching else w.last, 4.2, dt)

# ---------- helicopter ----------
func make_heli(pos: Vector3) -> void:
	var root := Node3D.new()
	Game.world.add_child(root)
	root.position = pos
	var mat := Mats.solid(Color("1b2f63"), 0.4, 0.3)
	var body := MeshInstance3D.new()
	var bm := CapsuleMesh.new()
	bm.radius = 1.1
	bm.height = 5.0
	body.mesh = bm
	body.rotation.x = PI / 2
	body.material_override = mat
	root.add_child(body)
	var tail := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.4, 0.4, 4.0)
	tail.mesh = tm
	tail.material_override = mat
	tail.position = Vector3(0, 0.4, -4.2)
	root.add_child(tail)
	var rotor := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(9, 0.08, 0.4)
	rotor.mesh = rm
	rotor.material_override = Mats.solid(Color("111111"), 0.5)
	rotor.position.y = 1.2
	root.add_child(rotor)
	var spot := SpotLight3D.new()
	spot.light_energy = 6.0
	spot.spot_range = 60.0
	spot.spot_angle = 14.0
	spot.light_color = Color("fff7c2")
	spot.shadow_enabled = false
	root.add_child(spot)
	heli.node = root
	heli.rotor = rotor
	heli.spot = spot
	heli.leaving = false

func update_heli(dt: float) -> void:
	var P = Game.player
	var w := W()
	var ppos: Vector3 = P.in_car.global_position if P.in_car else P.global_position
	if w.stars >= 3 and heli.node == null:
		var a := randf() * TAU
		make_heli(ppos + Vector3(cos(a) * 120, 38, sin(a) * 120))
	if heli.node == null:
		return
	var hn: Node3D = heli.node
	heli.rotor.rotation.y += dt * 30.0
	if w.stars < 3:
		heli.leaving = true
	var tgt: Vector3
	if heli.leaving:
		var away := hn.position - ppos
		away.y = 0
		tgt = hn.position + away.normalized() * 50.0
	elif not w.searching:
		tgt = ppos
	else:
		var a := Game.t * 0.4
		tgt = w.last + Vector3(cos(a) * 18, 0, sin(a) * 18)
	var d := U.d2(hn.position, tgt)
	var sp := minf(18.0, d * 1.2) * dt
	if d > 0.1:
		hn.position.x += (tgt.x - hn.position.x) / d * sp
		hn.position.z += (tgt.z - hn.position.z) / d * sp
	hn.position.y = 34.0
	hn.rotation.y = U.ang_to(hn.position, tgt)
	var aim := tgt if (w.searching or heli.leaving) else ppos
	heli.spot.look_at(Vector3(aim.x, 0, aim.z) + Vector3(0.01, 0, 0.01), Vector3.UP)
	heli.spot.visible = not heli.leaving
	if heli.leaving and U.d2(hn.position, ppos) > 150.0:
		hn.queue_free()
		heli.node = null

func heli_sees() -> bool:
	if heli.node == null or heli.leaving:
		return false
	var P = Game.player
	var pp: Vector3 = P.in_car.global_position if P.in_car else P.global_position
	var hp: Vector3 = heli.node.position
	if U.d2(hp, pp) > 55.0:
		return false
	return Game.main.los(hp - Vector3(0, 1.5, 0), pp + Vector3(0, 1.2, 0))

func any_cop_sees() -> bool:
	var P = Game.player
	var pp: Vector3 = P.in_car.global_position if P.in_car else P.global_position
	var mult := 0.35 if Game.in_garage else 1.0
	for u in units:
		if u.state in ["leave", "abandoned"]:
			continue
		for c in u.cops:
			if not is_instance_valid(c) or c.dead or c.ko:
				continue
			var src: Vector3 = c.in_car.global_position if c.in_car else c.global_position
			if U.d2(src, pp) > 55.0 * mult:
				continue
			if Game.main.los(src + Vector3(0, 1.3 if c.in_car else 1.6, 0), pp + Vector3(0, 1.0, 0)):
				return true
	return heli_sees()

func recognition(dt: float) -> void:
	var P = Game.player
	if P.dead:
		return
	var pp: Vector3 = P.in_car.global_position if P.in_car else P.global_position
	var H := Game.heat
	var outside: bool = Game.cur_building == null
	var matches := false
	var why := ""
	if H.face > 0.0 and not P.masked and P.in_car == null:
		matches = true; why = "Officer recognised your face"
	elif H.outfit == Game.outfit and H.outfit >= 0 and P.in_car == null:
		matches = true; why = "You match the suspect description"
	elif P.in_car and H.car_id == P.in_car.car_id:
		matches = true; why = "Police recognised the getaway car"
	elif P.masked and outside and P.in_car == null:
		matches = true; why = "Masked person spotted by police"
	elif P.weapon and P.in_car == null:
		matches = true; why = "Police saw your weapon"
	var seen := false
	if matches:
		for u in units:
			for c in u.cops:
				if not is_instance_valid(c) or c.dead or c.ko:
					continue
				var src: Vector3 = c.in_car.global_position if c.in_car else c.global_position
				if U.d2(src, pp) < (8.0 if Game.in_garage else 22.0) and Game.main.los(src + Vector3(0, 1.5, 0), pp + Vector3(0, 1.0, 0)):
					seen = true
	if seen:
		susp += dt * (1.5 if P.weapon else 0.7)
	else:
		susp = maxf(0.0, susp - dt * 0.5)
	W().suspicion = susp
	if susp >= 1.0:
		susp = 0.0
		raise_stars(2, pp, why)

func update(dt: float) -> void:
	var P = Game.player
	var w := W()
	var pp: Vector3 = P.in_car.global_position if P.in_car else P.global_position
	perc_t -= dt
	if w.stars > 0:
		if perc_t <= 0.0:
			perc_t = 0.16
			if any_cop_sees():
				w.seen_ago = 0.0
				w.last = pp
				if P.in_car:
					Game.heat.car_id = P.in_car.car_id
					Game.heat.car_color = P.in_car.color_idx
					Game.heat.car_t = 180.0
				else:
					Game.heat.outfit = Game.outfit
					Game.heat.outfit_t = 180.0
					if not P.masked:
						Game.heat.face = maxf(Game.heat.face, 120.0)
		w.seen_ago += dt
		w.searching = w.seen_ago > 4.0
		if w.searching:
			var outside_r := U.d2(pp, w.last) > search_radius()
			w.clear += dt * (1.0 if outside_r else (0.6 if Game.in_garage else 0.3))
			if w.clear > 7.0 + w.stars * 3.0:
				clear_stars()
		else:
			w.clear = maxf(0.0, w.clear - dt * 2.0)
		var want: int = mini(4, w.stars + (1 if w.stars >= 4 else 0))
		var active := units.filter(func(u): return u.state not in ["leave", "abandoned"]).size()
		w.spawn_t -= dt
		if active < want and w.spawn_t <= 0.0:
			spawn_unit()
			w.spawn_t = 3.5
		if P.in_car == null and w.stars <= 2 and not P.dead:
			var close := false
			for u in units:
				for c in u.cops:
					if is_instance_valid(c) and c.in_car == null and not c.dead and not c.ko and U.d2(c.global_position, P.global_position) < 1.7 and P.aim_target != c:
						close = true
			if close and P.speed_now < 4.0:
				P.bust_t += dt
				if P.bust_t > 2.2:
					Game.main.end_life("BUSTED")
			else:
				P.bust_t = maxf(0.0, P.bust_t - dt * 2.0)
		else:
			P.bust_t = 0.0
	else:
		recognition(dt)
		P.bust_t = 0.0
		w.patrol_t -= dt
		if w.patrol_t <= 0.0 and not units.any(func(u): return u.state == "patrol"):
			var u := spawn_unit()
			u.state = "patrol"
			u.car.siren = false
			w.patrol_t = 25.0
	for i in range(units.size() - 1, -1, -1):
		if i < units.size():
			update_unit(units[i], dt)
	update_heli(dt)
	var sv := 0.0
	for u in units:
		if is_instance_valid(u.car) and u.car.siren:
			sv = maxf(sv, clampf(1.0 - U.d2(u.car.global_position, pp) / 90.0, 0.0, 1.0))
	Sfx.set_loop("siren", sv * 0.8)

func reset() -> void:
	while not units.is_empty():
		remove_unit(units[0])
	if heli.node != null:
		heli.node.queue_free()
		heli.node = null
	var w := W()
	w.stars = 0
	w.clear = 0.0
	w.seen_ago = 99.0
	w.searching = false
	susp = 0.0
