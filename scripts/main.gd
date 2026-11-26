extends Node3D
## Game root: builds the city and robbery sites, spawns the cast, runs the fixed-rate
## simulation (60 Hz physics ticks, interpolated rendering) and routes game events
## (damage, run-overs, crashes, WASTED/BUSTED). Port of main.js.

const KEEP := [[20, -7.4], [-25, -7.4], [25, 7.4], [-72, -7.5], [74, -7.5], [-26, 9], [-11, 27.5], [70, 9.5], [34.5, -7.5],
	[-61.5, -7.5], [17, 7.5], [69, -6.6], [30.1, -8], [39.1, 7.5], [-37.8, -8], [37.5, 22.3], [12.5, 27.75], [14.25, -22], [-31.25, -24]]
const SPAWN := Vector3(74, 0, -7.6)
const PED_COLORS := [Color("b0b8c0"), Color("9db4c8"), Color("c8b49d"), Color("a8c89d"), Color("c89dbb")]

@onready var camera: FollowCamera = $Camera
@onready var sun: DirectionalLight3D = $Sun
var world: Node3D
var builder: MeshBuilder
var nav: NavGrid
var site_builder: SiteBuilder
var npc_ai: Node
var traffic: Node
var fx: Fx
var hud: Hud
var player_ctl: Player
var _ray := PhysicsRayQueryParameters3D.new()
var cull_t := 0.0

func _ready() -> void:
	Game.main = self
	Game.reset_state()
	world = Node3D.new()
	world.name = "World"
	add_child(world)
	Game.world = world
	var robbery := Robbery.new()
	robbery.name = "Robbery"
	add_child(robbery)
	Game.robbery = robbery
	var police := preload("res://scripts/actors/police.gd").new()
	police.name = "Police"
	add_child(police)
	Game.police = police
	npc_ai = preload("res://scripts/actors/npc_ai.gd").new()
	npc_ai.name = "NpcAI"
	add_child(npc_ai)
	traffic = preload("res://scripts/gameplay/traffic.gd").new()
	traffic.name = "Traffic"
	add_child(traffic)
	fx = Fx.new()
	fx.name = "Fx"
	add_child(fx)
	# --- static world ---
	builder = MeshBuilder.new(world)
	var city := CityGen.new(builder)
	city.build(KEEP)
	site_builder = SiteBuilder.new(builder)
	site_builder.build()
	builder.finalize(world)
	_add_ocean()
	nav = NavGrid.new(builder.cols)
	Roads.build()
	# --- cast ---
	player_ctl = Player.new().setup("player", SPAWN, {"hp": 100.0, "yaw": -PI / 2}) as Player
	player_ctl.name = "Player"
	world.add_child(player_ctl)
	Game.player = player_ctl
	Game.chars.append(player_ctl)
	var partner := spawn_char("partner", SPAWN + Vector3(-1.8, 0, 1.0), {"hp": 999.0, "yaw": -PI / 2})
	var bag := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.5, 0.35, 0.3)
	bag.mesh = bm
	bag.material_override = Mats.solid(Color("1d1f22"), 0.8)
	bag.position = Vector3(0, 1.15, -0.28)
	bag.visible = false
	partner.inner.add_child(bag)
	partner.bag_mesh = bag
	Game.partner = partner
	Game.player_car = spawn_car("coupe", Vector3(69, 0, -4.95), -PI / 2, {"color_idx": 3, "personal": true})
	traffic.spawn()
	for i in 12:
		var p: Vector3 = npc_ai.random_sidewalk()
		var c := spawn_char("pedestrian", nav.free_point(p), {"color": PED_COLORS[i % 5]})
		c.state = "walk"
	site_builder.spawn_parked_cars()
	site_builder.reset_all()
	camera.yaw = -PI / 2
	# --- UI + quality ---
	hud = Hud.new()
	add_child(hud)
	Settings.apply()
	Game.paused = true

func _add_ocean() -> void:
	var sea := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(520, 900)
	pm.subdivide_width = 96
	pm.subdivide_depth = 160
	sea.mesh = pm
	sea.material_override = Mats.m("water")
	sea.position = Vector3(176 + 260, 0.0, 0)
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(sea)
	# far ground so the horizon never shows void past the boundary walls
	var far := MeshInstance3D.new()
	var fm := PlaneMesh.new()
	fm.size = Vector2(1170, 1400)
	far.mesh = fm
	far.material_override = Mats.solid(Color("6d6a60"), 0.95)
	far.position = Vector3(170 - 585, -0.06, 0)
	far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(far)
	# physical ground (road surface height); sidewalks/sand add their own slabs on top
	var gb := StaticBody3D.new()
	gb.name = "Ground"
	gb.collision_layer = Game.L_GROUND
	gb.collision_mask = 0
	var gs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(900, 1, 900)
	gs.shape = box
	gs.position = Vector3(25, -0.48, 0)
	gb.add_child(gs)
	var pmat := PhysicsMaterial.new()
	pmat.friction = 0.9
	gb.physics_material_override = pmat
	world.add_child(gb)

# ---------- spawning ----------
func spawn_char(role: String, pos: Vector3, opts := {}) -> Character:
	var c := Character.new().setup(role, pos, opts)
	if opts.has("color"):
		c.mem.color = opts.color
	world.add_child(c)
	Game.chars.append(c)
	return c

func remove_char(c) -> void:
	if not is_instance_valid(c):
		return
	Game.chars.erase(c)
	if Game.player != null and Game.player.aim_target == c:
		Game.player.aim_target = null
	c.queue_free()

func spawn_car(kind: String, pos: Vector3, yaw: float, opts := {}) -> Vehicle:
	var car := Vehicle.new().setup(kind, pos, yaw, opts)
	world.add_child(car)
	Game.cars.append(car)
	return car

func remove_car(car) -> void:
	if not is_instance_valid(car):
		return
	car.removed = true
	Game.cars.erase(car)
	if car.npc_driver:
		remove_char(car.npc_driver)
	car.queue_free()

func builder_cols_add(minv: Vector3, maxv: Vector3, tag := "") -> Dictionary:
	var c := {"min": minv, "max": maxv, "glass": false, "solid": true, "tag": tag, "ground": false}
	builder.cols.append(c)
	return c

# ---------- queries ----------
func ray(a: Vector3, b: Vector3, mask: int):
	_ray.from = a
	_ray.to = b
	_ray.collision_mask = mask
	_ray.hit_from_inside = false
	var r := get_world_3d().direct_space_state.intersect_ray(_ray)
	return null if r.is_empty() else r

func los(a: Vector3, b: Vector3) -> bool:
	return ray(a, b, Game.L_WORLD) == null

# ---------- events ----------
func damage(c, dmg: float, src = null) -> void:
	var P := player_ctl
	if c == P:
		if P.dead:
			return
		if P.armor > 0.0:
			var a := minf(P.armor, dmg * 0.6)
			P.armor -= a
			dmg -= a
		P.hp -= dmg
		hud.canvas.damage_flash()
		camera.shake = maxf(camera.shake, 0.25)
		if P.hp <= 0.0:
			P.hp = 0.0
			end_life("WASTED")
		return
	if c.role == "partner":
		return
	c.damage(dmg, src)

func on_char_down(c, src) -> void:
	if c.mem.get("carry_case", false):
		npc_ai.drop_case(c)
	if src == player_ctl:
		var pp := player_ctl.global_position
		if c.role == "cop":
			Game.police.raise_stars(clampi(Game.wanted.stars + 1, 3, 5), pp, "Officer down")
		elif c.role != "guard" and c.role != "truckguard":
			if c.site != null:
				Game.robbery.crime(c.site, "murder")
			for k in Game.chars:
				if k.role == "cop" and not k.dead and U.d2(k.in_car.global_position if k.in_car else k.global_position, pp) < 40.0:
					Game.police.raise_stars(3, pp, "Murder witnessed by police")
					break

func on_run_over(c, car, sp: float) -> void:
	if c == player_ctl:
		damage(player_ctl, sp * 3.0, car)
		return
	if c.role == "partner":
		return
	c.knock_out()
	c.damage(sp * 3.0, car)
	Sfx.play("hit", 0.8)
	if car.driver == "player":
		if c.role == "cop":
			Game.police.raise_stars(maxi(3, Game.wanted.stars), car.global_position, "Ran over an officer")
		Game.add_noise(c.global_position, 20.0)

func on_vehicle_impact(car, dv: float) -> void:
	var pp := player_ctl.global_position
	var d := U.d2(car.global_position, pp)
	Sfx.play("crash", clampf(dv / 14.0, 0.15, 1.0) * clampf(1.0 - d / 60.0, 0.0, 1.0))
	if car.driver == "player":
		camera.shake = maxf(camera.shake, clampf(dv / 20.0, 0.1, 0.6))
		if Game.wanted.stars == 0:
			for other in Game.cars:
				if other != car and other.kind == "police" and U.d2(other.global_position, car.global_position) < car.L + 1.5:
					Game.police.raise_stars(1, car.global_position, "Rammed a police car")
					break

func locked_in() -> void:
	Game.notify("Locked inside the vault...", "bad")
	get_tree().create_timer(1.8).timeout.connect(func(): end_life("BUSTED", "Trapped in the vault when it sealed"))

func end_life(kind: String, why := "") -> void:
	var P := player_ctl
	if P.dead:
		return
	P.dead = true
	P.pose = "down" if kind == "WASTED" else "kneel"
	if P.in_car:
		P.exit_car()
	var lost: float = Game.money.cash + Robbery.bag_value(Game.bag) + Robbery.bag_value(Game.partner_bag)
	var fee: float = minf(Game.money.bank, 1000.0 if kind == "WASTED" else 1500.0)
	var body := ""
	if why != "":
		body += why + ".\n\n"
	body += "Lost %s in cash and loot you were carrying." % U.money(lost)
	if fee > 0.0:
		body += " %s fee: %s from your bank." % ["Hospital" if kind == "WASTED" else "Bail", U.money(fee)]
	body += "\n\nMoney in the bank and loot stashed in your trunk is safe. Deposit at ATMs early."
	Game.money.cash = 0.0
	Game.bag.clear()
	Game.partner_bag.clear()
	Game.money.bank -= fee
	Sfx.play("bad")
	get_tree().create_timer(0.9).timeout.connect(func(): hud.show_death(kind, body))

func respawn() -> void:
	var P := player_ctl
	hud.hide_death()
	Game.police.reset()
	P.dead = false
	P.hp = 100.0
	P.weapon = false
	P.action = null
	P.pose = "stand"
	if P.masked:
		P.toggle_mask()
	P.set_hidden(false)
	P.in_car = null
	P.teleport(SPAWN)
	var pt = Game.partner
	pt.in_car = null
	pt.set_hidden(false)
	pt.teleport(SPAWN + Vector3(-1.8, 0, 1.0))
	for s in Game.sites:
		s.player_inside = false
		s.left_reported = true
	P.crumbs.clear()
	camera.yaw = -PI / 2
	camera.snap()
	var car: Vehicle = Game.player_car
	if is_instance_valid(car) and U.d2(car.global_position, SPAWN) > 30.0 and car.trunk.is_empty():
		car.place(Vector3(69, 0, -4.95), -PI / 2)

# ---------- loop ----------
func _physics_process(dt: float) -> void:
	if not Game.running or Game.paused:
		Sfx.set_loop("alarm", 0.0)
		Sfx.set_loop("siren", 0.0)
		Sfx.set_loop("engine", 0.0)
		Sfx.set_loop("screech", 0.0)
		return
	Game.t += dt
	player_ctl.update_player(dt)
	Game.partner.mask_mesh.visible = player_ctl.masked
	traffic.update(dt)
	traffic.contacts()
	var pp: Vector3 = player_ctl.in_car.global_position if player_ctl.in_car else player_ctl.global_position
	var b = null
	for bd in Game.buildings:
		if bd.rect.has_point(Vector2(pp.x, pp.z)):
			b = bd
	Game.cur_building = b
	Game.in_garage = b != null and b.garage
	player_ctl.compute_aim()
	npc_ai.update(dt)
	Game.police.update(dt)
	Game.robbery.update(dt)

func _process(dt: float) -> void:
	camera.update_cam(dt)
	if Game.running:
		hud.update_state(dt)
	cull_t -= dt
	if cull_t <= 0.0:
		cull_t = 0.25
		var cp := camera.global_position
		for c in Game.chars:
			if not c.hidden:
				c.visible = absf(c.global_position.x - cp.x) + absf(c.global_position.z - cp.z) < 130.0
		for s in Game.sites:
			s.group.visible = absf(s.door.x - cp.x) + absf(s.door.z - cp.z) < 110.0
