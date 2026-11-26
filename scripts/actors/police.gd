extends Node
## Leonida Keys Sheriff - GTA 6-style policing.
##
## Wanted flow (Game.wanted.state):
##   report -> RESPONSE  hollow stars. A 911 call / silent alarm / stolen-car tracker came in.
##                       Units are dispatched from the sheriff's station or from patrols
##                       on the key and have to DRIVE there (real ETA, they never spawn on
##                       you). They don't know who you are unless the report described you.
##   spotted -> PURSUIT  solid stars. A cop (or the helicopter) has eyes on you and you
##                       match the description, have a weapon out, a mask on, or they saw
##                       the crime. They know where you are while they can see you.
##   LOST                flashing stars. Units converge on your last known position.
##   SEARCH              red search area that slowly grows. Leave it or hide (crouch in a
##                       parked car, sit in the garage) to drain the stars. Escaping turns
##                       the area into a HOT ZONE: extra patrols, faster recognition.
##
## Escalation by stars: 1 patrol car, 2 two cars, 3 adds a K9 unit and roadblocks on
## Route 1, 4 adds SWAT and the helicopter plus spike strips, 5-6 more of everything and
## the heli marksman. Cops shoot out tyres, try PIT manoeuvres, call out to you, arrest
## you if you're unarmed and let you surrender. How quickly they shoot depends on your
## criminal profile (Professional / Hardened / Violent / Psycho - Psychos can't surrender).

const STATION_X := 330.0
const UNITS_FOR := [0, 1, 2, 3, 4, 5, 6]
var units: Array = []
var heli := {"node": null, "rotor": null, "spot": null, "leaving": false, "hp": 100.0, "cool": 0.0, "cd": 2.0}
var dogs: Array = []
var roadblocks: Array = []
var perc_t := 0.0
var susp := 0.0
var tracker_t := 0.0
var tracker_car = null
var rb_cool := 0.0
var shout_t := 0.0
var station := Vector3(STATION_X, 0, 0)

func W() -> Dictionary:
	return Game.wanted

func ppos() -> Vector3:
	var P = Game.player
	return P.in_car.global_position if P.in_car else P.global_position

func _ready() -> void:
	set_process(false)

func setup_station(gen: KeysGen) -> void:
	station = Vector3(STATION_X, 0, gen.rc(STATION_X) + 4.0)

# =================================================================== stars & state
## Someone called it in (witness 911, silent alarm, tracker). Police know *where*, not
## necessarily *who*: hollow stars until a unit spots you. `desc` may carry what the caller
## saw: {face: bool, outfit: int, car_id, car_color, weapon: bool}.
func report(n: int, pos: Vector3, reason: String, desc := {}) -> void:
	var w := W()
	n = clampi(n, 1, Game.MAX_STARS)
	_apply_desc(desc)
	if w.state in ["pursuit", "lost"]:
		if n > w.stars:
			w.stars = n
		return
	var was: int = w.stars
	w.stars = maxi(w.stars, n)
	if w.state != "search" or n > was:
		w.state = "response"
		w.last = pos
		w.report_t = 0.0
		w.searching = false
		w.clear = 0.0
	w.reason = reason
	if w.stars > was or was == 0:
		Game.notify("%s  %s - police responding" % ["*".repeat(w.stars), reason], "bad")
		if was == 0:
			Sfx.play("bad", 0.7)

func _apply_desc(desc: Dictionary) -> void:
	var H := Game.heat
	if desc.get("face", false):
		if H.face <= 0.0:
			Game.notify("A witness got a good look at your face", "bad")
		H.face = maxf(H.face, 240.0)
	if desc.get("outfit", -1) >= 0:
		H.outfit = desc.outfit
		H.outfit_t = maxf(H.outfit_t, 180.0)
	if desc.get("car_id", -1) >= 0:
		H.car_id = desc.car_id
		H.car_color = desc.get("car_color", -1)
		H.car_t = maxf(H.car_t, 180.0)
	if desc.get("weapon", false):
		H.weapon = maxf(H.weapon, 120.0)
	if desc.get("partner", false):
		H.partner = maxf(H.partner, 150.0)

## A crime the police saw (or can't miss): straight to pursuit.
func raise_stars(n: int, pos: Vector3, reason := "") -> void:
	var w := W()
	n = clampi(n, 1, Game.MAX_STARS)
	if Game.profile() == "PSYCHO":
		n = maxi(n, 3)
	var was: int = w.stars
	w.stars = maxi(w.stars, n)
	w.last = pos
	w.seen_ago = 0.0
	w.clear = 0.0
	w.searching = false
	var was_state: String = w.state
	w.state = "pursuit"
	if reason != "" and (w.stars > was or was_state != "pursuit"):
		Game.notify("%s %s" % ["*".repeat(w.stars), reason], "bad")
	if was == 0:
		Sfx.play("bad", 0.7)

func escalate(reason: String, by := 1, min_stars := 0) -> void:
	raise_stars(maxi(W().stars + by, min_stars), ppos(), reason)

func clear_stars(msg := "") -> void:
	var w := W()
	if w.stars == 0:
		return
	if w.state in ["search", "lost", "pursuit"]:
		Game.hot_zones.append({"pos": w.last, "r": 70.0 + w.stars * 20.0, "t": 150.0 + w.stars * 30.0})
		Game.record.escapes += 1
	w.stars = 0
	w.state = "none"
	w.clear = 0.0
	w.searching = false
	w.eta = -1.0
	Game.notify(msg if msg != "" else "You lost the police", "good")
	Sfx.play("good")
	for u in units:
		u.state = "leave"
		u.route = []
	for rb in roadblocks.duplicate():
		_remove_roadblock(rb)
	for d in dogs:
		d.state = "return"

func search_radius() -> float:
	return W().get("search_r", 40.0)

func in_hot_zone(p: Vector3) -> bool:
	for z in Game.hot_zones:
		if U.d2(z.pos, p) < z.r:
			return true
	return false

# =================================================================== units
func _dispatch_origin(target: Vector3) -> Vector3:
	var pp := ppos()
	# first choice: a patrol node on the road network out of your sight, 140-280 m away;
	# the station when you're near it (cars roll out of the sheriff's lot)
	if U.d2(station, pp) > 120.0 and U.d2(station, target) < 300.0 and randf() < 0.6:
		return station
	for k in 8:
		var n := Roads.far_node(target, 140.0, 280.0)
		if U.d2(n, pp) < 120.0:
			continue
		if U.d2(n, pp) < 200.0 and Game.main.los(n + Vector3(0, 1.5, 0), pp + Vector3(0, 1.5, 0)):
			continue
		return n
	return Roads.far_node(pp, 180.0, 320.0)

func spawn_unit(kind := "patrol", at = null) -> Dictionary:
	var w := W()
	var origin: Vector3 = at if at != null else _dispatch_origin(w.last if w.stars > 0 else ppos())
	var car_kind := "swat" if kind == "swat" else "police"
	var car: Vehicle = Game.main.spawn_car(car_kind, origin, U.ang_to(origin, w.last if w.stars > 0 else ppos()), {"tracker": true})
	car.siren = w.stars > 0
	car.ai = {"kind": "police"}
	var n := 4 if kind == "swat" else (1 if kind == "k9" else 2)
	var cops := []
	for i in n:
		var opts := {"hp": 140.0 if kind == "swat" else 70.0}
		if kind == "swat":
			opts["color"] = Color("1b2433")
		var c: Character = Game.main.spawn_char("cop", origin, opts)
		c.in_car = car
		c.set_hidden(true)
		c.mem.swat = kind == "swat"
		c.mem.aim = 0.12 if kind == "swat" else 0.0
		cops.append(c)
	var u := {"car": car, "cops": cops, "state": "respond", "route": [], "ri": 0, "replan": 0.0, "kind": kind, "shoot_t": 2.0, "pit_t": 0.0}
	for c in cops:
		c.mem.unit = u
	units.append(u)
	if kind == "k9":
		_spawn_dog(u)
	return u

func remove_unit(u: Dictionary) -> void:
	for c in u.cops:
		if is_instance_valid(c):
			Game.main.remove_char(c)
	var car = u.car
	if is_instance_valid(car) and Game.player.in_car != car:
		Game.main.remove_car(car)
	for d in dogs.duplicate():
		if d.unit == u:
			d.node.queue_free()
			dogs.erase(d)
	units.erase(u)

func unit_target() -> Vector3:
	var w := W()
	if w.state == "response" or w.state == "lost":
		return w.last
	if w.state == "search":
		w.search_pick -= get_physics_process_delta_time()
		if w.search_pick <= 0.0:
			var rr := search_radius() * 0.85
			var a := randf() * TAU
			var r := sqrt(randf()) * rr
			w.search_pt = Game.main.nav.land_point(w.last + Vector3(cos(a) * r, 0, sin(a) * r))
			w.search_pick = 7.0
		return w.search_pt
	return ppos()

## Drive a route; far from the player the car rides it kinematically (no colliders out there).
func follow_route(u: Dictionary, dt: float, vmax: float) -> void:
	var car: Vehicle = u.car
	if u.route.is_empty() or u.ri >= u.route.size():
		car.set_rail(false)
		car.drive_to(car.global_position, 0, dt, {"stop": true})
		return
	var wp: Vector3 = u.route[u.ri]
	var last: bool = u.ri == u.route.size() - 1
	var far: bool = U.d2(car.global_position, ppos()) > 140.0 and U.d2(car.global_position, Game.main.camera.global_position) > 140.0
	far = far or not Game.main.streamer.generated(car.global_position)
	car.set_rail(far, vmax)
	if car.rail:
		var p := car.global_position
		var to := Vector3(wp.x - p.x, 0, wp.z - p.z)
		var dist := to.length()
		if dist < 2.0:
			u.ri += 1
			return
		var yaw := car.yaw()
		yaw += U.ang_diff(yaw, atan2(to.x, to.z)) * minf(1.0, dt * 4.0)
		var np := p + to / dist * minf(vmax * dt, dist)
		car.global_transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(np.x, maxf(p.y, 0.06), np.z))
		return
	var opts := {"arrive": last}
	if not last:
		opts.next = u.route[u.ri + 1]
	if car.drive_to(wp, vmax, dt, opts) < (3.0 if last else 6.0):
		u.ri += 1

func _route_dist(u: Dictionary) -> float:
	var car: Vehicle = u.car
	if u.route.is_empty():
		return U.d2(car.global_position, W().last)
	var d := 0.0
	var p := car.global_position
	for i in range(u.ri, u.route.size()):
		d += U.d2(p, u.route[i])
		p = u.route[i]
	return d

func update_unit(u: Dictionary, dt: float) -> void:
	var P = Game.player
	var car: Vehicle = u.car
	if not is_instance_valid(car):
		units.erase(u)
		return
	var w := W()
	var pp := ppos()
	var alive: Array = u.cops.filter(func(c): return is_instance_valid(c) and not c.dead and not c.ko)
	if alive.is_empty() and u.state != "leave":
		u.state = "abandoned"
	var dcar := U.d2(car.global_position, pp)
	if car.driver == "player" or car.removed:
		for c in alive:
			if c.in_car == null:
				cop_on_foot(c, dt)
		if alive.is_empty() or (w.stars == 0 and alive.all(func(c): return U.d2(c.global_position, pp) > 40.0)):
			for c in u.cops:
				if is_instance_valid(c) and c.in_car != car:
					Game.main.remove_char(c)
			units.erase(u)
		return
	if u.state == "roadblock":
		car.set_rail(not Game.main.streamer.generated(car.global_position), 0.0)
		car.release()
		car.handbrake = true
		for c in alive:
			if c.in_car == null:
				cop_on_foot(c, dt, true)
		return
	if u.state == "patrol":
		car.siren = false
		if w.stars > 0 and (w.state != "response" or U.d2(car.global_position, w.last) < 400.0):
			u.state = "respond"
			u.route = []
		else:
			if u.route.is_empty() or u.ri >= u.route.size():
				var tgt := Roads.far_node(car.global_position, 60.0, 220.0)
				if not Game.hot_zones.is_empty() and randf() < 0.6:
					var z: Dictionary = Game.hot_zones[randi() % Game.hot_zones.size()]
					tgt = Roads.closest_road_point(z.pos)
				u.route = Roads.plan(car.global_position, tgt)
				u.ri = 0
			follow_route(u, dt, 12.0)
			if dcar > 600.0:
				remove_unit(u)
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
				u.route = Roads.plan(car.global_position, Roads.far_node(car.global_position, 160.0, 400.0))
				u.ri = 0
			follow_route(u, dt, 14.0)
			if dcar > 120.0:
				remove_unit(u)
		else:
			car.drive_to(car.global_position, 0, dt, {"stop": true})
		return
	car.siren = true
	var tgt := unit_target()
	var any_out: bool = alive.any(func(c): return c.in_car == null)
	var any_in: bool = alive.any(func(c): return c.in_car != null)
	if u.state in ["respond", "chase"]:
		var see_p: bool = w.state == "pursuit" and dcar < 60.0 and Game.main.los(car.global_position + Vector3(0, 1.3, 0), pp + Vector3(0, 1.0, 0))
		if P.in_car and see_p:
			u.state = "chase"
			car.set_rail(false)
			_chase(u, dt)
		else:
			u.state = "respond"
			u.replan -= dt
			if u.route.is_empty() or u.replan <= 0.0:
				u.route = Roads.plan(car.global_position, tgt)
				u.ri = 0
				u.replan = 3.0
			var dt_g := U.d2(car.global_position, tgt)
			var close := 8.0 if (P.in_car and w.state == "pursuit") else 22.0
			if dt_g < close or u.ri >= u.route.size():
				if P.in_car == null or w.state != "pursuit":
					u.state = "deploy"
				else:
					car.set_rail(false)
					car.drive_to(tgt, 20.0, dt, {"arrive": false})
			else:
				follow_route(u, dt, 30.0 if w.state == "pursuit" else 26.0)
	if u.state == "deploy":
		car.set_rail(false)
		car.drive_to(car.global_position, 0, dt, {"stop": true})
		if absf(car.speed()) < 1.0:
			var i := 0
			for c in u.cops:
				if not is_instance_valid(c) or c.in_car == null or c.dead:
					continue
				c.in_car = null
				c.set_hidden(false)
				var side := U.right(car.yaw()) * (1.6 if i % 2 else -1.6) - car.fwd_dir() * (i / 2) * 1.2
				c.teleport(Game.main.nav.free_point(car.global_position + side))
				i += 1
			for d in dogs:
				if d.unit == u and d.state == "car":
					d.state = "track"
					d.node.visible = true
					d.pos = car.global_position + U.right(car.yaw()) * 2.0
			u.state = "onfoot"
			if w.state == "pursuit" and shout_t <= 0.0 and dcar < 40.0:
				_shout("POLICE! %s" % ("DROP THE WEAPON!" if P.weapon else "GET ON THE GROUND!"))
	if u.state == "onfoot":
		car.drive_to(car.global_position, 0, dt, {"stop": true})
		if (P.in_car and dcar > 26.0 and w.state == "pursuit") or U.d2(car.global_position, tgt) > 80.0:
			var all_in := true
			for c in alive:
				if c.in_car != null:
					continue
				all_in = false
				if c.nav_move(car.global_position, 5.5, dt) < 2.4:
					c.in_car = car
					c.set_hidden(true)
			for d in dogs:
				if d.unit == u and d.state != "car":
					d.state = "return"
			if all_in:
				u.state = "respond"
				u.route = []
		else:
			for c in alive:
				if c.in_car == null:
					cop_on_foot(c, dt)
			if not any_out and any_in:
				u.state = "respond"

## Car chase: lead the target, PIT when lined up on a rear quarter, passengers shoot tyres.
func _chase(u: Dictionary, dt: float) -> void:
	var P = Game.player
	var car: Vehicle = u.car
	var pc: Vehicle = P.in_car
	var pp := pc.global_position
	var pf := pc.fwd_dir()
	var psp: float = pc.speed()
	var rel := car.global_position - pp
	var behind := rel.dot(pf)
	var lateral := rel.dot(Vector3(-pf.z, 0, pf.x))
	var aggressive: bool = W().stars >= 2 or Game.profile() in ["VIOLENT", "PSYCHO"]
	u.pit_t = maxf(0.0, u.pit_t - dt)
	if aggressive and behind < -1.0 and behind > -9.0 and absf(lateral) < 3.5 and psp > 9.0 and u.pit_t <= 0.0:
		# PIT: aim for the rear quarter and push through it
		var side := signf(lateral) if lateral != 0.0 else 1.0
		var hit := pp - pf * (pc.L * 0.35) + Vector3(-pf.z, 0, pf.x) * side * 0.6
		car.drive_to(hit, psp + 5.0, dt, {"arrive": false})
		if absf(lateral) < 1.8 and behind > -4.0:
			u.pit_t = 6.0
	else:
		var lead: Vector3 = pp + pf * clampf(psp * 0.5, -3.0, 9.0)
		car.drive_to(lead, 32.0, dt, {"arrive": false})
	# passenger fire: tyres at 3+ stars, the driver at 4+
	u.shoot_t -= dt
	var dist := U.d2(car.global_position, pp)
	if u.shoot_t <= 0.0 and dist < 28.0:
		u.shoot_t = randf_range(1.6, 2.6)
		var shooter = null
		for c in u.cops:
			if is_instance_valid(c) and not c.dead and c.in_car == car:
				shooter = c
		if shooter != null and W().stars >= 3 and Game.main.los(car.global_position + Vector3(0, 1.3, 0), pp + Vector3(0, 0.6, 0)):
			Game.main.fx.tracer(car.global_position + Vector3(0, 1.3, 0), pp + Vector3(randf_range(-1, 1), 0.4, randf_range(-1, 1)))
			Sfx.play("npc_shot", clampf(1.0 - dist / 60.0, 0.2, 1.0))
			if randf() < 0.22 and pc.tires_burst < 4:
				pc.burst_tire()
				Game.notify("They shot out a tyre!", "bad")
			elif W().stars >= 4 and randf() < 0.3:
				Game.main.damage(P, 5.0, shooter)

# =================================================================== cops on foot
func _shout(text: String) -> void:
	shout_t = 6.0
	Game.notify(text, "bad")

func shoots_on_sight() -> bool:
	var prof := Game.profile()
	var s: int = W().stars
	if prof == "PSYCHO":
		return true
	if prof == "VIOLENT":
		return s >= 2
	if prof == "HARDENED":
		return s >= 3 or (s >= 2 and Game.player.weapon)
	return s >= 3 or (Game.player.weapon and Game.player.aim_target != null and Game.player.aim_target.role == "cop")

func cop_on_foot(c: Character, dt: float, hold := false) -> void:
	var P = Game.player
	var w := W()
	var pp: Vector3 = P.global_position
	c.dist_p = U.d2(c.global_position, pp)
	c.perc_t -= dt
	if c.perc_t <= 0.0:
		c.perc_t = 0.2
		c.sees = not P.dead and P.in_car == null and c.can_see(pp, 45.0, -0.3)
	c.show_gun = true
	if P.dead:
		c.pose = "stand"
		c.speed_now = 0.0
		return
	if P.in_car:
		# aim at the car; roadblock cops fire at an approaching car
		var car: Vehicle = P.in_car
		var dc := U.d2(c.global_position, car.global_position)
		if dc < 40.0:
			c.pose = "aim"
			c.speed_now = 0.0
			c.face_to(car.global_position, dt, 8.0)
			c.cd -= dt
			if c.cd <= 0.0 and w.stars >= 3 and Game.main.los(c.global_position + Vector3(0, 1.5, 0), car.global_position + Vector3(0, 0.8, 0)):
				c.cd = randf_range(1.0, 1.6)
				Game.main.fx.tracer(c.global_position + Vector3(0, 1.4, 0), car.global_position + Vector3(randf_range(-1, 1), 0.5, randf_range(-1, 1)))
				Sfx.play("npc_shot", clampf(1.0 - dc / 60.0, 0.2, 1.0))
				if randf() < 0.12 and car.tires_burst < 4:
					car.burst_tire()
				elif randf() < 0.2:
					Game.main.damage(P, 4.0, c)
			# pull the driver out of a stopped car
			if dc < 3.4 and absf(car.speed()) < 1.2 and w.stars <= 3 and not shoots_on_sight():
				P.bust_t += dt * 0.6
		else:
			c.pose = "stand"
			c.speed_now = 0.0
		return
	if P.surrendering and Game.profile() != "PSYCHO":
		# move in and cuff
		c.pose = "aim"
		c.face_to(pp, dt, 8.0)
		if c.dist_p > 1.2:
			c.nav_move(pp, 3.2, dt, 0.5)
		else:
			c.speed_now = 0.0
			P.bust_t += dt * 1.6
		return
	if c.sees and shoots_on_sight() and c.dist_p < 34.0:
		c.pose = "aim"
		c.speed_now = 0.0
		c.face_to(pp, dt, 8.0)
		c.cd -= dt
		if c.cd <= 0.0:
			c.cd = randf_range(0.7, 1.2) * (0.8 if c.mem.get("swat", false) else 1.0)
			var hc := clampf(0.5 + c.mem.get("aim", 0.0) - c.dist_p * 0.011 - (0.15 if P.speed_now > 4.0 else 0.0) - (0.05 if Game.tools.armor else 0.0), 0.08, 0.6)
			Game.main.npc_ai.npc_shoot(c, P, hc, 9.0 if c.mem.get("swat", false) else 8.0)
		if c.dist_p > 14.0 and not hold:
			c.nav_move(pp, 2.6, dt)
		return
	if c.sees and w.stars >= 1:
		# arrest attempt: guns up, close in, "hands where I can see them"
		c.pose = "aim"
		c.face_to(pp, dt, 8.0)
		if c.dist_p > 1.3 and not hold:
			c.nav_move(pp, 3.8, dt, 0.5)
		else:
			c.speed_now = 0.0
		if shout_t <= 0.0 and c.dist_p < 20.0:
			_shout("COP: \"%s\"" % ["Hands where I can see them!", "Don't move!", "Get on the ground, now!", "Sheriff's office - stop right there!"][randi() % 4])
		if P.aim_target == c:
			raise_stars(maxi(w.stars, 3), pp, "Threatening an officer")
		return
	if hold:
		c.pose = "aim" if w.stars > 0 else "stand"
		c.speed_now = 0.0
		return
	c.pose = "stand"
	c.nav_move(w.search_pt if w.state == "search" else w.last, 4.2, dt)

# =================================================================== K9
func _spawn_dog(u: Dictionary) -> void:
	var root := Node3D.new()
	var mat := Mats.solid(Color("4a3626"), 0.8)
	var dark := Mats.solid(Color("1e1712"), 0.8)
	var parts := [[Vector3(0.32, 0.32, 0.85), Vector3(0, 0.55, 0), mat], [Vector3(0.26, 0.26, 0.34), Vector3(0, 0.78, 0.5), mat],
		[Vector3(0.16, 0.14, 0.2), Vector3(0, 0.72, 0.72), dark], [Vector3(0.08, 0.14, 0.05), Vector3(-0.08, 0.96, 0.46), dark],
		[Vector3(0.08, 0.14, 0.05), Vector3(0.08, 0.96, 0.46), dark], [Vector3(0.06, 0.06, 0.36), Vector3(0, 0.68, -0.55), mat]]
	for pt in parts:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = pt[0]
		mi.mesh = bm
		mi.position = pt[1]
		mi.material_override = pt[2]
		mi.layers = 1 | 4
		root.add_child(mi)
	var legs := []
	for lp in [Vector3(-0.1, 0.4, 0.3), Vector3(0.1, 0.4, 0.3), Vector3(-0.1, 0.4, -0.3), Vector3(0.1, 0.4, -0.3)]:
		var leg := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(0.08, 0.42, 0.08)
		leg.mesh = lm
		leg.position = lp - Vector3(0, 0.2, 0)
		leg.material_override = mat
		var pivot := Node3D.new()
		pivot.position = Vector3(lp.x, 0.4, lp.z)
		leg.position = Vector3(0, -0.2, 0)
		pivot.add_child(leg)
		root.add_child(pivot)
		legs.append(pivot)
	root.visible = false
	Game.world.add_child(root)
	dogs.append({"node": root, "legs": legs, "unit": u, "state": "car", "pos": u.car.global_position, "yaw": 0.0, "path": [], "path_t": 0.0, "bite_t": 0.0, "phase": 0.0, "bark_t": 0.0})

func _update_dogs(dt: float) -> void:
	var P = Game.player
	for d in dogs.duplicate():
		var u: Dictionary = d.unit
		if not is_instance_valid(u.car):
			d.node.queue_free()
			dogs.erase(d)
			continue
		if d.state == "car":
			d.node.visible = false
			continue
		var target: Vector3
		var speed := 7.5
		if d.state == "return":
			target = u.car.global_position
			if U.d2(d.pos, target) < 2.0:
				d.state = "car"
				continue
		else:
			# follow the scent: your breadcrumb trail, or straight to you when close
			if P.in_car:
				target = P.in_car.global_position
			elif U.d2(d.pos, P.global_position) < 14.0 or P.crumbs.is_empty():
				target = P.global_position
			else:
				target = P.crumbs[maxi(0, P.crumbs.size() - 8)]
		d.path_t -= dt
		if d.path_t <= 0.0 and Game.main.nav.take_budget():
			d.path = Game.main.nav.find_path(d.pos, target)
			d.path_t = 0.8
		if d.path.is_empty():
			d.path = [target]
		while d.path.size() > 1 and U.d2(d.path[0], d.pos) < 0.6:
			d.path.pop_front()
		var to: Vector3 = d.path[0] - d.pos
		to.y = 0
		var dist := to.length()
		var moving := dist > 0.9
		if moving:
			d.pos += to / dist * minf(speed * dt, dist)
			d.yaw = d.yaw + U.ang_diff(d.yaw, atan2(to.x, to.z)) * minf(1.0, dt * 10.0)
		d.phase += dt * (16.0 if moving else 0.0)
		for i in d.legs.size():
			d.legs[i].rotation.x = sin(d.phase + (PI if i % 3 == 0 else 0.0)) * 0.7
		d.node.position = Vector3(d.pos.x, Game.ground_y(d.pos.x, d.pos.z), d.pos.z)
		d.node.rotation.y = d.yaw
		d.node.visible = true
		if d.state != "track":
			continue
		var dp := U.d2(d.pos, P.global_position)
		d.bark_t -= dt
		if P.in_car:
			# sniffs out a hidden suspect
			if dp < 4.5 and P.in_car.crouched:
				if d.bark_t <= 0.0:
					d.bark_t = 2.0
					Game.notify("The K9 is barking at your car!", "bad")
				_spotted(P.in_car.global_position)
		elif dp < 1.3 and not P.dead:
			d.bite_t -= dt
			if d.bite_t <= 0.0:
				d.bite_t = 0.9
				Game.main.damage(P, 7.0, null)
				P.bust_t += 0.5 if W().stars <= 3 else 0.0
				Sfx.play("kick", 0.7)
				if d.bark_t <= 0.0:
					d.bark_t = 3.0
					Game.notify("K9 takedown! Get away from the dog", "bad")
			_spotted(P.global_position)

# =================================================================== roadblocks + spikes
func _maybe_roadblock(dt: float) -> void:
	var P = Game.player
	var w := W()
	rb_cool -= dt
	if w.stars < 3 or P.in_car == null or w.state != "pursuit" or rb_cool > 0.0 or roadblocks.size() >= (2 if w.stars >= 5 else 1):
		return
	var car: Vehicle = P.in_car
	var gen: KeysGen = Game.main.world_gen
	var p := car.global_position
	if absf(p.z - gen.rc(p.x)) > 10.0 or absf(car.linear_velocity.x) < 9.0:
		return
	var dir := signf(car.linear_velocity.x)
	var x := p.x + dir * randf_range(260.0, 330.0)
	if absf(x) > Roads.R1_END - 30.0:
		return
	rb_cool = 40.0
	var c := gen.rc(x)
	var rb := {"x": x, "dir": dir, "units": [], "strip": null, "strip_x": x - dir * 16.0}
	for k in 2:
		var pos := Vector3(x + k * dir * 2.5, 0, c + (-3.2 if k == 0 else 3.2))
		var u := spawn_unit("patrol", pos)
		u.state = "roadblock"
		var cr: Vehicle = u.car
		cr.global_transform = Transform3D(Basis(Vector3.UP, (PI / 2 if dir < 0.0 else -PI / 2) + (0.45 if k == 0 else -0.45)), Vector3(pos.x, 0.06, pos.z))
		cr.set_rail(true, 0.0)
		cr.siren = true
		var i := 0
		for cp in u.cops:
			cp.in_car = null
			cp.set_hidden(false)
			cp.teleport(pos + Vector3(dir * 3.5, 0, (i - 0.5) * 2.0))
			cp.yaw = PI / 2 if dir < 0.0 else -PI / 2
			i += 1
		rb.units.append(u)
	if w.stars >= 4:
		var strip := Node3D.new()
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.45, 0.06, 11.0)
		mi.mesh = bm
		mi.material_override = Mats.solid(Color("15171a"), 0.6, 0.4)
		strip.add_child(mi)
		for k in 22:
			var sp := MeshInstance3D.new()
			var pm := PrismMesh.new()
			pm.size = Vector3(0.12, 0.12, 0.12)
			sp.mesh = pm
			sp.position = Vector3(0, 0.08, -5.25 + k * 0.5)
			sp.material_override = Mats.solid(Color("c8ccd2"), 0.3, 0.9)
			strip.add_child(sp)
		strip.position = Vector3(rb.strip_x, 0.03, gen.rc(rb.strip_x))
		Game.world.add_child(strip)
		rb.strip = strip
	roadblocks.append(rb)

func _update_roadblocks() -> void:
	var P = Game.player
	var pp := ppos()
	for rb in roadblocks.duplicate():
		if absf(pp.x - rb.x) > 420.0 or (signf(pp.x - rb.x) == rb.dir and absf(pp.x - rb.x) > 120.0):
			_remove_roadblock(rb)
			continue
		if rb.strip != null and P.in_car:
			var car: Vehicle = P.in_car
			var sp: Vector3 = rb.strip.position
			if absf(car.global_position.x - sp.x) < 1.2 + car.L * 0.5 and absf(car.global_position.z - sp.z) < 5.8 and car.tires_burst < 4:
				for k in 4:
					car.burst_tire()
				Game.notify("SPIKE STRIP! All four tyres shredded", "bad")

func _remove_roadblock(rb: Dictionary) -> void:
	for u in rb.units:
		if units.has(u):
			remove_unit(u)
	if rb.strip != null:
		rb.strip.queue_free()
	roadblocks.erase(rb)

# =================================================================== helicopter
func make_heli(pos: Vector3) -> void:
	var root := Node3D.new()
	Game.world.add_child(root)
	root.position = pos
	var mat := Mats.solid(Color("1b2f63"), 0.4, 0.3)
	var white := Mats.solid(Color("e9edf2"), 0.4, 0.2)
	var body := MeshInstance3D.new()
	var bm := CapsuleMesh.new()
	bm.radius = 1.1
	bm.height = 5.0
	body.mesh = bm
	body.rotation.x = PI / 2
	body.material_override = mat
	root.add_child(body)
	var stripe := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(2.25, 0.35, 3.0)
	stripe.mesh = sm
	stripe.material_override = white
	root.add_child(stripe)
	var tail := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.4, 0.4, 4.0)
	tail.mesh = tm
	tail.material_override = mat
	tail.position = Vector3(0, 0.4, -4.2)
	root.add_child(tail)
	for sx in [-0.9, 0.9]:
		var skid := MeshInstance3D.new()
		var km := BoxMesh.new()
		km.size = Vector3(0.12, 0.12, 3.6)
		skid.mesh = km
		skid.material_override = Mats.solid(Color("111111"), 0.5)
		skid.position = Vector3(sx, -1.35, 0)
		root.add_child(skid)
	var rotor := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(9, 0.08, 0.4)
	rotor.mesh = rm
	rotor.material_override = Mats.solid(Color("111111"), 0.5)
	rotor.position.y = 1.2
	root.add_child(rotor)
	var spot := SpotLight3D.new()
	spot.light_energy = 6.0
	spot.spot_range = 70.0
	spot.spot_angle = 14.0
	spot.light_color = Color("fff7c2")
	spot.shadow_enabled = false
	root.add_child(spot)
	heli.node = root
	heli.rotor = rotor
	heli.spot = spot
	heli.leaving = false
	heli.hp = 100.0

func update_heli(dt: float) -> void:
	var w := W()
	var pp := ppos()
	heli.cool = maxf(0.0, heli.cool - dt)
	if w.stars >= 4 and heli.node == null and heli.cool <= 0.0 and w.state != "response":
		var a := randf() * TAU
		make_heli(pp + Vector3(cos(a) * 140, 40, sin(a) * 140))
		Game.notify("Police helicopter overhead", "bad")
	if heli.node == null:
		return
	var hn: Node3D = heli.node
	heli.rotor.rotation.y += dt * 30.0
	if w.stars < 3:
		heli.leaving = true
	var tgt: Vector3
	if heli.leaving:
		var away := hn.position - pp
		away.y = 0
		tgt = hn.position + away.normalized() * 50.0
	elif w.state == "pursuit":
		tgt = pp
	else:
		var a := Game.t * 0.35
		var r := search_radius() * 0.6
		tgt = w.last + Vector3(cos(a) * r, 0, sin(a) * r)
	var d := U.d2(hn.position, tgt)
	var sp := minf(22.0, d * 1.2) * dt
	if d > 0.1:
		hn.position.x += (tgt.x - hn.position.x) / d * sp
		hn.position.z += (tgt.z - hn.position.z) / d * sp
	hn.position.y = lerpf(hn.position.y, 34.0, dt)
	hn.rotation.y = U.ang_to(hn.position, tgt)
	hn.rotation.z = sin(Game.t * 0.7) * 0.05
	var aim := tgt if (w.state != "pursuit" or heli.leaving) else pp
	heli.spot.look_at(Vector3(aim.x, 0, aim.z) + Vector3(0.01, 0, 0.01), Vector3.UP)
	heli.spot.visible = not heli.leaving
	# marksman at 5+ stars
	if not heli.leaving and w.stars >= 5 and heli_sees():
		heli.cd -= dt
		if heli.cd <= 0.0:
			heli.cd = randf_range(1.8, 2.8)
			Game.main.fx.tracer(hn.position - Vector3(0, 1.0, 0), pp + Vector3(randf_range(-0.6, 0.6), 1.0, randf_range(-0.6, 0.6)))
			Sfx.play("npc_shot", 0.6)
			if randf() < (0.15 if Game.player.in_car else 0.3):
				Game.main.damage(Game.player, 8.0, null)
	if heli.leaving and U.d2(hn.position, pp) > 170.0:
		hn.queue_free()
		heli.node = null

## Player bullets that pass near the helicopter damage it; enough fire makes it withdraw.
func shot_ray(start: Vector3, dir: Vector3, max_t: float) -> void:
	if heli.node == null or heli.leaving:
		return
	var hp: Vector3 = heli.node.position
	var t := (hp - start).dot(dir)
	if t < 0.0 or t > maxf(max_t, 80.0):
		return
	if (start + dir * t).distance_to(hp) < 2.6:
		heli.hp -= 9.0
		Game.record.shots_at_cops += 1
		Game.main.fx.tracer(hp, hp + Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)))
		if heli.hp <= 0.0:
			heli.leaving = true
			heli.cool = 90.0
			Game.notify("The helicopter took fire and is pulling back!", "good")
			escalate("Fired on a police helicopter", 0, 4)

func heli_sees() -> bool:
	if heli.node == null or heli.leaving:
		return false
	var pp := ppos()
	var hp: Vector3 = heli.node.position
	if Vector2(hp.x - pp.x, hp.z - pp.z).length() > 75.0:
		return false
	if Game.player.in_car and Game.player.in_car.crouched:
		return false
	if Game.in_garage or Game.cur_building != null:
		return false
	return Game.main.los(hp - Vector3(0, 1.5, 0), pp + Vector3(0, 1.2, 0))

# =================================================================== perception
func _cop_sees(src: Vector3, eye: float, rng: float) -> bool:
	var P = Game.player
	var pp := ppos()
	var mult := 0.35 if Game.in_garage else 1.0
	var d := U.d2(src, pp)
	if P.in_car and P.in_car.crouched:
		rng = 5.0
	if d > rng * mult:
		return false
	return Game.main.los(src + Vector3(0, eye, 0), pp + Vector3(0, 1.0, 0))

func any_cop_sees() -> bool:
	for u in units:
		if u.state in ["leave", "abandoned"]:
			continue
		for c in u.cops:
			if not is_instance_valid(c) or c.dead or c.ko:
				continue
			var src: Vector3 = c.in_car.global_position if c.in_car else c.global_position
			if _cop_sees(src, 1.3 if c.in_car else 1.6, 55.0):
				return true
	return heli_sees()

func _spotted(p: Vector3) -> void:
	var w := W()
	if w.stars == 0:
		return
	if w.state != "pursuit":
		Game.notify("SPOTTED - police have eyes on you", "bad")
	w.state = "pursuit"
	w.seen_ago = 0.0
	w.last = p
	w.searching = false
	w.clear = 0.0

## Do you look like the person they're after (or like trouble)? Returns the reason or "".
func _matches() -> String:
	var P = Game.player
	var H := Game.heat
	if P.in_car:
		if H.car_id == P.in_car.car_id:
			return "Police recognised the car"
		if P.in_car.kind == "police":
			return "Spotted in a stolen police car"
		return ""
	if P.weapon:
		return "Police saw your weapon"
	if H.face > 0.0 and not P.masked:
		return "Officer recognised your face"
	if H.outfit == Game.outfit and H.outfit >= 0:
		return "You match the suspect description"
	if P.masked and Game.cur_building == null:
		return "Masked person spotted by police"
	if H.partner > 0.0 and Game.partner and not Game.partner.hidden and U.d2(Game.partner.global_position, P.global_position) < 6.0:
		return "Police recognised your partner"
	return ""

func recognition(dt: float) -> void:
	var P = Game.player
	if P.dead:
		return
	var w := W()
	var pp := ppos()
	var why := _matches()
	var seen := false
	if why != "":
		for u in units:
			for c in u.cops:
				if not is_instance_valid(c) or c.dead or c.ko:
					continue
				var src: Vector3 = c.in_car.global_position if c.in_car else c.global_position
				if _cop_sees(src, 1.5, 8.0 if Game.in_garage else 24.0):
					seen = true
	var rate := (1.6 if P.weapon else 0.7) * (2.0 if in_hot_zone(pp) else 1.0)
	if w.state == "response" and U.d2(pp, w.last) < 90.0:
		rate *= 2.5   # they're actively looking for someone like you here
	if seen:
		susp += dt * rate
	else:
		susp = maxf(0.0, susp - dt * 0.5)
	w.suspicion = susp
	if susp >= 1.0:
		susp = 0.0
		raise_stars(maxi(w.stars, 2), pp, why)

func _tracker(dt: float) -> void:
	var P = Game.player
	var car = P.in_car
	if car == null or car.personal or not car.tracker or car.kind == "police":
		tracker_t = 0.0
		tracker_car = null
		return
	if tracker_car != car:
		tracker_car = car
		tracker_t = 0.0
	tracker_t += dt
	if tracker_t > 25.0:
		tracker_t = 5.0
		var desc := {"car_id": car.car_id, "car_color": car.color_idx}
		var w := W()
		if w.state in ["none", "response", "search"]:
			report(maxi(1, w.stars), car.global_position, "Stolen car tracker pinged (%s %s)" % [Game.CAR_COLOR_NAMES[clampi(car.color_idx, 0, 7)], car.kind], desc)

# =================================================================== main update
func update(dt: float) -> void:
	var P = Game.player
	var w := W()
	var pp := ppos()
	shout_t = maxf(0.0, shout_t - dt)
	for z in Game.hot_zones.duplicate():
		z.t -= dt
		if z.t <= 0.0:
			Game.hot_zones.erase(z)
	_tracker(dt)
	perc_t -= dt
	var seen_now := false
	if w.stars > 0 and perc_t <= 0.0:
		perc_t = 0.16
		if any_cop_sees():
			seen_now = true
			if w.state == "response":
				# they found someone at the scene: are you who they're looking for?
				var why := _matches()
				if why != "" or (P.in_car == null and P.weapon):
					_spotted(pp)
			else:
				_spotted(pp)
			if w.state == "pursuit":
				if P.in_car:
					Game.heat.car_id = P.in_car.car_id
					Game.heat.car_color = P.in_car.color_idx
					Game.heat.car_t = 180.0
				else:
					Game.heat.outfit = Game.outfit
					Game.heat.outfit_t = 180.0
					if not P.masked:
						Game.heat.face = maxf(Game.heat.face, 120.0)
					if P.weapon:
						Game.heat.weapon = maxf(Game.heat.weapon, 120.0)
	if w.stars > 0:
		_state_machine(dt)
		_dispatch(dt)
		_maybe_roadblock(dt)
		_arrest(dt)
	else:
		recognition(dt)
		P.bust_t = 0.0
		w.eta = -1.0
		w.patrol_t -= dt
		var patrols := units.filter(func(u): return u.state == "patrol").size()
		var want := 2 if in_hot_zone(pp) else 1
		if w.patrol_t <= 0.0 and patrols < want:
			var u := spawn_unit("patrol")
			u.state = "patrol"
			u.car.siren = false
			w.patrol_t = 20.0
	for i in range(units.size() - 1, -1, -1):
		if i < units.size():
			update_unit(units[i], dt)
	_update_dogs(dt)
	_update_roadblocks()
	update_heli(dt)
	var sv := 0.0
	for u in units:
		if is_instance_valid(u.car) and u.car.siren:
			sv = maxf(sv, clampf(1.0 - U.d2(u.car.global_position, pp) / 110.0, 0.0, 1.0))
	Sfx.set_loop("siren", sv * 0.8)

func _state_machine(dt: float) -> void:
	var w := W()
	var pp := ppos()
	var P = Game.player
	match w.state:
		"response":
			w.report_t += dt
			w.searching = false
			# nobody found at the scene for a while: the call goes cold
			if w.report_t > 50.0 + w.stars * 15.0:
				Game.hot_zones.append({"pos": w.last, "r": 90.0, "t": 120.0})
				w.stars = 0
				w.state = "none"
				w.eta = -1.0
				Game.notify("The police didn't find anyone. The area stays hot for a while.", "good")
				for u in units:
					if u.state != "patrol":
						u.state = "leave"
						u.route = []
				return
		"pursuit":
			w.seen_ago += dt
			w.searching = false
			w.clear = maxf(0.0, w.clear - dt * 2.0)
			if w.seen_ago > 2.5:
				w.state = "lost"
		"lost":
			w.seen_ago += dt
			w.searching = false
			if w.seen_ago > 9.0:
				w.state = "search"
				w.search_r = 40.0 + w.stars * 22.0
				w.search_pick = 0.0
				Game.notify("Police are searching the area - stay out of sight", "warn")
		"search":
			w.seen_ago += dt
			w.searching = true
			w.search_r = minf(w.search_r + dt * 1.2, (40.0 + w.stars * 22.0) * 1.6)
			var outside: bool = U.d2(pp, w.last) > w.search_r
			var hidden: bool = Game.in_garage or (P.in_car != null and P.in_car.crouched)
			w.hidden = hidden
			w.clear += dt * (1.0 if outside else (0.75 if hidden else 0.3))
			if w.clear > 8.0 + w.stars * 4.0:
				clear_stars("You escaped. The area is a hot zone for a while.")

func _dispatch(dt: float) -> void:
	var w := W()
	var want: int = UNITS_FOR[clampi(w.stars, 0, 6)]
	var active := units.filter(func(u): return u.state not in ["leave", "abandoned", "roadblock"])
	w.spawn_t -= dt
	if active.size() < want and w.spawn_t <= 0.0:
		var kind := "patrol"
		var has_k9: bool = active.any(func(u): return u.kind == "k9")
		var n_swat := active.filter(func(u): return u.kind == "swat").size()
		if w.stars >= 3 and not has_k9 and Game.player.in_car == null:
			kind = "k9"
		elif w.stars >= 4 and n_swat < (2 if w.stars >= 5 else 1):
			kind = "swat"
		spawn_unit(kind)
		w.spawn_t = 4.0 if w.state == "pursuit" else 6.0
	# ETA of the nearest responding unit (shown while police are on their way)
	var eta := -1.0
	if w.state == "response":
		for u in active:
			if u.state == "respond" and is_instance_valid(u.car):
				var t := _route_dist(u) / 22.0
				if eta < 0.0 or t < eta:
					eta = t
			elif u.state in ["deploy", "onfoot"]:
				eta = 0.0
	w.eta = eta

func _arrest(dt: float) -> void:
	var P = Game.player
	var w := W()
	if P.dead:
		return
	if P.in_car == null and not P.surrendering and w.stars <= 2 and not shoots_on_sight() and not P.weapon:
		var close := false
		for u in units:
			for c in u.cops:
				if is_instance_valid(c) and c.in_car == null and not c.dead and not c.ko and U.d2(c.global_position, P.global_position) < 1.8:
					close = true
		if close and P.speed_now < 4.0:
			P.bust_t += dt
		else:
			P.bust_t = maxf(0.0, P.bust_t - dt * 1.5)
	elif not P.surrendering and P.in_car == null:
		P.bust_t = maxf(0.0, P.bust_t - dt * 1.5)
	if P.bust_t > 2.2:
		Game.record.busts += 1
		Game.main.end_life("BUSTED", "You surrendered to the Leonida Keys Sheriff" if P.surrendering else "")

## Can the player give up right now? (cops close, on foot, not a psycho)
func can_surrender() -> bool:
	var P = Game.player
	if W().stars == 0 or P.in_car != null or P.dead or Game.profile() == "PSYCHO":
		return false
	for u in units:
		for c in u.cops:
			if is_instance_valid(c) and c.in_car == null and not c.dead and U.d2(c.global_position, P.global_position) < 30.0:
				return true
	return false

func reset() -> void:
	while not units.is_empty():
		remove_unit(units[0])
	for rb in roadblocks.duplicate():
		_remove_roadblock(rb)
	for d in dogs:
		d.node.queue_free()
	dogs.clear()
	if heli.node != null:
		heli.node.queue_free()
		heli.node = null
	var w := W()
	w.stars = 0
	w.state = "none"
	w.clear = 0.0
	w.seen_ago = 99.0
	w.searching = false
	w.eta = -1.0
	susp = 0.0
	tracker_t = 0.0
