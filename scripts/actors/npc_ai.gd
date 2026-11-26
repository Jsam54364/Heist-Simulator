extends Node
## NPC behaviour by role, with personalities.
##
## Every civilian gets traits: bravery, nervousness, whether they carry a phone and
## whether they're the type to film. Traits decide how they react when something happens:
## nervous people bolt, brave ones stand their ground, call 911 or try to be a hero,
## the phone-obsessed film you (footage gets posted = your face gets known).
##
## Witnesses: crimes broadcast a crime event (gunfire, assault, carjacking, brandishing a
## gun, bodies on the ground...). Anyone who sees/hears it becomes a witness, gets clear of
## you and phones it in. The 911 call takes a few seconds and can be stopped: aim at them,
## shout them down, or take them out. A completed call sends a report to the police with
## whatever the caller saw (your face if unmasked, outfit, car, weapon, partner).
##
## Crowd control in robberies: SHOUT puts everyone on the floor; intimidation wears off
## when nobody is covering them. Unwatched hostages sneak for the exit or make a quiet
## call; heroes jump you. Zip-tie them, keep them covered, or let your partner hold the
## crowd. You can also rob customers / passers-by of their wallets.

const SHOUT_R := 15.0
var shout_cd := 0.0
var rng := RandomNumberGenerator.new()

func _ready() -> void:
	rng.randomize()

# =================================================================== helpers
func give_traits(c: Character) -> void:
	if c.mem.has("brave"):
		return
	c.mem.brave = clampf(randfn(0.4, 0.22), 0.0, 1.0)
	c.mem.nervous = clampf(randfn(0.45, 0.22), 0.0, 1.0)
	c.mem.phone = randf() < 0.8
	c.mem.filmer = c.mem.phone and randf() < 0.28
	if c.hero == null:
		c.hero = c.mem.brave > 0.72 and randf() < 0.6

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

## Is the player actively covering this person (gun out, looking their way, close)?
func watched(c: Character) -> bool:
	var P = Game.player
	if partner_covers(c):
		return true
	if not P.weapon or P.in_car or c.dist_p > 16.0 or not c.sees:
		return false
	var f := U.fwd(P.yaw)
	var to: Vector3 = c.global_position - P.global_position
	to.y = 0
	return to.normalized().dot(f) > 0.34 or c.dist_p < 4.0

func partner_covers(c: Character) -> bool:
	var pt = Game.partner
	if pt == null or pt.hidden or not pt.mem.get("at_crowd", false):
		return false
	return U.d2(pt.global_position, c.global_position) < 14.0 and (c.site == null or pt.mem.get("crowd_site") == c.site)

func crowd_held(site) -> bool:
	var pt = Game.partner
	return pt != null and pt.mem.get("crowd_site") == site and pt.mem.get("at_crowd", false) and site != null

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

## What this witness can tell the police about you.
func _describe(c: Character) -> Dictionary:
	var P = Game.player
	var d := {}
	if P.in_car:
		d.car_id = P.in_car.car_id
		d.car_color = P.in_car.color_idx
	else:
		d.outfit = Game.outfit
		if not P.masked and c.dist_p < 12.0:
			d.face = true
		d.weapon = P.weapon
	var pt = Game.partner
	if pt and not pt.hidden and U.d2(pt.global_position, c.global_position) < 18.0:
		d.partner = true
	return d

## A crime happened at pos: everyone around who notices becomes a witness.
## stars = what the call will be worth, r = how far it carries (gunshots carry further).
func crime_event(pos: Vector3, reason: String, stars: int, r := 22.0, loud := false) -> void:
	for c in Game.chars:
		if c.hidden or c.dead or c.ko or c.role not in ["pedestrian", "driver", "civilian", "staff", "teller", "clerk"]:
			continue
		var d := U.d2(c.global_position, pos)
		if d > r:
			continue
		give_traits(c)
		var noticed: bool = loud or d < 6.0 or c.can_see(pos, r, -0.2, 1.6, 1.0)
		if not noticed:
			continue
		_witness(c, reason, stars, pos)
	if loud:
		# drivers nearby floor it
		for car in Game.cars:
			if car.npc_driver != null and U.d2(car.global_position, pos) < r * 1.4:
				car.npc_driver.mem.panic = 6.0

func _witness(c: Character, reason: String, stars: int, pos: Vector3) -> void:
	var cur = c.mem.get("crime")
	if cur != null and cur.stars >= stars and not c.mem.get("called", false):
		return
	c.mem.crime = {"reason": reason, "stars": stars, "pos": pos, "desc": _describe(c)}
	c.mem.called = false
	if c.site == null and c.state not in ["flee", "film", "call", "handsup", "down", "tied"]:
		c.state = _pick_reaction(c)
		c.mem.react_t = 0.0
		c.mem.erase("dest")

func _pick_reaction(c: Character) -> String:
	var brave: float = c.mem.get("brave", 0.4)
	var nerv: float = c.mem.get("nervous", 0.4)
	var P = Game.player
	if P.weapon and c.dist_p < 10.0 and not P.in_car:
		return "cower" if nerv > 0.5 else "flee"
	if c.mem.get("filmer", false) and brave > 0.3 and c.dist_p > 8.0:
		return "film"
	if nerv > 0.62 or brave < 0.25:
		return "flee"
	if c.mem.get("phone", false) and brave > 0.5 and c.dist_p > 14.0:
		return "call"
	return "flee" if randf() < 0.6 else "cower"

## 911 call in progress: 6-9 s on the phone, then the report goes through.
func _update_call(c: Character, dt: float) -> bool:
	var cr = c.mem.get("crime")
	if cr == null or c.mem.get("called", false) or not c.mem.get("phone", false):
		return false
	c.mem.call_t = c.mem.get("call_t", 0.0) + dt
	c.pose = "phone"
	var need: float = 6.0 + c.mem.get("nervous", 0.4) * 3.0
	c.mem.call_need = need
	if c.mem.call_t >= need:
		c.mem.called = true
		c.mem.call_t = 0.0
		var site = c.site
		if site != null and site.robbery_active:
			Game.robbery.transmit(site)
			Game.police.report(4 if site.vault_hit else site.leave_stars, site.door, "911 call from %s" % site.name, cr.desc)
		else:
			Game.police.report(cr.stars, cr.pos, "911: " + cr.reason, cr.desc)
		Game.notify("A witness got through to 911", "bad")
		return false
	return true

## The player stops a call: aiming at the caller, shouting, or taking them out.
func interrupt_call(c: Character, why := "") -> void:
	if c.mem.get("call_t", 0.0) > 0.0 and not c.mem.get("called", false):
		c.mem.call_t = 0.0
		if why != "":
			Game.notify(why, "good")
	c.mem.call_t = 0.0

func caller_progress(c: Character) -> float:
	if c.mem.get("called", false) or c.mem.get("call_t", 0.0) <= 0.0:
		return -1.0
	return c.mem.call_t / c.mem.get("call_need", 7.0)

# =================================================================== player verbs
## SHOUT: "Everybody down!" - intimidates everyone in earshot, stops their calls.
func shout() -> void:
	var P = Game.player
	if shout_cd > 0.0 or P.in_car or P.dead:
		return
	shout_cd = 1.2
	var lines := ["EVERYBODY DOWN! NOBODY MOVES!", "ON THE FLOOR, NOW!", "HANDS UP, FACE DOWN!", "PHONES ON THE GROUND!"]
	Game.notify("YOU: \"%s\"" % lines[randi() % lines.size()], "warn")
	var site = null
	for s in Game.sites:
		if U.in_bounds(P.global_position, s.bounds, 1.0):
			site = s
	if site != null:
		Game.robbery.crime(site, "threat")
	var n := 0
	for c in Game.chars:
		if c.hidden or c.dead or c.ko or c.role not in ["pedestrian", "driver", "civilian", "staff", "teller", "clerk"]:
			continue
		var d := U.d2(c.global_position, P.global_position)
		if d > SHOUT_R:
			continue
		if c.site == null and d > 8.0 and not c.can_see(P.global_position, SHOUT_R, -1.0):
			continue
		give_traits(c)
		n += 1
		var brave: float = c.mem.brave
		c.fear = clampf(c.fear + 0.75 - brave * 0.3 + (0.25 if P.weapon else 0.0), 0.0, 1.0)
		interrupt_call(c)
		c.mem.unwatched = 0.0
		if c.mem.get("tied", false):
			continue
		if c.role == "civilian":
			c.state = "down"
		elif c.role in ["pedestrian", "driver"]:
			_witness(c, "Armed threats" if P.weapon else "Threatening people", 1, P.global_position)
			c.mem.react_t = 0.0
			c.mem.erase("dest")
			c.state = "down" if (d < 9.0 and (P.weapon or brave < 0.6)) else "flee"
	if n == 0:
		Game.notify("Nobody close enough to hear you")

func zip_tie(c: Character) -> void:
	if Game.tools.get("zipties", 0) <= 0:
		Game.notify("Out of zip-ties - buy more from the fence", "bad")
		return
	Game.tools.zipties -= 1
	c.mem.tied = true
	c.state = "tied"
	c.fear = 1.0
	interrupt_call(c)
	Sfx.play("click")
	Game.notify("Zip-tied. %d left" % Game.tools.zipties, "good")
	if c.site != null:
		Game.robbery.crime(c.site, "threat")

func rob_wallet(c: Character) -> void:
	c.mem.robbed = true
	var cash := float(randi_range(2, 18) * 10)
	if c.role == "civilian":
		cash *= 1.6
	Game.robbery.add_cash(cash, c.site)
	Game.notify("Took %s from their wallet" % U.money(cash), "good")
	Sfx.play("cash")
	if c.site == null:
		crime_event(c.global_position, "Street robbery", 1, 16.0)
		_witness(c, "Robbed at gunpoint", 1, c.global_position)

func greet(c: Character) -> void:
	give_traits(c)
	c.mem.wave_t = 1.6
	c.face_to(Game.player.global_position, 1.0, 1.0)
	var lines := ["Hey!", "Mornin'.", "How's it going?", "Nice day for it.", "Yo."]
	if c.mem.brave < 0.2:
		lines = ["Uh... hi.", "Do I know you?"]
	Game.notify("%s: \"%s\"" % ["Local", lines[randi() % lines.size()]])

## Antagonize: shoo people off (clear witnesses) - nervous ones leave, brave ones push back.
func antagonize(c: Character) -> void:
	give_traits(c)
	var brave: float = c.mem.brave
	c.mem.antag = c.mem.get("antag", 0) + 1
	if brave > 0.6 and c.mem.antag < 3:
		c.state = "confront"
		c.mem.react_t = 0.0
		Game.notify("Local: \"%s\"" % ["You got a problem?", "Back off, man.", "Say that again."][randi() % 3], "warn")
	else:
		c.state = "leave_area"
		c.mem.erase("dest")
		Game.notify("Local: \"%s\"" % ["Whatever, freak.", "I'm out of here.", "Jeez, OK!"][randi() % 3])

func dodge(c: Character, car, side: float) -> void:
	if c.mem.get("dodge_t", 0.0) > 0.0 or c.role in ["cop", "partner", "player"] or c.hidden:
		return
	var r: Vector3 = U.right(car.yaw()) * side
	c.mem.dodge_t = 0.45
	c.mem.dodge_to = c.global_position + r * 2.6
	c.fear = minf(1.0, c.fear + 0.4)
	if c.role in ["pedestrian", "driver"] and car.driver == "player":
		if c.state in ["walk", "idle"]:
			c.state = "flee"
			c.mem.flee_t = 4.0
			c.mem.erase("dest")

# =================================================================== fear (sites)
func update_fear(c: Character, dt: float) -> void:
	var P = Game.player
	give_traits(c)
	if c.mem.get("tied", false):
		c.fear = 1.0
		return
	if partner_covers(c):
		c.fear = 1.0
		c.mem.unwatched = 0.0
		return
	if P.aim_target == c:
		c.fear += 2.2 * dt
		c.last_aimed = Game.t
		interrupt_call(c, "You stopped them from calling 911")
	elif P.weapon and c.sees and c.dist_p < 14.0:
		c.fear += 0.9 * dt
	else:
		# intimidation wears off - faster for the brave, slower for the nervous
		c.fear -= (0.025 + c.mem.brave * 0.07 - c.mem.nervous * 0.02) * dt
	if hear_noise(c) != null:
		c.fear += 0.8
	if c.site != null and c.site.alarm_triggered:
		c.fear = maxf(c.fear, 0.25)
	c.fear = clampf(c.fear, 0.0, 1.0)
	if watched(c):
		c.mem.unwatched = 0.0
	else:
		c.mem.unwatched = c.mem.get("unwatched", 0.0) + dt

func staff_alarm(c: Character, dt: float) -> void:
	var s = c.site
	if s == null or c.mem.get("tied", false):
		return
	var at: float = c.mem.get("alarm_t", 0.0)
	if s.robbery_active and c.saw_crime and s.alarm_armed and not s.alarm_triggered and not partner_covers(c) and c.fear < 0.4 and not watched(c):
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

# =================================================================== roles
## Customers in a robbed shop/bank.
func civilian(c: Character, dt: float) -> void:
	var s = c.site
	var P = Game.player
	update_fear(c, dt)
	if c.mem.get("tied", false):
		c.state = "tied"
	var out_pt: Vector3 = s.door + (s.door - Vector3(s.bounds.get_center().x, 0, s.bounds.get_center().y)).normalized() * 14.0
	match c.state:
		"idle":
			c.pose = "stand"
			wander_in(c, s.public, dt)
			if c.fear > 0.3:
				c.state = "down"
		"down", "cower":
			c.state = "down"
			c.pose = "cower"
			c.speed_now = 0.0
			if c.sees:
				c.face_to(P.global_position, dt, 4.0)
			if not s.robbery_active:
				return
			# nobody covering them and the fear has worn off: act
			if c.fear < 0.3 and c.mem.get("unwatched", 0.0) > 2.5:
				if c.hero and c.dist_p < 8.0 and Game.t - c.last_aimed > 2.5 and not Game.partner.mem.get("at_crowd", false):
					c.state = "hero"
					Game.notify("A customer is trying to be a hero!", "warn")
				elif c.mem.phone and c.mem.brave > 0.45 and not c.mem.get("called", false):
					c.state = "secret_call"
					c.mem.crime = {"reason": "Robbery at " + s.name, "stars": s.leave_stars, "pos": s.door, "desc": _describe(c)}
				else:
					c.state = "sneak"
					Game.notify("A hostage is sneaking for the exit", "warn")
		"secret_call":
			c.speed_now = 0.0
			if watched(c) or P.aim_target == c:
				interrupt_call(c, "You caught a hostage on the phone")
				c.fear = 1.0
				c.state = "down"
				return
			if not _update_call(c, dt):
				c.state = "down"
				c.fear = 0.5
		"sneak":
			c.pose = "cower"
			if watched(c) or P.aim_target == c:
				c.fear = minf(1.0, c.fear + 0.4)
				c.state = "down"
				Game.notify("Hostage froze")
				return
			c.nav_move(out_pt, 1.3, dt)
			if not U.in_bounds(c.global_position, s.bounds):
				c.state = "flee"
		"hero":
			c.pose = "stand"
			if P.aim_target == c or partner_covers(c):
				c.fear = 1.0
				c.state = "down"
				return
			if c.nav_move(P.global_position, 4.6, dt, 0.4) < 1.15 or c.dist_p < 1.15:
				c.cd -= dt
				if c.cd <= 0.0:
					c.cd = 1.1
					Game.main.damage(P, 9.0, c)
					Sfx.play("kick")
		"flee":
			c.pose = "stand"
			if P.aim_target == c:
				c.fear = 1.0
				c.state = "down"
				interrupt_call(c)
				return
			c.nav_move(out_pt, 5.0, dt)
			if not U.in_bounds(c.global_position, s.bounds, 3.0):
				c.mem.call_t = c.mem.get("call_t", 0.0)
				if not c.mem.get("called", false) and s.robbery_active:
					if not c.mem.has("crime"):
						c.mem.crime = {"reason": "Robbery at " + s.name, "stars": s.leave_stars, "pos": s.door, "desc": _describe(c)}
					if not c.mem.get("phone", true):
						c.mem.phone = true
					c.speed_now = 0.0
					if not _update_call(c, dt) and c.mem.get("called", false):
						Game.notify("A witness escaped and called 911", "bad")
		"tied":
			c.pose = "kneel"
			c.speed_now = 0.0

func staff(c: Character, dt: float) -> void:
	var P = Game.player
	update_fear(c, dt)
	staff_alarm(c, dt)
	if c.mem.get("tied", false):
		c.pose = "kneel"
		c.speed_now = 0.0
		return
	if c.state == "idle":
		c.pose = "stand"
		c.speed_now = 0.0
		c.yaw += U.ang_diff(c.yaw, c.home_yaw) * minf(1.0, dt * 3.0)
		if c.fear > 0.3:
			c.state = "cower"
		if P.aim_target == c:
			Game.robbery.crime(c.site, "threat")
	else:
		c.pose = "cower" if c.fear > 0.15 else "handsup"
		c.speed_now = 0.0
		if c.sees:
			c.face_to(P.global_position, dt, 4.0)

func clerk(c: Character, dt: float) -> void:
	var s = c.site
	var P = Game.player
	if P.aim_target == c:
		c.last_aimed = Game.t
	update_fear(c, dt)
	if c.mem.get("tied", false):
		c.pose = "kneel"
		c.speed_now = 0.0
		return
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
				if randf() < 0.3 + c.mem.brave * 0.3:
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
	if c.state == "surrendered" or c.mem.get("tied", false):
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

## Partner: holds the crowd during robberies (re-intimidating anyone who gets ideas),
## carries a bag, fights cops at 2+ stars, follows your breadcrumbs.
func partner(c: Character, dt: float) -> void:
	var P = Game.player
	if c.in_car != null:
		if not c.hidden:
			c.set_hidden(true)
		c.global_position = Vector3(c.in_car.global_position.x, 0, c.in_car.global_position.z)
		c.mem.crowd_site = null
		c.mem.at_crowd = false
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
			# cover whoever looks most likely to try something
			var tgt = null
			var worst := 9.0
			for n in site.npcs:
				if is_instance_valid(n) and not n.dead and not n.ko and n.role != "guard" and not n.mem.get("tied", false):
					var score: float = n.fear - n.mem.get("brave", 0.4) * 0.3 + U.d2(n.global_position, c.global_position) * 0.02
					if score < worst:
						worst = score
						tgt = n
			if tgt != null:
				c.face_to(tgt.global_position, dt, 5.0)
				c.cd -= dt
				if c.cd <= 0.0 and tgt.state in ["sneak", "secret_call", "hero", "flee"]:
					c.cd = 2.0
					tgt.fear = 1.0
					tgt.state = "down"
					interrupt_call(tgt)
					Game.notify("Partner: \"%s\"" % ["Don't even think about it!", "Back on the floor!", "Phone down. Now."][randi() % 3], "warn")
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
				Game.heat.partner = maxf(Game.heat.partner, 150.0)
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

## People out on the streets of Key Lento.
func pedestrian(c: Character, dt: float) -> void:
	var P = Game.player
	give_traits(c)
	var gen: KeysGen = Game.main.world_gen
	# dodging a car takes priority over everything
	if c.mem.get("dodge_t", 0.0) > 0.0:
		c.mem.dodge_t -= dt
		c.pose = "stand"
		c.step_toward(c.mem.dodge_to, 6.5, dt)
		return
	if c.mem.get("tied", false):
		c.state = "tied"
	# stimuli
	var n = hear_noise(c)
	if n != null and c.state in ["walk", "idle", "chat", "confront", "leave_area"]:
		_witness(c, "Shots fired", 2, n.pos)
		if c.state in ["walk", "idle", "chat", "confront", "leave_area"]:
			c.state = "cower" if c.mem.nervous > 0.7 else "flee"
	if c.sees and P.weapon and c.dist_p < 18.0 and not c.mem.has("crime"):
		_witness(c, "Armed person", 1, P.global_position)
	if P.aim_target == c and c.state not in ["tied", "down"]:
		if c.state != "handsup":
			interrupt_call(c, "The witness dropped their phone")
		c.state = "handsup"
		c.mem.react_t = 0.0
	# bodies on the ground
	c.mem.body_t = c.mem.get("body_t", randf()) - dt
	if c.mem.body_t <= 0.0:
		c.mem.body_t = 1.0
		if not c.mem.has("crime"):
			for k in Game.chars:
				if (k.dead or k.ko) and not k.hidden and U.d2(k.global_position, c.global_position) < 14.0 and c.can_see(k.global_position, 14.0, 0.0, 1.6, 0.3):
					_witness(c, "Body found" if k.dead else "Someone knocked out", 2 if k.dead else 1, k.global_position)
					break
	c.mem.react_t = c.mem.get("react_t", 0.0) + dt
	c.pose = "stand"
	match c.state:
		"walk":
			c.mem.wave_t = c.mem.get("wave_t", 0.0) - dt
			if c.mem.wave_t > 0.0:
				c.pose = "wave"
				c.speed_now = 0.0
				return
			if not c.mem.has("dest") or U.d2(c.global_position, c.mem.dest) < 1.0:
				var q: Vector3 = gen.ped_spot(c.global_position, 8.0, 45.0, rng)
				if q == Vector3.INF or randf() < 0.15:
					c.state = "idle"
					c.mem.idle_t = randf_range(2.0, 6.0)
					return
				c.mem.dest = q
			c.nav_move(c.mem.dest, 1.25 + c.mem.nervous * 0.4, dt, 6.0)
		"idle":
			c.speed_now = 0.0
			c.mem.idle_t = c.mem.get("idle_t", 3.0) - dt
			if c.mem.get("phone", false) and fmod(c.mem.react_t, 9.0) < 3.0:
				c.pose = "phone"
			if c.mem.idle_t <= 0.0:
				c.state = "walk"
				c.mem.erase("dest")
		"cower":
			c.pose = "cower"
			c.speed_now = 0.0
			if c.mem.react_t > 2.0 + c.mem.nervous * 4.0:
				c.state = "flee"
				c.mem.erase("dest")
		"down":
			c.pose = "cower"
			c.speed_now = 0.0
			# stay down while covered; once nobody's watching, get away and call it in
			if watched(c):
				c.mem.unwatched = 0.0
			else:
				c.mem.unwatched = c.mem.get("unwatched", 0.0) + dt
			if c.mem.unwatched > 3.0 + c.mem.nervous * 5.0:
				c.state = "flee"
				c.mem.erase("dest")
		"handsup":
			c.pose = "handsup"
			c.speed_now = 0.0
			c.face_to(P.global_position, dt, 6.0)
			if P.aim_target != c and c.mem.react_t > 1.5:
				c.state = "flee"
				c.mem.erase("dest")
		"film":
			# phone up, recording you; footage = face on record if you're unmasked
			c.speed_now = 0.0
			c.pose = "film"
			if c.sees:
				c.face_to(P.global_position, dt, 5.0)
			if c.mem.react_t > 7.0:
				if c.sees and not P.masked and P.in_car == null:
					Game.heat.face = maxf(Game.heat.face, 200.0)
					Game.heat.cctv = 2
					Game.notify("Someone filmed you and posted it - your face is out there", "bad")
				c.state = "call" if c.mem.brave > 0.5 else "flee"
				c.mem.react_t = 0.0
		"call":
			c.speed_now = 0.0
			if c.dist_p < 8.0 and P.weapon:
				c.state = "flee"
				c.mem.erase("dest")
				return
			if c.sees:
				c.face_to(P.global_position, dt, 3.0)
			if not _update_call(c, dt):
				c.state = "walk" if c.mem.get("called", false) else "flee"
				c.mem.erase("dest")
		"flee", "leave_area":
			var panic: bool = c.state == "flee"
			if not c.mem.has("dest"):
				var away: Vector3 = c.global_position - (c.mem.crime.pos if c.mem.has("crime") else P.global_position)
				away.y = 0
				if away.length() < 0.1:
					away = U.fwd(randf() * TAU)
				var q: Vector3 = Game.main.nav.land_point(c.global_position + away.normalized() * (30.0 if panic else 40.0))
				c.mem.dest = q
				c.mem.flee_t = 9.0
			c.mem.flee_t = c.mem.get("flee_t", 9.0) - dt
			var rem := c.nav_move(c.mem.dest, 5.2 if panic else 2.2, dt, 2.0)
			var safe: bool = c.dist_p > 28.0 or (not c.sees and c.dist_p > 16.0)
			if panic and safe and c.mem.has("crime") and c.mem.get("phone", false) and not c.mem.get("called", false):
				c.state = "call"
				return
			if c.mem.flee_t <= 0.0 or rem < 1.0:
				c.state = "walk"
				c.mem.erase("dest")
		"confront":
			# brave local squaring up to you after being antagonized
			c.face_to(P.global_position, dt, 6.0)
			if P.weapon:
				c.state = "handsup"
				return
			if c.dist_p > 1.4:
				c.nav_move(P.global_position, 2.6, dt, 0.6)
			else:
				c.speed_now = 0.0
				if c.mem.antag >= 2:
					c.cd -= dt
					if c.cd <= 0.0:
						c.cd = 1.2
						Game.main.damage(P, 4.0, c)
						Sfx.play("kick", 0.6)
			if c.mem.react_t > 6.0:
				c.state = "walk"
				c.mem.erase("dest")
		"tied":
			c.pose = "kneel"
			c.speed_now = 0.0
		_:
			c.state = "walk"

## Drivers at gunpoint: point a gun at a stopped car and the driver bails out.
func _driver_threat() -> void:
	var P = Game.player
	if not P.weapon or P.in_car or P.dead:
		return
	var f := U.fwd(P.yaw)
	for car in Game.cars:
		if car.npc_driver == null or car.rail:
			continue
		var to: Vector3 = car.global_position - P.global_position
		to.y = 0
		var d := to.length()
		if d > 8.0 or d < 0.5 or absf(car.speed()) > 3.0 or to.normalized().dot(f) < 0.85:
			continue
		var dr: Character = car.npc_driver
		car.npc_driver = null
		car.ai = {}
		car.release()
		car.handbrake = true
		dr.in_car = null
		dr.set_hidden(false)
		dr.role = "driver"
		dr.teleport(Game.main.nav.free_point(car.global_position - U.right(car.yaw()) * 1.9))
		give_traits(dr)
		_witness(dr, "Carjacking at gunpoint", 1, P.global_position)
		dr.state = "handsup"
		dr.mem.react_t = 0.0
		Game.notify("The driver jumped out with their hands up", "warn")
		break

func update(dt: float) -> void:
	var P = Game.player
	shout_cd = maxf(0.0, shout_cd - dt)
	_driver_threat()
	for c in Game.chars:
		if c == P or c.role == "cop":
			continue
		if c.dead or c.ko:
			c.pose = "down"
			c.speed_now = 0.0
			continue
		if c.hidden and c.role != "partner":
			continue
		# AI LOD: people far from the player think 4x less often (with 4x the dt)
		var dp := U.d2(c.global_position, P.global_position)
		var cdt := dt
		if dp > 60.0 and c.role != "partner" and c.role != "truckguard":
			c.ai_acc += dt
			c.ai_n += 1
			if c.ai_n < 4:
				continue
			cdt = c.ai_acc
			c.ai_acc = 0.0
			c.ai_n = 0
		perceive(c, cdt)
		match c.role:
			"civilian": civilian(c, cdt)
			"teller", "staff": staff(c, cdt)
			"clerk": clerk(c, cdt)
			"guard": guard(c, cdt)
			"truckguard": truckguard(c, cdt)
			"partner": partner(c, cdt)
			"pedestrian", "driver": pedestrian(c, cdt)
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

## The nearest active 911 caller (for the HUD warning).
func active_caller():
	var best = null
	var bp := -1.0
	for c in Game.chars:
		if c.hidden or c.dead or c.ko:
			continue
		var p := caller_progress(c)
		if p > bp:
			bp = p
			best = c
	return best
