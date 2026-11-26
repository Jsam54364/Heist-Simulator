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
	await wait(30)
	await shot("01_spawn")
	# --- walking ---
	var p0 := P.global_position
	P.inp.jy = 1.0
	await wait(90)
	P.inp.jy = 0.0
	check(P.global_position.distance_to(p0) > 4.0, "player walks (%.1f m)" % P.global_position.distance_to(p0))
	# --- personal car ---
	P.teleport(Vector3(69, 0, -7.0))
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
	check(Game.wanted.stars >= 2, "alarm raises wanted level (%d)" % Game.wanted.stars)
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
	# --- armored truck -> vault opens ---
	Game.police.reset()
	P.teleport(Vector3(25, 0, 12))
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
	check(opened, "vault opened for the delivery (vault %s, truck %s)" % [Game.robbery.vault.state, Game.robbery.truck.state])
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
	P.teleport(Vector3(165, 0, 20))
	main.camera.yaw = PI / 2
	main.camera.snap()
	await wait(40)
	await shot("08_beach")
	# --- run the world for a while: traffic + peds shouldn't explode ---
	await wait(900)
	var flipped := 0
	var lost := 0
	for c in Game.cars:
		if c.global_basis.y.y < 0.5:
			flipped += 1
		if c.global_position.y < -5.0 or absf(c.global_position.x) > 400.0:
			lost += 1
	check(lost == 0, "no cars fell out of the world (%d)" % lost)
	check(flipped <= 1, "traffic stays upright (%d flipped)" % flipped)
	var moving := 0
	for c in Game.cars:
		if c.ai.get("kind", "") == "traffic" and c.linear_velocity.length() > 2.0:
			moving += 1
	check(moving >= 3, "traffic is moving (%d cars)" % moving)
	print("\nRESULT: %d failure(s)  (%.1f s)" % [fails, (Time.get_ticks_msec() - t0) / 1000.0])
	get_tree().quit(1 if fails else 0)
