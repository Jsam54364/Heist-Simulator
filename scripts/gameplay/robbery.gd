class_name Robbery
extends Node
## Robbery systems: sites, crimes, alarms, footage/witnesses, loot & duffel bags,
## doors, C4, security cameras, the bank vault + armored truck, dye packs,
## Pay 'N' Spray and site restocking. Port of robbery.js.

var vault := {"pivot": null, "col": null, "state": "closed", "t": 0.0, "open_time": 35.0, "site": null, "bounds": Rect2(), "body": null}
var truck := {"state": "wait", "t": 50.0, "car": null, "guard": null, "panic": 0.0}
var spray := {"bounds": Rect2(), "busy": 0.0, "door": null, "done": -99.0, "warned": -99.0}
var bombs: Array = []
var cam_tick := 0.0
const TRUCK_STOP := Vector3(27.5, 0, 3.2)

# ---------- sites ----------
func make_site(def: Dictionary) -> Dictionary:
	var s := {
		"alarm_armed": true, "alarm_triggered": false, "robbery_active": false, "left_reported": false, "last_crime": -999.0,
		"footage": {"face": false, "outfit": -1, "destroyed": false}, "cloud": {"face": false, "outfit": -1},
		"cameras": [], "npcs": [], "doors": [], "player_inside": false, "vault_hit": false, "take": 0.0,
		"code": str(randi_range(1000, 9999)), "safe_open": false, "register": 0.0, "safe_loot": 0.0,
	}
	s.merge(def, true)
	var g := Node3D.new()
	g.name = "Site_" + s.id
	Game.world.add_child(g)
	s.group = g
	Game.sites.append(s)
	return s

func crime(site, _kind := "") -> void:
	if site == null:
		return
	site.last_crime = Game.t
	if not site.robbery_active:
		site.robbery_active = true
		Game.notify("Robbery in progress - " + site.name, "warn")

func trigger_alarm(site: Dictionary, why: String) -> void:
	if site.alarm_triggered:
		return
	site.alarm_triggered = true
	site.robbery_active = true
	site.last_crime = Game.t
	Game.notify("ALARM - %s. Police dispatched." % why, "bad")
	Sfx.play("bad")
	transmit(site)
	Game.police.report(4 if site.vault_hit else site.alarm_stars, site.door, "Silent alarm at " + site.name)

## Police receive footage + statements (alarm, or when you leave the building)
func transmit(site: Dictionary) -> void:
	var face: bool = site.cloud.face or (not site.footage.destroyed and site.footage.face)
	var outfit: int = site.cloud.outfit if site.cloud.outfit >= 0 else (site.footage.outfit if not site.footage.destroyed else -1)
	for n in site.npcs:
		if not is_instance_valid(n) or n.dead or n.ko or not n.saw_crime:
			continue
		if n.saw_face:
			face = true
		if n.saw_outfit >= 0:
			outfit = n.saw_outfit
	if face:
		if Game.heat.face <= 0.0:
			Game.notify("Your face is on record - IDENTIFIED. Masks help next time.", "bad")
		Game.heat.face = 240.0
	if outfit >= 0:
		if Game.heat.outfit != outfit:
			Game.notify("Police have a description of your outfit", "warn")
		Game.heat.outfit = outfit
		Game.heat.outfit_t = 180.0

# ---------- loot ----------
static func item_weight(type: String, value: float) -> float:
	return value / 2500.0 if type == "marked" else value / 5000.0

static func bag_weight(items: Array) -> float:
	var s := 0.0
	for i in items:
		s += i.w
	return s

static func bag_value(items: Array) -> float:
	var s := 0.0
	for i in items:
		s += i.value
	return s

func add_loot(type: String, value: float, dye: bool, src, site) -> bool:
	var w := item_weight(type, value)
	if bag_weight(Game.bag) + w > Game.bag_cap + 0.01:
		Game.notify("Duffel bag is full - pass it to your partner or stash it in a trunk", "warn")
		Sfx.play("bad", 0.6)
		return false
	var has_dye: bool = dye and not Game.tools.jammer
	Game.bag.append({"type": type, "value": value, "dye": has_dye, "src": src, "w": w})
	if site != null:
		site.take += value
	Sfx.play("cash")
	Game.notify("+%s %s in bag%s" % [U.money(value), "marked bills" if type == "marked" else "jewelry", " (dye pack!)" if has_dye else ""], "good")
	return true

func add_cash(n: float, site = null) -> void:
	Game.money.cash += n
	if site != null:
		site.take += n
	Sfx.play("cash")
	Game.notify("+%s cash" % U.money(n), "good")

# ---------- doors ----------
func make_door(site, o: Dictionary) -> Dictionary:
	var body := StaticBody3D.new()
	body.collision_layer = Game.L_WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(o.w, 2.65, o.d)
	cs.shape = bs
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = bs.size
	mi.mesh = bm
	mi.material_override = Mats.m("reinforced" if o.kind == "reinforced" else "locked")
	body.add_child(mi)
	body.position = Vector3(o.x, 1.325, o.z)
	(site.group if site else Game.world).add_child(body)
	var col = Game.main.builder_cols_add(Vector3(o.x - o.w / 2, 0, o.z - o.d / 2), Vector3(o.x + o.w / 2, 2.65, o.z + o.d / 2), "door")
	var door := {"site": site, "kind": o.kind, "body": body, "shape": cs, "mesh": mi, "open": false, "pos": Vector3(o.x, 0, o.z), "col": col, "temp_open": false}
	Game.doors.append(door)
	if site:
		site.doors.append(door)
	return door

func open_door(door: Dictionary, blown := false) -> void:
	if door.open:
		return
	door.open = true
	door.shape.set_deferred("disabled", true)
	door.mesh.visible = false
	door.col["disabled"] = true
	Game.main.nav.update_col(door.col)

func close_door(door: Dictionary) -> void:
	door.open = false
	door.temp_open = false
	door.shape.set_deferred("disabled", false)
	door.mesh.visible = true
	door.col["disabled"] = false
	Game.main.nav.update_col(door.col)

# ---------- explosives + particles ----------
func plant_c4(pos: Vector3, site, on_blow: Callable) -> void:
	var m := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.25, 0.18, 0.12)
	m.mesh = bm
	var mat := Mats.solid(Color("d9d9d9"), 0.5, 0.0, 0.0)
	mat.emission_enabled = true
	mat.emission = Color.RED
	m.material_override = mat
	m.position = Vector3(pos.x, 1.1, pos.z)
	Game.world.add_child(m)
	bombs.append({"pos": pos, "t": 3.0, "mesh": m, "mat": mat, "site": site, "on_blow": on_blow})
	Game.tools.c4 -= 1
	Game.notify("C4 planted - get clear! (3s)", "warn")

func _update_bombs(dt: float) -> void:
	for i in range(bombs.size() - 1, -1, -1):
		var b: Dictionary = bombs[i]
		var before: float = b.t
		b.t -= dt
		b.mat.emission_energy_multiplier = 3.0 if int(b.t * 6.0) % 2 == 0 else 0.0
		if int(before * 6.0) != int(b.t * 6.0):
			Sfx.play("beep", 0.6)
		if b.t <= 0.0:
			b.mesh.queue_free()
			bombs.remove_at(i)
			Sfx.play("boom")
			puff(b.pos + Vector3(0, 1, 0), Color("ffaa33"), 40, 3.0, true)
			Game.add_noise(b.pos, 60)
			b.on_blow.call()
			for c in Game.chars:
				var d := U.d2(c.global_position, b.pos)
				if d < 4.0 and not c.hidden:
					Game.main.damage(c, roundf(90.0 * (1.0 - d / 4.0)), "blast")
			if b.site:
				crime(b.site, "c4")
				trigger_alarm(b.site, "Explosion")

func puff(pos: Vector3, color: Color, n := 16, spread := 1.5, fire := false) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = n
	p.lifetime = 1.4
	var m := BoxMesh.new()
	m.size = Vector3(0.3, 0.3, 0.3)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	if fire:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 2.0
	m.material = mat
	p.mesh = m
	p.direction = Vector3.UP
	p.spread = 60.0
	p.initial_velocity_min = spread * 0.8
	p.initial_velocity_max = spread * 2.2
	p.gravity = Vector3(0, -2.0, 0)
	p.scale_amount_min = 0.8
	p.scale_amount_max = 2.2
	var grad := Gradient.new()
	grad.set_color(0, Color(color, 0.95))
	grad.set_color(1, Color(color.darkened(0.5), 0.0))
	p.color_ramp = grad
	p.position = pos
	Game.world.add_child(p)
	p.emitting = true
	get_tree().create_timer(2.0).timeout.connect(p.queue_free)

# ---------- security cameras ----------
func make_camera(site: Dictionary, pos: Vector3, aim: Vector3, cloud := false) -> Dictionary:
	var root := Node3D.new()
	site.group.add_child(root)
	root.position = pos
	root.look_at_from_position(pos, aim, Vector3.UP)
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.22, 0.2, 0.42)
	body.mesh = bm
	body.material_override = Mats.solid(Color("dff6ff") if cloud else Color("e8e8e8"), 0.4)
	root.add_child(body)
	var lens := MeshInstance3D.new()
	var lm := BoxMesh.new()
	lm.size = Vector3(0.12, 0.12, 0.05)
	lens.mesh = lm
	var lmat := Mats.solid(Color("ff1030"), 0.3, 0.0, 0.2)
	lens.material_override = lmat
	lens.position = Vector3(0, 0, -0.23)
	root.add_child(lens)
	if cloud:
		var fin := MeshInstance3D.new()
		var fm := BoxMesh.new()
		fm.size = Vector3(0.3, 0.05, 0.05)
		fin.mesh = fm
		fin.material_override = Mats.solid(Color("2de2e6"), 0.3, 0.0, 1.5)
		fin.position.y = 0.14
		root.add_child(fin)
	# focus-mode view cone
	var cone := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = tan(0.66) * 14.0
	cm.height = 14.0
	cm.radial_segments = 20
	cm.cap_bottom = false
	cone.mesh = cm
	var cmat := StandardMaterial3D.new()
	cmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	cmat.albedo_color = Color(0.18, 0.89, 0.9, 0.1) if cloud else Color(1, 0.2, 0.33, 0.1)
	cone.material_override = cmat
	cone.rotation.x = PI / 2
	cone.position = Vector3(0, 0, -7.0)
	cone.visible = false
	root.add_child(cone)
	var cam := {"site": site, "pos": pos, "dir": (aim - pos).normalized(), "cloud": cloud, "destroyed": false, "root": root, "lens": lmat, "cone": cone, "seeing": false, "range": 16.0, "fov_cos": cos(0.66)}
	site.cameras.append(cam)
	return cam

func destroy_cam(cam: Dictionary) -> void:
	if cam.destroyed:
		return
	cam.destroyed = true
	cam.seeing = false
	cam.root.rotation.x += 0.9
	cam.root.position.y -= 0.25
	cam.lens.emission_energy_multiplier = 0.0
	cam.lens.albedo_color = Color("111111")
	cam.cone.visible = false
	puff(cam.pos, Color("666666"), 6, 0.6)
	Game.notify("Cloud camera destroyed - what it already uploaded is gone to the cloud" if cam.cloud else "Camera destroyed")

func _update_cameras(dt: float) -> void:
	cam_tick -= dt
	if cam_tick > 0.0:
		return
	cam_tick = 0.2
	var P = Game.player
	var chest: Vector3 = P.global_position + Vector3(0, 1.3, 0)
	for s in Game.sites:
		var near: bool = U.in_bounds(P.global_position, s.bounds, 2.0) and P.in_car == null
		var suspicious: bool = P.weapon or P.masked or s.robbery_active or (P.action != null and P.action.get("crime", false))
		for cam in s.cameras:
			cam.cone.visible = Game.focus and not cam.destroyed
			if cam.destroyed:
				continue
			var see := false
			if near:
				var to: Vector3 = chest - cam.pos
				var d := to.length()
				if d < cam.range and to.dot(cam.dir) / d > cam.fov_cos:
					see = Game.main.los(cam.pos + to.normalized() * 0.35, chest)
			cam.seeing = see
			cam.lens.emission_energy_multiplier = (3.0 if suspicious else 1.2) if see else 0.2
			if see and suspicious:
				if not cam.cloud and s.footage.destroyed:
					continue
				var rec: Dictionary = s.cloud if cam.cloud else s.footage
				if not P.masked:
					rec.face = true
				rec.outfit = Game.outfit

# ---------- vault + armored truck ----------
func open_vault() -> void:
	if vault.state == "closed":
		vault.state = "opening"
		vault.t = 0.0
		Game.notify("The bank vault is opening!", "warn")

func _update_vault(dt: float) -> void:
	if vault.pivot == null:
		return
	var target := -1.9 if vault.state in ["opening", "open"] else 0.0
	vault.pivot.rotation.y = lerpf(vault.pivot.rotation.y, target, minf(1.0, dt * 1.6))
	vault.t += dt
	if vault.state == "opening" and vault.t > 2.0:
		vault.state = "open"
		vault.t = 0.0
		vault.shape.set_deferred("disabled", true)
		vault.col["disabled"] = true
		Game.main.nav.update_col(vault.col)
	elif vault.state == "open" and vault.t > vault.open_time:
		vault.state = "closing"
		vault.t = 0.0
		Game.notify("Vault closing!", "bad")
	elif vault.state == "closing" and vault.t > 2.0:
		vault.state = "closed"
		vault.shape.set_deferred("disabled", false)
		vault.col["disabled"] = false
		Game.main.nav.update_col(vault.col)
		if U.in_bounds(Game.player.global_position, vault.bounds) and not Game.player.dead:
			Game.main.locked_in()
		for c in Game.chars:
			if c != Game.player and U.in_bounds(c.global_position, vault.bounds):
				c.teleport(Vector3(25, 0, 22.3))

func truck_eta() -> float:
	return truck.t if truck.state == "wait" else 0.0

func _update_truck(dt: float) -> void:
	var ts := truck
	ts.t -= dt
	if ts.state == "wait":
		if ts.t <= 0.0:
			ts.car = Game.main.spawn_car("truck", Vector3(-144, 0, 3.2), PI / 2)
			ts.car.ai = {"kind": "armored"}
			ts.state = "drive"
			Game.notify("Armored truck is on its way to Leonida Federal")
		return
	var car = ts.car
	if car == null or not is_instance_valid(car) or car.removed:
		ts.state = "wait"
		ts.t = 150.0
		return
	if car.driver == "player":
		return
	if ts.state == "drive":
		var d: float = car.drive_to(TRUCK_STOP, 11.0, dt)
		if d < 1.4:
			car.drive_to(car.global_position, 0, dt, {"stop": true})
			ts.state = "parked"
			var rear: Vector3 = car.global_position - car.fwd_dir() * 3.8
			var g: Character = Game.main.spawn_char("truckguard", rear, {"hp": 80.0, "yaw": car.yaw() + PI})
			g.state = "deliver"
			g.mem.route = [Vector3(24.0, 0, 6.8), Vector3(25, 0, 8.4), Vector3(25, 0, 10.5), Vector3(33.8, 0, 15.6), Vector3(35.2, 0, 19.3), Vector3(30.25, 0, 19.6), Vector3(30.25, 0, 22.2), Vector3(25, 0, 22.3)]
			g.mem.ri = 0
			g.mem.carry_case = true
			ts.guard = g
	elif ts.state == "parked":
		car.drive_to(car.global_position, 0, dt, {"stop": true})
		var g = ts.guard
		if g == null or not is_instance_valid(g) or g.state == "boarded":
			if g != null and is_instance_valid(g):
				Game.main.remove_char(g)
			ts.guard = null
			ts.state = "leave"
		elif (g.dead or g.ko or g.state in ["surrendered", "alert"]) and ts.panic == 0.0:
			ts.panic = Game.t
		if ts.panic > 0.0 and Game.t - ts.panic > 25.0:
			ts.state = "leave"
			ts.panic = 0.0
			if g != null and is_instance_valid(g) and not g.dead and not g.ko and U.d2(g.global_position, Game.player.global_position) > 25.0:
				Game.main.remove_char(g)
			ts.guard = null
	elif ts.state == "leave":
		var d: float = car.drive_to(Vector3(144, 0, 3.2), 13.0, dt, {"arrive": false})
		if d < 6.0:
			Game.main.remove_car(car)
			ts.car = null
			ts.state = "wait"
			ts.t = 150.0

# ---------- dye packs ----------
func _update_dye() -> void:
	if Game.tools.jammer:
		return
	var containers := [[Game.bag, Game.player.global_position]]
	if Game.partner:
		containers.append([Game.partner_bag, Game.partner.global_position])
	for car in Game.cars:
		if not car.trunk.is_empty():
			containers.append([car.trunk, car.global_position])
	for ct in containers:
		var items: Array = ct[0]
		var ruined := 0.0
		for i in range(items.size() - 1, -1, -1):
			var it: Dictionary = items[i]
			if not it.dye or it.src == null:
				continue
			if U.d2(ct[1], it.src) > 75.0:
				ruined += it.value
				items.remove_at(i)
		if ruined > 0.0:
			Sfx.play("boom", 0.4)
			puff(ct[1] + Vector3(0, 1.2, 0), Color("d81b3a"), 26, 1.4)
			Game.notify("Dye pack exploded - %s in marked bills ruined. A Dye-Pack Jammer prevents this." % U.money(ruined), "bad")

func dye_warning() -> float:
	if Game.tools.jammer:
		return -1.0
	var worst := -1.0
	for pair in [[Game.bag, Game.player.global_position], [Game.partner_bag, Game.partner.global_position if Game.partner else Vector3.ZERO]]:
		for it in pair[0]:
			if it.dye and it.src != null:
				worst = maxf(worst, U.d2(pair[1], it.src))
	return worst

# ---------- site enter/leave + restock ----------
func _update_sites(_dt: float) -> void:
	var P = Game.player
	var alarm_vol := 0.0
	for s in Game.sites:
		var inside: bool = U.in_bounds(P.global_position, s.bounds) and P.in_car == null
		if s.player_inside and not inside and s.robbery_active and not s.left_reported:
			s.left_reported = true
			transmit(s)
			Game.police.report(4 if s.vault_hit else s.leave_stars, s.door, "Robbery reported at " + s.name)
			if s.take > 0.0:
				Game.stats.robberies += 1
				Game.stats.best = maxf(Game.stats.best, s.take)
		s.player_inside = inside
		if s.robbery_active and Game.t - s.last_crime > 150.0 and U.d2(P.global_position, s.door) > 60.0 and Game.wanted.stars == 0:
			reset_site(s)
		if s.alarm_triggered:
			alarm_vol = maxf(alarm_vol, clampf(1.0 - U.d2(P.global_position, s.door) / 70.0, 0.0, 1.0))
	Sfx.set_loop("alarm", alarm_vol)

func reset_site(s: Dictionary) -> void:
	s.alarm_armed = true
	s.alarm_triggered = false
	s.robbery_active = false
	s.left_reported = false
	s.vault_hit = false
	s.take = 0.0
	s.footage = {"face": false, "outfit": -1, "destroyed": false}
	s.cloud = {"face": false, "outfit": -1}
	s.code = str(randi_range(1000, 9999))
	Game.known_codes.erase(s.id)
	Game.keys.erase(s.id)
	for d in s.doors:
		close_door(d)
	for cam in s.cameras:
		if cam.destroyed:
			cam.destroyed = false
			cam.root.rotation.x -= 0.9
			cam.root.position.y += 0.25
			cam.lens.albedo_color = Color("ff1030")
	for n in s.npcs:
		if is_instance_valid(n):
			Game.main.remove_char(n)
	s.npcs = []
	if s.has("on_reset"):
		s.on_reset.call()
	Game.notify("%s has restocked" % s.name)

# ---------- Pay 'N' Spray ----------
func _update_spray(dt: float) -> void:
	var P = Game.player
	if P.in_car == null:
		spray.busy = 0.0
		return
	var car = P.in_car
	if not U.in_bounds(car.global_position, spray.bounds) or absf(car.speed()) > 1.0:
		spray.busy = 0.0
		return
	if Game.t - spray.done < 6.0:
		return
	var seen: bool = Game.wanted.stars > 0 and Game.wanted.seen_ago < 1.5
	if seen:
		if Game.t - spray.warned > 4.0:
			Game.notify("Pay 'N' Spray won't work while cops can see you", "warn")
			spray.warned = Game.t
		return
	var cost := 500.0
	if Game.money.cash + Game.money.bank < cost:
		if Game.t - spray.warned > 4.0:
			Game.notify("Pay 'N' Spray costs $500", "warn")
			spray.warned = Game.t
		return
	spray.busy += dt
	if spray.door:
		spray.door.position.y = 4.0 - minf(1.0, spray.busy / 0.6) * 2.4
	if spray.busy > 2.2:
		spray.busy = 0.0
		spray.done = Game.t
		if spray.door:
			spray.door.position.y = 4.0
		if Game.money.bank >= cost:
			Game.money.bank -= cost
		else:
			Game.money.cash -= cost - Game.money.bank
			Game.money.bank = 0.0
		var c: int = car.color_idx
		while c == car.color_idx:
			c = randi() % Game.CAR_COLORS.size()
		car.set_color(c)
		if Game.heat.car_id == car.car_id:
			Game.heat.car_id = -1
			Game.heat.car_t = 0.0
		if Game.wanted.stars > 0:
			Game.police.clear_stars("Fresh paint - the cops lost you")
		else:
			Game.notify("Resprayed - police no longer recognise this car", "good")
		Sfx.play("good")

func update(dt: float) -> void:
	_update_cameras(dt)
	_update_vault(dt)
	_update_truck(dt)
	_update_dye()
	_update_sites(dt)
	_update_bombs(dt)
	_update_spray(dt)
	if Game.wanted.stars == 0:
		var H := Game.heat
		if H.face > 0.0:
			H.face = maxf(0.0, H.face - dt)
		if H.outfit_t > 0.0:
			H.outfit_t -= dt
			if H.outfit_t <= 0.0:
				H.outfit = -1
		if H.car_t > 0.0:
			H.car_t -= dt
			if H.car_t <= 0.0:
				H.car_id = -1
	Game.noise = Game.noise.filter(func(n): return Game.t - n.t < 0.5)
