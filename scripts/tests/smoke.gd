extends Node
## Scenario smoke test. Run headless:
##   godot --headless --path . --fixed-fps 60 res://scenes/tests/smoke.tscn
## Optional screenshots (needs a display): add `-- shots`.

var main: Node
var frame := 0
var step := 0
var log_lines: Array = []
var fails := 0
var shots := false
var t0 := 0

func _ready() -> void:
	shots = "shots" in OS.get_cmdline_user_args()
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	t0 = Time.get_ticks_msec()

func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		fails += 1

func shot(name: String) -> void:
	if not shots:
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("/tmp/hs_%s.png" % name)
	print("shot /tmp/hs_%s.png" % name)

func wait(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame

func _start() -> void:
	main.hud._start_game()

func _process(_dt: float) -> void:
	if step == 0:
		step = 1
		_run()

func _run() -> void:
	await wait(5)
	print("build ms: ", Time.get_ticks_msec() - t0, "  chars=", Game.chars.size(), " cars=", Game.cars.size(), " sites=", Game.sites.size(), " interactables=", Game.interactables.size())
	_start()
	var P: Player = Game.player
	var gen: KeysGen = main.world_gen
	await wait(30)
	await shot("01_spawn")
	# --- Key Lento map + streaming ---
	var span := 0.0
	for ck in main.streamer.cells:
		span = maxf(span, absf(ck.x * 50.0 + 25.0))
	check(span * 2.0 > 2300.0, "island spans ~2.5 km (%.0f m)" % (span * 2.0))
	check(gen.lots.size() > 150, "island has lots (%d) and landmarks (%d)" % [gen.lots.size(), gen.marks.size()])
	check(main.streamer.gen_stats.generated > 10, "chunks generated around spawn (%d in %.0f ms)" % [main.streamer.gen_stats.generated, main.streamer.gen_stats.gen_ms])
	check(main.streamer.generated(P.global_position), "spawn chunk generated")
	check(gen.walkable(P.global_position.x, P.global_position.z), "spawn is on the stilt-house dock")
	var shapes := 0
	var convex := false
	for ch in Game.player_car.get_children():
		if ch is CollisionShape3D:
			shapes += 1
			convex = ch.shape is ConvexPolygonShape3D
	check(shapes == 1 and convex, "car = one rigid body with one convex collider (%d shapes)" % shapes)
	# --- walking ---
	var p0 := P.global_position
	P.inp.jy = 1.0
	await wait(90)
	P.inp.jy = 0.0
	check(P.global_position.distance_to(p0) > 4.0, "player walks (%.1f m)" % P.global_position.distance_to(p0))
	# --- personal car ---
	P.teleport(gen.spawn_car + Vector3(-2.2, 0, 0))
	await wait(5)
	var acts = P.current_actions()
	check(acts != null, "actions near personal car")
	var car: Vehicle = Game.player_car
	P.enter_car(car)
	check(P.in_car == car, "entered car")
	P.inp.gas = true
	await wait(180)
	check(car.speed() > 8.0, "car accelerates (%.1f m/s)" % car.speed())
	await shot("02_driving")
	P.inp.gas = false
	P.inp.jx = 0.6
	P.inp.gas = true
	await wait(60)
	P.inp.jx = 0.0
	P.inp.gas = false
	P.inp.brake = true
	var v0 := car.speed()
	var vmin := absf(v0)
	for i in 150:
		await get_tree().physics_frame
		vmin = minf(vmin, absf(car.speed()))
	P.inp.brake = false
	check(vmin < 1.5, "car brakes to a stop (%.1f -> %.1f m/s), then reverses (%.1f)" % [v0, vmin, car.speed()])
	var up := car.global_basis.y.y
	check(up > 0.8, "car upright (up.y=%.2f)" % up)
	P.exit_car()
	check(P.in_car == null and not P.hidden, "exited car")
	await wait(10)
	# --- highway run on Route 1 through freshly generated chunks ---
	var hx := -700.0
	car.place(Vector3(hx, 0, gen.rc(hx) + 3.0), PI / 2)
	P.teleport(car.global_position)
	main.streamer.prime(car.global_position)
	P.enter_car(car)
	P.inp.gas = true
	var max_off := 0.0
	var min_y := 9.0
	for i in 60 * 7:
		await get_tree().physics_frame
		var cp := car.global_position
		P.inp.jx = clampf((gen.rc(cp.x + 12.0) + 3.0 - cp.z) * 0.08 - car.linear_velocity.z * 0.05, -1.0, 1.0)
		max_off = maxf(max_off, absf(cp.z - gen.rc(cp.x)))
		min_y = minf(min_y, cp.y)
	P.inp.gas = false
	P.inp.jx = 0.0
	check(car.global_position.x > hx + 120.0, "highway run: covered %.0f m at up to %.1f m/s" % [car.global_position.x - hx, car.speed()])
	check(min_y > -0.5 and car.global_basis.y.y > 0.8, "stayed on the road surface (min y %.2f, off-centre %.1f m)" % [min_y, max_off])
	await shot("02b_route1")
	P.inp.brake = true
	await wait(120)
	P.inp.brake = false
	P.exit_car()
	check(gen.walkable(P.global_position.x, P.global_position.z), "exited car onto land")
	# --- police flow: report (hollow) -> pursuit -> lost -> search -> escape -> hot zone ---
	Game.police.reset()
	P.teleport(Vector3(-600, 0, gen.rc(-600) + 9.0))
	main.streamer.prime(P.global_position)
	Game.police.report(2, P.global_position + Vector3(60, 0, 0), "test call", {"outfit": Game.outfit})
	check(Game.wanted.state == "response" and Game.wanted.stars == 2, "report -> RESPONSE, hollow stars (%s %d)" % [Game.wanted.state, Game.wanted.stars])
	await wait(90)
	check(Game.police.units.size() > 0 and Game.wanted.eta != 0.0, "units dispatched, ETA %.0f s" % Game.wanted.eta)
	var nearest := 1e9
	for uu in Game.police.units:
		nearest = minf(nearest, U.d2(uu.car.global_position, P.global_position))
	check(nearest > 60.0, "police didn't spawn on top of you (nearest %.0f m)" % nearest)
	Game.police.raise_stars(3, P.global_position, "test crime")
	check(Game.wanted.state == "pursuit", "seen committing a crime -> PURSUIT")
	Game.police.reset()
	Game.police.raise_stars(1, P.global_position, "test")
	Game.wanted.seen_ago = 3.0
	P.teleport(Vector3(-900, 0, gen.rc(-900) + 9.0))
	await wait(30)
	check(Game.wanted.state in ["lost", "search"], "out of sight -> LOST (%s)" % Game.wanted.state)
	Game.wanted.seen_ago = 12.0
	await wait(30)
	check(Game.wanted.state == "search" and Game.wanted.search_r > 30.0, "-> SEARCH area (r %.0f)" % Game.wanted.search_r)
	Game.wanted.clear = 99.0
	await wait(10)
	check(Game.wanted.stars == 0 and not Game.hot_zones.is_empty(), "escaped -> hot zone (%d zones)" % Game.hot_zones.size())
	Game.hot_zones.clear()
	Game.police.reset()
	# --- witnesses: gunfire -> someone calls 911 ---
	var wpos := P.global_position + Vector3(9, 0, 0)
	var wit: Character = main.spawn_pedestrian(wpos)
	wit.mem.phone = true
	wit.mem.nervous = 0.3
	wit.mem.brave = 0.6
	wit.mem.filmer = false
	await wait(5)
	P.toggle_weapon()
	main.camera.yaw = U.ang_to(P.global_position, wpos) + PI
	await wait(3)
	P.fire()
	await wait(5)
	check(wit.mem.has("crime"), "pedestrian witnessed the gunfire (state %s)" % wit.state)
	var called := false
	for i in 60 * 20:
		await get_tree().physics_frame
		if Game.wanted.stars > 0:
			called = true
			break
	check(called, "witness got through to 911 (state %s, wanted %s %d)" % [wit.state, Game.wanted.state, Game.wanted.stars])
	P.toggle_weapon()
	Game.police.reset()
	main.remove_char(wit)
	# --- escalation: 4 stars on Route 1 -> roadblock with spikes, SWAT, helicopter ---
	var rx := -900.0
	car.place(Vector3(rx, 0, gen.rc(rx) + 3.0), PI / 2)
	car.tires_burst = 0
	P.teleport(car.global_position)
	main.streamer.prime(car.global_position)
	P.enter_car(car)
	P.inp.gas = true
	await wait(150)
	Game.police.raise_stars(4, car.global_position, "test pursuit")
	var saw_rb := false
	var saw_strip := false
	var saw_heli := false
	var saw_swat := false
	for i in 60 * 6:
		await get_tree().physics_frame
		Game.wanted.seen_ago = 0.0
		var cp := car.global_position
		var la := Vector3(cp.x + 20.0, 0, gen.rc(cp.x + 20.0) + 3.0)
		P.inp.jx = -clampf(U.ang_diff(car.yaw(), U.ang_to(cp, la)) * 2.4, -1.0, 1.0)
		if not Game.police.roadblocks.is_empty():
			saw_rb = true
			saw_strip = saw_strip or Game.police.roadblocks[0].strip != null
		saw_heli = saw_heli or Game.police.heli.node != null
		for uu in Game.police.units:
			saw_swat = saw_swat or uu.kind == "swat"
	P.inp.gas = false
	P.inp.jx = 0.0
	check(saw_rb and saw_strip, "4-star pursuit on Route 1 -> roadblock ahead with spike strip")
	check(saw_heli, "4 stars -> police helicopter")
	check(saw_swat, "4 stars -> SWAT unit dispatched")
	P.exit_car()
	Game.police.reset()
	# --- K9 on foot at 3 stars, then surrender ---
	P.teleport(Vector3(-950, 0, gen.rc(-950) + 10.0))
	main.streamer.prime(P.global_position)
	await wait(5)
	Game.police.raise_stars(3, P.global_position, "test k9")
	var saw_dog := false
	for i in 60 * 4:
		await get_tree().physics_frame
		Game.wanted.seen_ago = 0.0
		saw_dog = saw_dog or not Game.police.dogs.is_empty()
	check(saw_dog, "3 stars on foot -> K9 unit")
	Game.police.reset()
	Game.police.raise_stars(1, P.global_position, "test surrender")
	var cop_u: Dictionary = Game.police.spawn_unit("patrol", Vector3(P.global_position.x + 14.0, 0, P.global_position.z))
	for cp in cop_u.cops:
		cp.in_car = null
		cp.set_hidden(false)
		cp.teleport(P.global_position + Vector3(6, 0, 0))
	cop_u.state = "onfoot"
	await wait(5)
	check(Game.police.can_surrender(), "can surrender with a cop close by")
	P.give_up()
	var busted := false
	for i in 60 * 10:
		await get_tree().physics_frame
		if P.dead:
			busted = true
			break
	check(busted, "surrendered -> cops cuff you -> BUSTED (bust %.1f)" % P.bust_t)
	await wait(70)
	main.respawn()
	await wait(5)
	# --- store robbery ---
	var store: Dictionary = Game.sites[0]
	var clerk = store.get("clerk")
	check(clerk != null and is_instance_valid(clerk), "store clerk spawned")
	P.teleport(Vector3(21, 0, -10.5))
	main.camera.yaw = U.ang_to(P.global_position, clerk.global_position)
	main.camera.pitch = 0.05
	main.camera.snap()
	P.toggle_mask()
	P.toggle_weapon()
	await wait(30)
	await shot("03_store_aim")
	var aimed := false
	for i in 400:
		await get_tree().physics_frame
		main.camera.yaw = U.ang_to(P.global_position, clerk.global_position)
		if P.aim_target == clerk:
			aimed = true
	check(aimed, "aim locks onto clerk")
	check(store.register <= 0.0, "clerk emptied register (register=%s, cash=%s)" % [store.register, Game.money.cash])
	check(store.robbery_active, "robbery active")
	# crowd control: shout, then zip-tie a hostage
	var cust = null
	for n in Game.sites[1].npcs + store.npcs:
		if is_instance_valid(n) and n.role == "civilian" and not n.dead:
			cust = n
	if cust != null:
		P.teleport(cust.global_position + Vector3(1.0, 0, 0))
		await wait(3)
		Game.main.npc_ai.shout_cd = 0.0
		Game.main.npc_ai.shout()
		await wait(10)
		check(cust.state == "down", "SHOUT puts the customer on the floor (%s, fear %.2f)" % [cust.state, cust.fear])
		var n0: int = Game.tools.zipties
		Game.main.npc_ai.zip_tie(cust)
		await wait(5)
		check(cust.mem.get("tied", false) and Game.tools.zipties == n0 - 1, "zip-tied a hostage (%d ties left)" % Game.tools.zipties)
		P.teleport(Vector3(21, 0, -10.5))
	# focus + labels
	Game.focus = true
	await wait(10)
	await shot("04_focus")
	Game.focus = false
	# --- safe via code note ---
	P.toggle_weapon()
	P.teleport(Vector3(18.5, 0, -19.2))
	await wait(5)
	acts = P.current_actions()
	check(acts != null and acts.actions.size() > 0, "code note actions: %s" % (acts.actions[0].label if acts else "none"))
	if acts:
		P.start_action(acts.actions[0], acts.target)
		await wait(100)
	check(Game.known_codes.has("store"), "learned store safe code")
	P.teleport(Vector3(13, 0, -19.4))
	await wait(5)
	acts = P.current_actions()
	if acts:
		print("   safe actions: ", acts.actions.map(func(a): return a.label))
		P.start_action(acts.actions[0], acts.target)
		await wait(140)
		acts = P.current_actions()
		if acts:
			P.start_action(acts.actions[0], acts.target)
			await wait(140)
	check(store.safe_open, "safe opened")
	print("   cash now ", Game.money.cash)
	# --- alarm -> police ---
	Game.robbery.trigger_alarm(store, "test")
	await wait(30)
	check(Game.wanted.stars >= 2, "alarm raises wanted level (%d, %s)" % [Game.wanted.stars, Game.wanted.state])
	await wait(600)
	check(Game.police.units.size() > 0, "police dispatched (%d units)" % Game.police.units.size())
	var u = Game.police.units[0] if Game.police.units.size() > 0 else null
	if u:
		print("   unit state ", u.state, " dist ", U.d2(u.car.global_position, P.global_position))
	await shot("05_police")
	# --- jewelry: smash a case ---
	Game.police.reset()
	P.teleport(Vector3(-31.8, 0, -10.4))
	await wait(5)
	acts = P.current_actions()
	if acts:
		print("   jewel actions: ", acts.actions.map(func(a): return a.label))
		P.start_action(acts.actions[0], acts.target)
		await wait(80)
	check(Robbery.bag_value(Game.bag) > 0.0, "jewelry in bag (%s)" % U.money(Robbery.bag_value(Game.bag)))
	# --- armored truck -> vault opens (unmasked, unarmed customer so the guards stay calm) ---
	if P.dead:
		main.respawn()
	Game.police.reset()
	for s in Game.sites:
		s.alarm_triggered = false
		s.robbery_active = false
		s.left_reported = true
		s.player_inside = false
	Game.heat.face = 0.0
	Game.heat.outfit = -1
	Game.heat.weapon = 0.0
	if P.masked:
		P.toggle_mask()
	P.hp = 100.0
	P.teleport(Vector3(25, 0, 12))
	# the test runs long enough for a delivery cycle to have started already: restart it
	var TS: Dictionary = Game.robbery.truck
	if TS.car != null and is_instance_valid(TS.car):
		main.remove_car(TS.car)
	if TS.guard != null and is_instance_valid(TS.guard):
		main.remove_char(TS.guard)
	TS.car = null
	TS.guard = null
	TS.panic = 0.0
	TS.state = "wait"
	Game.robbery.truck.t = 0.5
	var opened := false
	var truck_seen := false
	for i in 60 * 70:
		await get_tree().physics_frame
		if Game.robbery.truck.car != null:
			truck_seen = true
		if Game.robbery.vault.state in ["opening", "open"]:
			opened = true
			break
	check(truck_seen, "armored truck spawned (state %s)" % Game.robbery.truck.state)
	var tg = Game.robbery.truck.guard
	var gs: String = "none" if tg == null or not is_instance_valid(tg) else "%s ri=%s pos=%s ko=%s dead=%s" % [tg.state, tg.mem.get("ri"), tg.global_position, tg.ko, tg.dead]
	check(opened, "vault opened for the delivery (vault %s, truck %s, guard %s, P dead=%s)" % [Game.robbery.vault.state, Game.robbery.truck.state, gs, P.dead])
	# --- bank interior shot ---
	Game.police.reset()
	P.teleport(Vector3(25, 0, 12))
	main.camera.yaw = 0.0
	main.camera.snap()
	await wait(40)
	await shot("06_bank")
	# --- street views ---
	P.teleport(Vector3(0, 0, -7.5))
	main.camera.yaw = PI * 0.25
	main.camera.pitch = 0.18
	main.camera.snap()
	await wait(40)
	await shot("07_street")
	for v in [[Vector3(500, 0, gen.rc(500) + 9.0), PI / 2, "08_keys_strip"], [Vector3(-470, 0, gen.rc(-470) - 30.0), PI, "09_marina"],
			[Vector3(715, 0, gen.rc(715) + 8.0), -0.3, "10_whale"], [Vector3(-330, 0, gen.rc(-330) - 120.0), PI, "11_stilt_house"]]:
		P.teleport(v[0])
		main.streamer.prime(v[0])
		main.camera.yaw = v[1]
		main.camera.pitch = 0.12
		main.camera.snap()
		await wait(40)
		await shot(v[2])
	P.teleport(Vector3(0, 0, -7.5))
	main.streamer.prime(P.global_position)
	# --- run the world for a while: traffic + peds shouldn't explode ---
	await wait(900)
	var flipped := 0
	var lost := 0
	for c in Game.cars:
		if c.global_basis.y.y < 0.5:
			flipped += 1
		if c.global_position.y < -5.0 or absf(c.global_position.x) > 1400.0:
			lost += 1
	check(lost == 0, "no cars fell out of the world (%d)" % lost)
	check(flipped <= 1, "traffic stays upright (%d flipped)" % flipped)
	var moving := 0
	for c in Game.cars:
		if c.ai.get("kind", "") in ["traffic", "route"] and (c.linear_velocity.length() > 2.0 or c.rail):
			moving += 1
	check(moving >= 3, "traffic is moving (%d cars)" % moving)
	print("\nRESULT: %d failure(s)  (%.1f s)" % [fails, (Time.get_ticks_msec() - t0) / 1000.0])
	get_tree().quit(1 if fails else 0)
