extends Node3D
## Game root: lays out Key Lento and the robbery sites, spawns the cast, runs the
## fixed-rate simulation (60 Hz physics ticks, interpolated rendering) and routes game
## events (damage, run-overs, crashes, WASTED/BUSTED).

var SPAWN := Vector3.ZERO
const PED_COLORS := [Color("b0b8c0"), Color("9db4c8"), Color("c8b49d"), Color("a8c89d"), Color("c89dbb"), Color("e8a0a0"),
	Color("f2d28a"), Color("8fd1c6"), Color("ffffff"), Color("6e7f99")]
## every material KeysGen uses: created up front on the main thread, because chunk
## generation runs on worker threads and must only read the material cache
const GEN_MATS := ["grass", "sand", "concrete", "wood_planks", "asphalt", "line_yellow", "line_white", "sidewalk", "paint",
	"shopfront", "facade_stucco", "roof_gravel", "awning", "signs", "metal_brushed", "trunk", "leaf", "lamp_glow", "paint_gloss",
	"light_panel"]

@onready var camera: FollowCamera = $Camera
@onready var sun: DirectionalLight3D = $Sun
var world: Node3D
var world_gen: KeysGen
var builder: MeshBuilder
var sea: MeshInstance3D
var nav: NavGrid
var streamer: WorldStreamer
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
	world_gen = KeysGen.new()
	world_gen.layout()
	SPAWN = world_gen.spawn
	for mn in GEN_MATS:
		Mats.m(mn)
	Mats.uber()
	builder = MeshBuilder.new(world)
	site_builder = SiteBuilder.new(builder)
	site_builder.build()
	world_gen.fill_far(builder)
	streamer = WorldStreamer.new()
	streamer.name = "Streamer"
	world.add_child(streamer)
	streamer.setup(builder, world_gen)
	nav = NavGrid.new(builder, world_gen)
	streamer.chunk_ready.connect(nav.on_chunk)
	streamer.prime(SPAWN)
	nav.follow(SPAWN)
	_add_ocean()
	Roads.build(world_gen)
	# --- cast ---
	player_ctl = Player.new().setup("player", SPAWN, {"hp": 100.0, "yaw": PI}) as Player
	player_ctl.name = "Player"
	world.add_child(player_ctl)
	Game.player = player_ctl
	Game.chars.append(player_ctl)
	var partner := spawn_char("partner", SPAWN + Vector3(-1.8, 0, 0.6), {"hp": 999.0, "yaw": PI})
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
	Game.player_car = spawn_car("pickup", world_gen.spawn_car, world_gen.spawn_car_yaw, {"color_idx": 3, "personal": true, "tracker": false})
	traffic.spawn()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in 10:
		var p: Vector3 = world_gen.ped_spot(SPAWN, 12.0, 90.0, rng)
		if p != Vector3.INF:
			spawn_pedestrian(p)
	site_builder.spawn_parked_cars()
	site_builder.reset_all()
	camera.yaw = PI
	# --- UI + quality ---
	hud = Hud.new()
	add_child(hud)
	Settings.apply()
	streamer.prime(SPAWN)
	Game.paused = true

## The sea: one wave-animated plane that follows the camera (snapped to its quad size,
## so the world-space waves never swim) plus a sea floor 3 m down for sunk cars.
## The water shader reads a land mask so it knows where shallows, foam and calm are.
func _add_ocean() -> void:
	sea = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(1600, 1600)
	pm.subdivide_width = 159
	pm.subdivide_depth = 159
	sea.mesh = pm
	var wm: ShaderMaterial = Mats.m("water")
	var img := Image.create(world_gen.nx, world_gen.nz, false, Image.FORMAT_RGB8)
	for j in world_gen.nz:
		for i in world_gen.nx:
			var land := world_gen.mask[j * world_gen.nx + i] != KeysGen.WATER
			img.set_pixel(i, j, Color(1, 1, 1) if land else Color(0, 0, 0))
	var soft := img.duplicate() as Image
	soft.resize(world_gen.nx / 6, world_gen.nz / 6, Image.INTERPOLATE_BILINEAR)
	soft.resize(world_gen.nx, world_gen.nz, Image.INTERPOLATE_BILINEAR)
	for j in world_gen.nz:
		for i in world_gen.nx:
			img.set_pixel(i, j, Color(img.get_pixel(i, j).r, clampf(soft.get_pixel(i, j).r * 2.2, 0.0, 1.0), 0))
	wm.set_shader_parameter("land_tex", ImageTexture.create_from_image(img))
	wm.set_shader_parameter("land_origin", Vector2(KeysGen.X0, KeysGen.Z0))
	wm.set_shader_parameter("land_size", Vector2(KeysGen.X1 - KeysGen.X0, KeysGen.Z1 - KeysGen.Z0))
	sea.material_override = wm
	sea.position = Vector3(world_gen.spawn.x, KeysGen.SEA_Y, world_gen.spawn.z)
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(sea)
	var gb := StaticBody3D.new()
	gb.name = "Ground"
	gb.collision_layer = Game.L_GROUND
	gb.collision_mask = 0
	gb.add_child(world_gen.ground_shape())
	var gs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(KeysGen.X1 - KeysGen.X0 + 400.0, 1, KeysGen.Z1 - KeysGen.Z0 + 400.0)
	gs.shape = box
	gs.position = Vector3(0, -3.5, 0)
	gb.add_child(gs)
	world.add_child(gb)

func spawn_pedestrian(p: Vector3) -> Character:
	var c := spawn_char("pedestrian", p, {"color": PED_COLORS[randi() % PED_COLORS.size()], "yaw": randf() * TAU})
	c.state = "walk"
	npc_ai.give_traits(c)
	return c

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
	var ck := MeshBuilder.chunk_of((minv + maxv) * 0.5)
	if not builder.cols_by_chunk.has(ck):
		builder.cols_by_chunk[ck] = []
	builder.cols_by_chunk[ck].append(c)
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
			Game.record.cop_kills += 1
			Game.police.raise_stars(clampi(Game.wanted.stars + 1, 3, Game.MAX_STARS), pp, "Officer down")
		elif c.role != "guard" and c.role != "truckguard":
			Game.record.civ_kills += 1
			if c.site != null:
				Game.robbery.crime(c.site, "murder")
			npc_ai.crime_event(c.global_position, "Murder", 3, 30.0)
			for k in Game.chars:
				if k.role == "cop" and not k.dead and U.d2(k.in_car.global_position if k.in_car else k.global_position, pp) < 40.0:
					Game.police.raise_stars(3, pp, "Murder witnessed by police")
					break
	if c.mem.get("call_t", 0.0) > 0.0:
		c.mem.call_t = 0.0

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
	pt.teleport(SPAWN + Vector3(-1.8, 0, 0.6))
	for s in Game.sites:
		s.player_inside = false
		s.left_reported = true
	P.crumbs.clear()
	camera.yaw = PI
	camera.snap()
	streamer.prime(SPAWN)
	nav.follow(SPAWN)
	var car: Vehicle = Game.player_car
	if is_instance_valid(car) and U.d2(car.global_position, SPAWN) > 30.0 and car.trunk.is_empty():
		car.place(world_gen.spawn_car, world_gen.spawn_car_yaw)

# ---------- loop ----------
func _physics_process(dt: float) -> void:
	if not Game.running or Game.paused:
		Sfx.set_loop("alarm", 0.0)
		Sfx.set_loop("siren", 0.0)
		Sfx.set_loop("engine", 0.0)
		Sfx.set_loop("screech", 0.0)
		return
	Game.t += dt
	nav.budget = 3
	if player_ctl.in_car:
		nav.follow(player_ctl.in_car.global_position, player_ctl.in_car.linear_velocity)
	else:
		nav.follow(player_ctl.global_position)
	var t0 := Time.get_ticks_usec()
	player_ctl.update_player(dt)
	Game.partner.mask_mesh.visible = player_ctl.masked
	t0 = _prof("player", t0)
	traffic.update(dt)
	t0 = _prof("traffic", t0)
	traffic.contacts()
	t0 = _prof("contacts", t0)
	var pp: Vector3 = player_ctl.in_car.global_position if player_ctl.in_car else player_ctl.global_position
	var b = null
	for bd in Game.buildings:
		if bd.rect.has_point(Vector2(pp.x, pp.z)):
			b = bd
	Game.cur_building = b
	Game.in_garage = b != null and b.garage
	player_ctl.compute_aim()
	t0 = _prof("aim", t0)
	npc_ai.update(dt)
	t0 = _prof("npc_ai", t0)
	Game.police.update(dt)
	t0 = _prof("police", t0)
	Game.robbery.update(dt)
	t0 = _prof("robbery", t0)

## Optional per-system timing (enabled by the profiling scene).
var prof := {}
var profiling := false
func _prof(key: String, t0: int) -> int:
	var t1 := Time.get_ticks_usec()
	if profiling:
		prof[key] = prof.get(key, 0) + (t1 - t0)
	return t1

func _process(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	camera.update_cam(dt)
	t0 = _prof("camera", t0)
	if Game.running:
		hud.update_state(dt)
	t0 = _prof("hud_state", t0)
	cull_t -= dt
	if cull_t <= 0.0:
		cull_t = 0.25
		_update_actor_lod()
	t0 = _prof("lod", t0)
	if sea:
		var cp := camera.global_position
		sea.global_position = Vector3(snappedf(cp.x, 20.0), KeysGen.SEA_Y, snappedf(cp.z, 20.0))

## Actor LOD, every 0.25 s: hide far people, drop their shadows / animation rate, and
## give far cars no wheels / shadows. Distances scale with the graphics preset.
var actor_lod := {"char_shadow": 25.0, "char_hide": 130.0, "car_shadow": 45.0, "car_detail": 110.0}
func _update_actor_lod() -> void:
	var cp := camera.global_position
	var sc: float = streamer.lod_scale
	for c in Game.chars:
		if c.hidden:
			continue
		var d: float = Vector2(c.global_position.x - cp.x, c.global_position.z - cp.z).length()
		c.visible = d < actor_lod.char_hide * sc
		var lvl := 0 if d < 30.0 * sc else (1 if d < 70.0 * sc else 2)
		if c == player_ctl or c == Game.partner:
			lvl = 0
		c.set_lod(lvl, d < actor_lod.char_shadow)
	for car in Game.cars:
		var d: float = Vector2(car.global_position.x - cp.x, car.global_position.z - cp.z).length()
		car.set_lod(d > actor_lod.car_detail * sc, d < actor_lod.car_shadow)
	for s in Game.sites:
		s.group.visible = absf(s.door.x - cp.x) + absf(s.door.z - cp.z) < 70.0 * sc
