class_name Player
extends Character
## The player: on-foot movement relative to the camera, driving, aiming and firing,
## context actions (timed interactions with a progress bar), takedowns, searching
## bodies, carjacking, the personal car's trunk, outfits and the mask. Port of player.js.

var weapon := false
var masked := false
var action = null
var shoot_cd := 0.0
var crumbs: Array = []
var aim_target = null
var aim_point := Vector3.ZERO
var bust_t := 0.0
var surrendering := false
var armor := 0.0
var inp := {"jx": 0.0, "jy": 0.0, "sprint": false, "gas": false, "brake": false, "handbrake": false, "fire": false}

const ROLE_NAMES := {"clerk": "clerk", "staff": "clerk", "teller": "teller", "guard": "guard", "cop": "officer", "civilian": "customer",
	"pedestrian": "bystander", "truckguard": "truck guard", "driver": "driver"}

static func role_name(c) -> String:
	return ROLE_NAMES.get(c.role, c.role)

func _ready() -> void:
	mem.color = Game.OUTFITS[Game.outfit].color
	super._ready()
	bag_mesh = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.5, 0.35, 0.3)
	bag_mesh.mesh = bm
	bag_mesh.material_override = Mats.solid(Color("1d1f22"), 0.8)
	bag_mesh.position = Vector3(0, 1.15, -0.28)
	bag_mesh.visible = false
	inner.add_child(bag_mesh)

func set_outfit(i: int) -> void:
	Game.outfit = i
	set_outfit_color(Game.OUTFITS[i].color)

func change_outfit(src: String) -> void:
	if src == "trunk":
		var cur := Game.outfit
		set_outfit(Game.spare_outfit)
		Game.spare_outfit = cur
	else:
		var n := (Game.outfit + 1) % Game.OUTFITS.size()
		if n == Game.spare_outfit:
			n = (n + 1) % Game.OUTFITS.size()
		set_outfit(n)
	var known: bool = Game.heat.outfit == Game.outfit
	Game.notify("Changed into %s%s" % [Game.OUTFITS[Game.outfit].name, " - police know this one!" if known else ""], "warn" if known else "good")
	Sfx.play("click")

func toggle_mask() -> void:
	masked = not masked
	mask_mesh.visible = masked
	Sfx.play("click")

## Give yourself up: holster, hands up, let the cops come to you.
func give_up() -> void:
	if surrendering:
		surrendering = false
		return
	if not Game.police.can_surrender():
		Game.notify("Nobody to surrender to" if Game.profile() != "PSYCHO" else "Psycho profile - the police won't take your surrender", "bad")
		return
	surrendering = true
	weapon = false
	show_gun = false
	action = null
	Game.notify("You put your hands up. Stay still...", "warn")

## Duck down in a stopped car to hide from the police.
func toggle_hide() -> void:
	if in_car == null:
		return
	if in_car.crouched:
		in_car.crouched = false
	elif absf(in_car.speed()) < 1.5:
		in_car.crouched = true
		in_car.throttle = 0.0
		Game.notify("Hiding in the car - stay still", "good")

func toggle_weapon() -> void:
	if in_car:
		return
	weapon = not weapon
	action = null
	Sfx.play("click")

# ---------- aiming & shooting ----------
func _cam_ray(length: float) -> Dictionary:
	var cam: Camera3D = Game.main.camera
	var dir := -cam.global_basis.z
	var o := cam.global_position
	var skip := o.distance_to(global_position + Vector3(0, 1.5, 0))
	var start := o + dir * skip * 0.9
	var hit = Game.main.ray(start, start + dir * length, Game.L_WORLD)
	var max_t: float = start.distance_to(hit.position) if hit else length
	return {"start": start, "dir": dir, "max_t": max_t}

func compute_aim() -> void:
	aim_target = null
	if not weapon or in_car or dead:
		return
	var r := _cam_ray(60.0)
	var start: Vector3 = r.start
	var dir: Vector3 = r.dir
	aim_point = start + dir * r.max_t
	var best = null
	var best_score := 1e9
	var h2 := dir.x * dir.x + dir.z * dir.z
	if h2 < 0.01:
		return
	for c in Game.chars:
		if c == self or c.hidden or c.dead or c.ko or c.role == "partner":
			continue
		var p: Vector3 = c.global_position
		var tt := ((p.x - start.x) * dir.x + (p.z - start.z) * dir.z) / h2
		if tt < 0.0 or tt > r.max_t or tt > 22.0:
			continue
		var px := start.x + dir.x * tt
		var pz := start.z + dir.z * tt
		var py := start.y + dir.y * tt
		var perp := Vector2(px - p.x, pz - p.z).length()
		if perp < 0.55 + tt * 0.04 and py > -0.3 and py < 2.4:
			var score := perp + tt * 0.02
			if score < best_score:
				best_score = score
				best = c
	aim_target = best

func fire() -> void:
	if not weapon or in_car or dead or shoot_cd > 0.0:
		return
	shoot_cd = 0.28
	var r := _cam_ray(70.0)
	var start: Vector3 = r.start
	var dir: Vector3 = r.dir
	var t_hit: float = r.max_t
	var hit_char = null
	var hit_cam = null
	var h2 := dir.x * dir.x + dir.z * dir.z
	for c in Game.chars:
		if c == self or c.hidden or c.dead or c.role == "partner" or h2 < 0.01:
			continue
		var p: Vector3 = c.global_position
		var tt := ((p.x - start.x) * dir.x + (p.z - start.z) * dir.z) / h2
		if tt < 0.0 or tt > t_hit:
			continue
		var px := start.x + dir.x * tt
		var pz := start.z + dir.z * tt
		var py := start.y + dir.y * tt - Game.ground_y(p.x, p.z)
		var y_top := 0.5 if c.ko else 1.95
		if Vector2(px - p.x, pz - p.z).length() < (0.6 if c == aim_target else 0.42) and py > 0.0 and py < y_top:
			t_hit = tt
			hit_char = c
	for s in Game.sites:
		for cm in s.cameras:
			if cm.destroyed:
				continue
			var v: Vector3 = cm.pos - start
			var tt := v.dot(dir)
			if tt < 0.0 or tt > t_hit:
				continue
			if (start + dir * tt).distance_to(cm.pos) < 0.45:
				t_hit = tt
				hit_cam = cm
				hit_char = null
	var muzzle := global_position + Vector3(0, 1.45 + Game.ground_y(global_position.x, global_position.z), 0) + U.fwd(yaw) * 0.5 - U.right(yaw) * 0.25
	var hp := start + dir * t_hit
	Game.main.fx.tracer(muzzle, hp)
	Game.main.camera.shake = maxf(Game.main.camera.shake, 0.05)
	Sfx.play("shot_suppressed" if Game.tools.suppressor else "shot")
	if not Game.tools.suppressor:
		Game.add_noise(global_position, 30.0)
		Game.main.npc_ai.crime_event(global_position, "Shots fired", 2, 45.0, true)
	else:
		Game.main.npc_ai.crime_event(global_position, "Shooting", 2, 10.0)
	Game.police.shot_ray(start, dir, t_hit)
	var site = null
	for s in Game.sites:
		if U.in_bounds(global_position, s.bounds, 1.0):
			site = s
	if site != null:
		Game.robbery.crime(site, "gunfire")
		if not Game.tools.suppressor and site.alarm_armed and not site.alarm_triggered and randf() < 0.35:
			Game.robbery.trigger_alarm(site, "Gunshots - staff hit the alarm")
	if hit_cam != null:
		Game.robbery.destroy_cam(hit_cam)
		Sfx.play("hit")
	elif hit_char == null:
		Game.robbery.puff(hp, Color(0.75, 0.72, 0.68), 4, 0.25)
	if hit_char != null:
		Sfx.play("hit")
		hit_char.damage(34.0, self)
		if hit_char.role == "cop":
			Game.record.shots_at_cops += 1
			Game.police.raise_stars(clampi(Game.wanted.stars + (1 if hit_char.dead else 0), 3, Game.MAX_STARS), global_position, "Shots fired at police")
		if hit_char.site != null:
			Game.robbery.crime(hit_char.site, "shoot")
	if not Game.tools.suppressor and Game.wanted.stars == 0:
		for c in Game.chars:
			if c.role == "cop" and not c.dead and U.d2(c.in_car.global_position if c.in_car else c.global_position, global_position) < 45.0:
				Game.police.raise_stars(2, global_position, "Police heard gunshots")
				break

# ---------- interactions ----------
func act(label: String, dur: float, run = null, opts := {}) -> Dictionary:
	var a := {"label": label, "dur": dur, "run": run}
	a.merge(opts, true)
	return a

func dynamic_candidates() -> Array:
	var out := []
	if in_car:
		out.append({"pos": in_car.global_position, "d": 0.0, "actions": [act("Exit vehicle", 0.0, func(): exit_car())]})
		return out
	var pp := global_position
	for car in Game.cars:
		var d := U.d2(car.global_position, pp)
		if d > 4.0:
			continue
		var rear: Vector3 = car.global_position - car.fwd_dir() * (car.L / 2 + 0.6)
		var d_rear := U.d2(rear, pp)
		if car.personal and d_rear < 1.6:
			var a := []
			a.append(act("Change outfit (spare: %s)" % Game.OUTFITS[Game.spare_outfit].name, 1.8, func(): change_outfit("trunk")))
			if not Game.bag.is_empty():
				a.append(act("Stash bag in trunk (%s)" % U.money(Robbery.bag_value(Game.bag)), 1.0, func():
					car.trunk.append_array(Game.bag)
					Game.bag.clear()
					Game.notify("Bag stashed in trunk", "good")))
			var pt = Game.partner
			if not Game.partner_bag.is_empty() and pt and U.d2(pt.global_position, car.global_position) < 5.0:
				a.append(act("Stash partner bag in trunk", 1.0, func():
					car.trunk.append_array(Game.partner_bag)
					Game.partner_bag.clear()
					Game.notify("Partner bag stashed", "good")))
			if not car.trunk.is_empty():
				a.append(act("Take loot from trunk (%s)" % U.money(Robbery.bag_value(car.trunk)), 1.0, func(): take_from_trunk(car)))
			out.append({"pos": rear, "d": d_rear - 0.3, "actions": a})
			continue
		var cop_inside := false
		for k in Game.chars:
			if k.in_car == car and k.role == "cop":
				cop_inside = true
		if d < 3.2 and car.kind != "truck" and not (car.kind == "police" and cop_inside):
			var label := "Carjack" if car.npc_driver else ("Steal police car" if car.kind == "police" else ("Get in your car" if car.personal else "Steal car"))
			out.append({"pos": car.global_position, "d": d - 1.0, "actions": [act(label, 0.0 if (car.npc_driver or car.personal) else 1.2, func(): enter_car(car))]})
	for c in Game.chars:
		if c == self or c.hidden or c.role == "partner" or c.role == "fence":
			continue
		var d := U.d2(c.global_position, pp)
		if d > (2.6 if c.role in ["pedestrian", "driver"] else 1.8):
			continue
		if (c.ko or c.dead) and (c.has_code or c.has_key) and not c.searched and c.site != null:
			out.append({"pos": c.global_position, "d": d - 0.2, "actions": [act("Search body", 1.4, func(): search_body(c))]})
			continue
		if c.ko or c.dead:
			continue
		var facing := cos(U.ang_diff(c.yaw, U.ang_to(c.global_position, pp)))
		var helpless: bool = c.pose in ["cower", "kneel", "handsup", "work"] or c.state == "surrendered"
		var unaware: bool = facing < 0.2 or not c.armed
		var npc_ai = Game.main.npc_ai
		var people: bool = c.role in ["civilian", "pedestrian", "driver", "staff", "teller", "clerk"]
		if helpless or unaware or people:
			var nm := role_name(c)
			var a := []
			if helpless and people and not c.mem.get("tied", false):
				var n: int = Game.tools.get("zipties", 0)
				a.append(act("Zip-tie %s (%d left)" % [nm, n], 1.2, func(): npc_ai.zip_tie(c), {"crime": true, "disabled": n <= 0}))
			if helpless and c.role in ["civilian", "pedestrian", "driver"] and not c.mem.get("robbed", false):
				a.append(act("Take their wallet", 1.0, func(): npc_ai.rob_wallet(c), {"crime": true}))
			a.append(act("Take down " + nm, 0.5, func(): takedown(c), {"crime": true}))
			if c.state == "surrendered" and (c.has_code or c.has_key) and not c.searched:
				a.append(act("Search " + nm, 1.4, func(): search_body(c), {"crime": true}))
			if not helpless and not weapon and c.role in ["pedestrian", "driver"] and c.state in ["walk", "idle", "confront"]:
				a.push_front(act("Antagonize", 0.0, func(): npc_ai.antagonize(c)))
				a.push_front(act("Greet", 0.0, func(): npc_ai.greet(c)))
			out.append({"pos": c.global_position, "d": d + 0.3, "actions": a})
	var pt = Game.partner
	if pt and not pt.hidden and U.d2(pt.global_position, pp) < 2.6:
		var a := []
		if not Game.bag.is_empty() and Game.partner_bag.is_empty():
			a.append(act("Pass bag to partner (%s)" % U.money(Robbery.bag_value(Game.bag)), 0.6, func():
				Game.partner_bag.append_array(Game.bag)
				Game.bag.clear()
				Game.notify("Partner is carrying the bag", "good")
				Sfx.play("click")))
		if not Game.partner_bag.is_empty() and Game.bag.is_empty():
			a.append(act("Take bag back from partner", 0.6, func():
				Game.bag.append_array(Game.partner_bag)
				Game.partner_bag.clear()
				Sfx.play("click")))
		if not a.is_empty():
			out.append({"pos": pt.global_position, "d": U.d2(pt.global_position, pp) + 0.6, "actions": a})
	return out

func take_from_trunk(car) -> void:
	var room: float = Game.bag_cap - Robbery.bag_weight(Game.bag)
	var moved := 0.0
	for i in range(car.trunk.size() - 1, -1, -1):
		var it: Dictionary = car.trunk[i]
		if it.w <= room - moved:
			moved += it.w
			Game.bag.append(it)
			car.trunk.remove_at(i)
	Game.notify("Took what fits in your bag" if not car.trunk.is_empty() else "Took all loot from the trunk")

func takedown(c) -> void:
	c.knock_out()
	Sfx.play("kick")
	if c.site != null:
		Game.robbery.crime(c.site, "takedown")
	if c.mem.get("carry_case", false):
		Game.main.npc_ai.drop_case(c)
	if c.role == "cop":
		Game.police.raise_stars(maxi(3, Game.wanted.stars), global_position, "Assaulted an officer")
	else:
		Game.notify(role_name(c).capitalize() + " knocked out")
		Game.main.npc_ai.crime_event(c.global_position, "Assault", 1, 14.0)

func search_body(c) -> void:
	c.searched = true
	var found := []
	if c.has_code and c.site != null:
		Game.known_codes[c.site.id] = true
		found.append("safe code " + c.site.code)
	if c.has_key and c.site != null:
		Game.keys[c.site.id] = true
		found.append("staff door key")
	Game.notify("Found: " + " + ".join(found) if not found.is_empty() else "Nothing useful", "good" if not found.is_empty() else "")
	if not found.is_empty():
		Sfx.play("good")

func enter_car(car) -> void:
	if car.npc_driver:
		var d = car.npc_driver
		d.in_car = null
		d.set_hidden(false)
		d.role = "driver"
		d.teleport(car.global_position - U.right(car.yaw()) * 1.8)
		Game.main.npc_ai.give_traits(d)
		Game.main.npc_ai.crime_event(car.global_position, "Carjacking", 1, 18.0)
		d.state = "flee"
		d.mem.erase("dest")
		car.npc_driver = null
		car.ai = {}
		Game.notify("Carjacked! The driver will call the cops.", "warn")
	if car.kind == "police":
		Game.police.raise_stars(maxi(2, Game.wanted.stars), car.global_position, "Stole a police car")
	car.parked = false
	if car.ai.get("kind", "") == "traffic":
		car.ai = {}
	in_car = car
	car.driver = "player"
	car.sleeping = false
	set_hidden(true)
	weapon = false
	action = null
	var pt = Game.partner
	if pt and pt.in_car == null and U.d2(pt.global_position, car.global_position) < 18.0:
		pt.in_car = car
		pt.set_hidden(true)
	Sfx.play("click")

func exit_car() -> void:
	var car = in_car
	if car == null:
		return
	var side: Vector3 = -U.right(car.yaw()) * 1.9
	var p: Vector3 = Game.main.nav.free_point(car.global_position + side)
	in_car = null
	set_hidden(false)
	teleport(p)
	car.driver = null
	car.release()
	car.handbrake = true
	yaw = car.yaw()
	crumbs.clear()
	var pt = Game.partner
	if pt and pt.in_car == car:
		pt.in_car = null
		pt.set_hidden(false)
		pt.teleport(Game.main.nav.free_point(car.global_position + U.right(car.yaw()) * 1.9))

func current_actions():
	if dead:
		return null
	var best = null
	var bd := 1e9
	for c in dynamic_candidates():
		if not c.actions.is_empty() and c.d < bd:
			bd = c.d
			best = {"target": c, "actions": c.actions}
	if in_car == null:
		var f := U.fwd(yaw)
		for it in Game.interactables:
			var d := U.d2(it.pos, global_position)
			if d > it.r:
				continue
			var facing: float = ((it.pos.x - global_position.x) * f.x + (it.pos.z - global_position.z) * f.z) / maxf(0.01, d)
			var acts: Array = it.actions.call()
			var score := d - facing * 0.25
			if not acts.is_empty() and score < bd:
				bd = score
				best = {"target": it, "actions": acts}
	return best

func start_action(a, target) -> void:
	if a == null or a.get("disabled", false):
		return
	if a.dur <= 0.0:
		if a.run is Callable:
			a.run.call()
		return
	action = a.duplicate()
	action.t = 0.0
	action.anchor = target.get("pos", global_position)
	action.r = target.get("r", 1.6) + 0.9
	if a.get("drill", false):
		Sfx.play("drill")

func update_action(dt: float, moving: bool) -> void:
	if action == null:
		return
	if moving or in_car or U.d2(global_position, action.anchor) > action.r + 0.6:
		action = null
		return
	action.t += dt
	if action.get("drill", false) and floori(action.t * 3.0) != floori((action.t - dt) * 3.0):
		Sfx.play("drill", 0.7)
	if action.t >= action.dur:
		var a = action
		action = null
		if a.run is Callable:
			a.run.call()

# ---------- per-tick update (physics rate) ----------
func key(k: Key) -> bool:
	return Input.is_physical_key_pressed(k)

func update_player(dt: float) -> void:
	if dead:
		return
	var jx: float = inp.jx
	var jy: float = inp.jy
	if key(KEY_W) or key(KEY_UP): jy = 1.0
	if key(KEY_S) or key(KEY_DOWN): jy = -1.0
	if key(KEY_A) or key(KEY_LEFT): jx = -1.0
	if key(KEY_D) or key(KEY_RIGHT): jx = 1.0
	var sprint: bool = inp.sprint or key(KEY_SHIFT)
	shoot_cd -= dt
	if in_car:
		var car: Vehicle = in_car
		var k_gas := key(KEY_W) or key(KEY_UP)
		var k_brake := key(KEY_S) or key(KEY_DOWN)
		var thr := (1.0 if (inp.gas or k_gas) else 0.0) - (1.0 if (inp.brake or k_brake) else 0.0)
		if not inp.gas and not inp.brake and not k_gas and not k_brake:
			thr = clampf(inp.jy * 1.25, -1.0, 1.0) if absf(inp.jy) > 0.3 else 0.0
		var st := -1.0 if (key(KEY_A) or key(KEY_LEFT)) else (1.0 if (key(KEY_D) or key(KEY_RIGHT)) else signf(inp.jx) * pow(absf(inp.jx), 1.35))
		car.throttle = thr
		car.steer_in = st
		car.handbrake = inp.handbrake or key(KEY_SPACE)
		if car.crouched:
			if absf(thr) > 0.1 or absf(st) > 0.3:
				car.crouched = false
			else:
				car.throttle = 0.0
				car.handbrake = true
		global_position = Vector3(car.global_position.x, 0, car.global_position.z)
		var sp := car.linear_velocity.length()
		Sfx.set_loop("engine", 0.5 + absf(thr) * 0.35, 0.7 + car.rpm * 0.9 + car.gear * 0.04)
		Sfx.set_loop("screech", clampf((car.slip - 2.0) / 6.0, 0.15, 1.0) if (car.slip > 2.2 and sp > 3.0) else 0.0)
		speed_now = 0.0
		update_action(dt, false)
		return
	Sfx.set_loop("engine", 0.0)
	Sfx.set_loop("screech", 0.0)
	var cam = Game.main.camera
	var mag := minf(1.0, Vector2(jx, jy).length())
	if surrendering:
		if mag > 0.5 or weapon or Game.wanted.stars == 0:
			surrendering = false
			if Game.wanted.stars > 0:
				Game.notify("You broke your surrender!", "bad")
		else:
			move_dir(Vector3.ZERO, 0.0, dt)
			pose = "handsup"
			show_gun = false
			speed_now = 0.0
			return
	var mv := U.fwd(cam.yaw) * jy + U.right(cam.yaw) * jx
	var moving := mag > 0.15
	var spd := 0.0
	if moving:
		mv = mv.normalized()
		var run := (sprint or mag > 0.97) and not weapon
		spd = (3.0 if weapon else (6.2 if run else 3.4)) * (1.0 if run else maxf(0.45, mag))
		if not weapon:
			yaw += U.ang_diff(yaw, atan2(mv.x, mv.z)) * minf(1.0, dt * 12.0)
	move_dir(mv if moving else Vector3.ZERO, spd, dt)
	if weapon:
		yaw = cam.yaw
	speed_now = spd
	pose = "aim" if weapon else ("work" if action != null else "stand")
	show_gun = weapon
	bag_mesh.visible = not Game.bag.is_empty()
	if crumbs.is_empty() or U.d2(crumbs[crumbs.size() - 1], global_position) > 0.7:
		crumbs.append(global_position)
	update_action(dt, moving)
	if weapon and (inp.fire or key(KEY_F) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED):
		fire()
