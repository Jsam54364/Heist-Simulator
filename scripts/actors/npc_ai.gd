extends Node
## NPC behaviour by role: shoppers & tellers (fear, cowering, heroes, fleeing to
## call 911, silent alarms), store clerks (empty the register at gunpoint), guards
## (surrender or shoot), the armored-truck guard, the partner (crowd control,
## carries a bag, fights cops) and pedestrians. Port of npc.js.

func npc_shoot(c: Character, target: Character, hit_chance: float, dmg: float) -> void:
	var a := c.global_position + Vector3(0, 1.4, 0) + U.fwd(c.yaw) * 0.4
	var b := target.global_position + Vector3(0, 1.1 + randf() * 0.5, 0)
	var hit := randf() < hit_chance
	if not hit:
		b += Vector3(randf_range(-1.5, 1.5), randf_range(-0.4, 0.8), randf_range(-1.5, 1.5))
	var blk = Game.main.ray(a, b, Game.L_WORLD)
	if blk:
		b = blk.position
	Game.main.fx.tracer(a, b)
	Sfx.play("npc_shot", clampf(1.0 - U.d2(c.global_position, Game.player.global_position) / 60.0, 0.1, 1.0))
	if hit and not blk:
		Game.main.damage(target, dmg, c)

func suspicious(P, site) -> bool:
	if P.weapon or (P.action != null and P.action.get("crime", false)):
		return true
	if site != null and U.in_bounds(P.global_position, site.bounds):
		return site.robbery_active or P.masked
	return false

func perceive(c: Character, dt: float) -> void:
	c.perc_t -= dt
	if c.perc_t > 0.0:
		return
	c.perc_t = 0.2 + randf() * 0.05
	var P = Game.player
	c.dist_p = U.d2(c.global_position, P.global_position)
	c.sees = P.in_car == null and not P.dead and c.dist_p < 28.0 and c.can_see(P.global_position, 28.0, -0.1)
	if c.sees and c.site != null and c.dist_p < 16.0 and suspicious(P, c.site):
		c.saw_crime = true
		c.saw_outfit = Game.outfit
		if not P.masked:
			c.saw_face = true

func hear_noise(c: Character):
	for n in Game.noise:
		if U.d2(n.pos, c.global_position) < n.r:
			return n
	return null

func crowd_held(site) -> bool:
	var pt = Game.partner
	return pt != null and pt.mem.get("crowd_site") == site and pt.mem.get("at_crowd", false) and site != null

func update_fear(c: Character, dt: float) -> void:
	var P = Game.player
	if crowd_held(c.site):
		c.fear = 1.0
		return
	if P.aim_target == c:
		c.fear += 2.2 * dt
		c.last_aimed = Game.t
	elif P.weapon and c.sees and c.dist_p < 14.0:
		c.fear += 0.9 * dt
	else:
		c.fear -= 0.07 * dt
	if hear_noise(c) != null:
		c.fear += 0.8
	if c.site != null and c.site.alarm_triggered:
		c.fear = maxf(c.fear, 0.25)
	c.fear = clampf(c.fear, 0.0, 1.0)

func staff_alarm(c: Character, dt: float) -> void:
	var s = c.site
	if s == null:
		return
	var at: float = c.mem.get("alarm_t", 0.0)
	if s.robbery_active and c.saw_crime and s.alarm_armed and not s.alarm_triggered and not crowd_held(s) and c.fear < 0.4:
		at += dt
		if at > 3.2:
			Game.robbery.trigger_alarm(s, "A teller hit the silent alarm" if c.role == "teller" else "Staff hit the silent alarm")
	else:
		at = maxf(0.0, at - dt * 0.5)
	c.mem.alarm_t = at

func wander_in(c: Character, b: Rect2, dt: float) -> void:
	var wait: float = c.mem.get("w_wait", 0.0)
	if not c.mem.has("w_target") or wait > 0.0:
		wait -= dt
		c.speed_now = 0.0
		if wait <= 0.0:
			c.mem.w_target = Vector3(randf_range(b.position.x, b.end.x), 0, randf_range(b.position.y, b.end.y))
			wait = 0.0
		c.mem.w_wait = wait
		return
	var d := c.nav_move(c.mem.w_target, 1.1, dt, 3.0)
	if d < 0.5:
		c.mem.erase("w_target")
		c.mem.w_wait = randf_range(2.0, 6.0)

# ---------- roles ----------
func civilian(c: Character, dt: float) -> void:
	var s = c.site
	var P = Game.player
	update_fear(c, dt)
	if c.hero == null:
		c.hero = randf() < 0.15
	var crowd := crowd_held(s)
	match c.state:
		"idle":
			c.pose = "stand"
			wander_in(c, s.public, dt)
			if c.fear > 0.3:
				c.state = "cower"
		"cower":
			c.pose = "cower"
			c.speed_now = 0.0
			if c.sees:
				c.face_to(P.global_position, dt, 4.0)
			if s.robbery_active and c.fear < 0.15 and not crowd:
				if c.hero and c.dist_p < 8.0 and Game.t - c.last_aimed > 2.5:
					c.state = "hero"
					Game.notify("A customer is trying to be a hero!", "warn")
				else:
					c.state = "flee"
		"hero":
			c.pose = "stand"
			if P.aim_target == c or crowd:
				c.fear = 1.0
				c.state = "cower"
				return
			if c.nav_move(P.global_position, 4.6, dt, 0.4) < 1.15 or c.dist_p < 1.15:
				c.cd -= dt
				if c.cd <= 0.0:
					c.cd = 1.1
					Game.main.damage(P, 9.0, c)
					Sfx.play("kick")
		"flee":
			c.pose = "stand"
			if crowd or P.aim_target == c:
				c.fear = 1.0
				c.state = "cower"
				return
			var center := Vector3(s.bounds.get_center().x, 0, s.bounds.get_center().y)
			var out: Vector3 = s.door + (s.door - center).normalized() * 14.0
			c.nav_move(out, 5.0, dt)
			if not U.in_bounds(c.global_position, s.bounds):
				c.mem.call_t = c.mem.get("call_t", 0.0) + dt
				if c.mem.call_t > 5.0 and not c.mem.get("called", false):
					c.mem.called = true
					if s.robbery_active:
						Game.notify("A witness escaped and called 911", "bad")
						Game.robbery.transmit(s)
						Game.police.raise_stars(4 if s.vault_hit else s.leave_stars, s.door, "Witness called 911")

func staff(c: Character, dt: float) -> void:
	var P = Game.player
	update_fear(c, dt)
	staff_alarm(c, dt)
	if c.state == "idle":
		c.pose = "stand"
		c.speed_now = 0.0
		c.yaw += U.ang_diff(c.yaw, c.home_yaw) * minf(1.0, dt * 3.0)
		if c.fear > 0.3:
			c.state = "cower"
		if P.aim_target == c:
			Game.robbery.crime(c.site, "threat")
	else:
		c.pose = "cower"
		c.speed_now = 0.0
		if c.sees:
			c.face_to(P.global_position, dt, 4.0)

func clerk(c: Character, dt: float) -> void:
	var s = c.site
	var P = Game.player
	if P.aim_target == c:
		c.last_aimed = Game.t
	update_fear(c, dt)
	match c.state:
		"idle":
			c.pose = "stand"
			c.speed_now = 0.0
			c.yaw += U.ang_diff(c.yaw, c.home_yaw) * minf(1.0, dt * 3.0)
			if (P.aim_target == c and c.dist_p < 9.0) or c.fear > 0.35:
				c.state = "comply"
				c.last_aimed = Game.t
				c.mem.reg = 0.0
				Game.robbery.crime(s, "threat")
				Game.notify("Clerk is emptying the register - keep your gun on them")
		"comply":
			c.face_to(P.global_position, dt, 6.0)
			c.speed_now = 0.0
			if s.register <= 0:
				c.state = "cower"
				return
			c.pose = "work"
			if Game.t - c.last_aimed < 1.2 and c.dist_p < 7.0:
				c.mem.reg = c.mem.get("reg", 0.0) + dt / 4.5
				if c.mem.reg >= 1.0:
					Game.robbery.add_cash(s.register, s)
					s.register = 0.0
					s.register_mesh.material_override = Mats.m("counter")
					c.state = "cower"
			elif Game.t - c.last_aimed > 3.0 and not c.mem.get("rolled", false) and s.alarm_armed and not s.alarm_triggered:
				c.mem.rolled = true
				if randf() < 0.45:
					Game.robbery.trigger_alarm(s, "The clerk hit the silent alarm")
		_:
			c.pose = "cower"
			c.speed_now = 0.0
			staff_alarm(c, dt)

func guard_combat(c: Character, dt: float) -> void:
	var P = Game.player
	if P.aim_target == c:
		c.last_aimed = Game.t
	var aimed: bool = Game.t - c.last_aimed < 0.25 and c.dist_p < 18.0
	c.pose = "aim"
	if not P.dead and (c.sees or c.dist_p < 3.0):
		c.face_to(P.global_position, dt, 8.0)
	if aimed:
		c.surrender += dt / 2.0
		c.exposure = 0.0
	else:
		c.surrender = maxf(0.0, c.surrender - dt * 0.25)
		if c.sees:
			c.exposure += dt
	if c.surrender >= 1.0:
		c.state = "surrendered"
		c.armed = false
		c.show_gun = false
		Game.notify(("Truck guard" if c.role == "truckguard" else "Guard") + " surrendered and dropped their weapon", "good")
		if c.site != null:
			Game.robbery.crime(c.site, "threat")
		Sfx.play("click")
		if c.mem.get("carry_case", false):
			drop_case(c)
		return
	if c.exposure > 0.7 and c.sees and not P.dead:
		c.cd -= dt
		if c.cd <= 0.0:
			c.cd = 0.85
			npc_shoot(c, P, clampf(0.55 - c.dist_p * 0.012 - (0.15 if P.speed_now > 4.0 else 0.0), 0.1, 0.6), 11.0)
			if c.site != null:
				Game.robbery.crime(c.site, "shootout")
	elif not c.sees and c.dist_p < 30.0 and c.site != null and c.state == "alert":
		if U.in_bounds(P.global_position, c.site.bounds, 6.0):
			c.nav_move(P.global_position, 3.0, dt)
		else:
			c.speed_now = 0.0
	else:
		c.speed_now = 0.0

func guard(c: Character, dt: float) -> void:
	var P = Game.player
	var s = c.site
	c.show_gun = c.state != "surrendered"
	if c.state == "surrendered":
		c.pose = "kneel"
		c.speed_now = 0.0
		return
	if c.state == "idle":
		c.pose = "stand"
		c.speed_now = 0.0
		c.yaw += U.ang_diff(c.yaw, c.home_yaw) * minf(1.0, dt * 2.0)
		var inside: bool = s != null and U.in_bounds(P.global_position, s.bounds)
		if (c.sees and c.dist_p < 20.0 and (P.weapon or (P.masked and inside))) or (s != null and s.alarm_triggered and c.dist_p < 35.0) or hear_noise(c) != null or P.aim_target == c:
			c.state = "alert"
			c.exposure = 0.0 if P.aim_target == c else 0.35
			if s != null:
				Game.robbery.crime(s, "guard")
			Game.notify("Guard alerted - aim at them until they drop their weapon", "warn")
		return
	guard_combat(c, dt)

func drop_case(c: Character) -> void:
	c.mem.carry_case = false
	Game.main.site_builder.drop_case(c.global_position)

func truckguard(c: Character, dt: float) -> void:
	var P = Game.player
	c.show_gun = c.state != "surrendered"
	if c.state == "surrendered":
		c.pose = "kneel"
		c.speed_now = 0.0
		return
	if c.state == "alert":
		c.noclip = false
		guard_combat(c, dt)
		return
	if (c.sees and P.weapon and c.dist_p < 18.0) or P.aim_target == c or hear_noise(c) != null:
		c.state = "alert"
		c.exposure = 0.0 if P.aim_target == c else 0.35
		c.noclip = false
		Game.notify("Truck guard spotted you!", "warn")
		return
	c.pose = "stand"
	c.noclip = true
	for d in Game.doors:
		if not d.open and d.kind == "locked" and U.d2(d.pos, c.global_position) < 1.8:
			Game.robbery.open_door(d)
			d.temp_open = true
	var route: Array = c.mem.route
	match c.state:
		"deliver", "return":
			var wp: Vector3 = route[c.mem.ri]
			if c.step_toward(wp, 2.8, dt) < 0.3:
				if c.state == "deliver" and c.mem.ri == route.size() - 1:
					c.state = "atvault"
					Game.robbery.open_vault()
				elif c.state == "return" and c.mem.ri == 0:
					c.state = "boarded"
					c.set_hidden(true)
				else:
					c.mem.ri += 1 if c.state == "deliver" else -1
		"atvault":
			c.speed_now = 0.0
			if Game.robbery.vault.state == "open":
				c.state = "drop"
		"drop":
			if c.step_toward(Vector3(25, 0, 24.9), 2.4, dt) < 0.3:
				if c.mem.get("carry_case", false):
					c.mem.carry_case = false
					Game.main.site_builder.add_delivery()
				c.state = "leavevault"
		"leavevault":
			if c.step_toward(route[route.size() - 1], 2.8, dt) < 0.3:
				c.state = "return"
				c.mem.ri = route.size() - 1

func partner(c: Character, dt: float) -> void:
	var P = Game.player
	if c.in_car != null:
		if not c.hidden:
			c.set_hidden(true)
		c.global_position = Vector3(c.in_car.global_position.x, 0, c.in_car.global_position.z)
		c.mem.crowd_site = null
		return
	if c.hidden:
		c.set_hidden(false)
	c.show_gun = true
	var site = null
	if P.in_car == null:
		for s in Game.sites:
			if s.robbery_active and U.in_bounds(P.global_position, s.bounds) and (U.in_bounds(c.global_position, s.bounds, 4.0) or U.d2(c.global_position, P.global_position) < 12.0):
				site = s
	c.mem.crowd_site = site
	if site != null:
		var d := c.nav_move(site.crowd, 4.5, dt, 0.8)
		c.mem.at_crowd = d < 1.2
		if c.mem.at_crowd:
			c.speed_now = 0.0
			var tgt = null
			var bd := 99.0
			for n in site.npcs:
				if is_instance_valid(n) and not n.dead and not n.ko and n.role != "guard":
					var dd := U.d2(n.global_position, c.global_position)
					if dd < bd:
						bd = dd
						tgt = n
			if tgt != null:
				c.face_to(tgt.global_position, dt, 5.0)
			c.pose = "aim"
		else:
			c.pose = "stand"
		return
	c.mem.at_crowd = false
	var shooting := false
	if Game.wanted.stars >= 2:
		var tgt = null
		var bd := 25.0
		for k in Game.chars:
			if k.role == "cop" and not k.dead and not k.hidden:
				var dd := U.d2(k.global_position, c.global_position)
				if dd < bd and Game.main.los(c.global_position + Vector3(0, 1.5, 0), k.global_position + Vector3(0, 1.3, 0)):
					bd = dd
					tgt = k
		if tgt != null:
			shooting = true
			c.face_to(tgt.global_position, dt, 8.0)
			c.pose = "aim"
			c.cd -= dt
			if c.cd <= 0.0:
				c.cd = 1.3
				Game.main.fx.tracer(c.global_position + Vector3(0, 1.4, 0), tgt.global_position + Vector3(0, 1.2, 0))
				Sfx.play("npc_shot", 0.6)
				if randf() < 0.35:
					tgt.damage(22.0, c)
	if not shooting:
		c.pose = "stand"
	# follow the player's breadcrumbs
	var dp := U.d2(c.global_position, P.global_position)
	var crumbs: Array = P.crumbs
	if dp > 40.0 and crumbs.size() > 4:
		c.teleport(crumbs[maxi(0, crumbs.size() - 5)])
	if dp > 2.3:
		while crumbs.size() > 1 and U.d2(c.global_position, crumbs[0]) < 0.6:
			crumbs.pop_front()
		if crumbs.size() > 60:
			crumbs = crumbs.slice(crumbs.size() - 60)
			P.crumbs = crumbs
		var tgt: Vector3 = crumbs[0] if not crumbs.is_empty() else P.global_position
		if U.d2(c.global_position, tgt) > 6.0 and not Game.main.los(c.global_position + Vector3(0, 1, 0), tgt + Vector3(0, 1, 0)):
			c.nav_move(P.global_position, 5.5, dt)
		else:
			c.step_toward(tgt, 5.6 if dp > 6.0 else 3.6, dt, not shooting)
	else:
		c.speed_now = 0.0
		c.velocity = Vector3.ZERO
	if c.bag_mesh:
		c.bag_mesh.visible = not Game.partner_bag.is_empty()

func random_sidewalk() -> Vector3:
	var along := randf_range(-140.0, 140.0)
	if randf() < 0.5:
		var xs := []
		for r in Game.ROAD_X:
			xs.append(r - 7.5)
			if r != 150.0:
				xs.append(r + 7.5)
		return Vector3(xs[randi() % xs.size()], 0, along)
	var zs := []
	for r in Game.ROAD_Z:
		zs.append(r - 7.5)
		zs.append(r + 7.5)
	return Vector3(along, 0, zs[randi() % zs.size()])

func pedestrian(c: Character, dt: float) -> void:
	var P = Game.player
	var n = hear_noise(c)
	var saw_gun: bool = c.sees and c.dist_p < 15.0 and P.weapon
	if n != null or saw_gun:
		if c.state != "flee":
			c.state = "flee"
			c.mem.flee_t = 7.0
			c.mem.erase("dest")
		if not c.mem.get("witness", false):
			c.mem.witness = true
			c.mem.witness_pos = P.global_position
			c.mem.call_t = 0.0
	if c.mem.get("witness", false) and not c.mem.get("called", false):
		c.mem.call_t += dt
		if c.mem.call_t > 6.0:
			c.mem.called = true
			if Game.wanted.stars == 0:
				Game.police.raise_stars(1, c.mem.witness_pos, "A bystander called the police")
	c.pose = "stand"
	if c.state == "flee":
		c.mem.flee_t -= dt
		if not c.mem.has("dest"):
			var away: Vector3 = c.global_position - P.global_position
			away.y = 0
			c.mem.dest = c.global_position + away.normalized() * 25.0
		c.nav_move(c.mem.dest, 5.0, dt, 2.0)
		if c.mem.flee_t <= 0.0:
			c.state = "walk"
			c.mem.erase("dest")
		return
	if not c.mem.has("dest") or U.d2(c.global_position, c.mem.dest) < 1.0:
		c.mem.dest = random_sidewalk()
	c.nav_move(c.mem.dest, 1.4, dt, 4.0)

func update(dt: float) -> void:
	var P = Game.player
	for c in Game.chars:
		if c == P or c.role == "cop":
			continue
		if c.dead or c.ko:
			c.pose = "down"
			c.speed_now = 0.0
			continue
		if c.hidden and c.role != "partner":
			continue
		if c.role != "partner" and c.role != "truckguard" and U.d2(c.global_position, P.global_position) > 160.0 and c.role == "pedestrian":
			continue
		perceive(c, dt)
		match c.role:
			"civilian": civilian(c, dt)
			"teller", "staff": staff(c, dt)
			"clerk": clerk(c, dt)
			"guard": guard(c, dt)
			"truckguard": truckguard(c, dt)
			"partner": partner(c, dt)
			"pedestrian", "driver": pedestrian(c, dt)
			_: c.speed_now = 0.0
	# auto-close doors the truck guard opened
	for d in Game.doors:
		if not d.temp_open:
			continue
		var near := false
		for c in Game.chars:
			if not c.hidden and U.d2(c.global_position, d.pos) < 2.2:
				near = true
		if not near:
			Game.robbery.close_door(d)
