extends Node
## Performance profile: build time, script time per system, physics/process time,
## and (when rendering) draw calls / objects / primitives for a few camera spots.
##   headless:  godot --headless --path . --fixed-fps 60 res://scenes/tests/profile.tscn
##   rendered:  godot --path . --rendering-method mobile res://scenes/tests/profile.tscn -- [quality]

var main: Node
var t_build := 0

func _ready() -> void:
	var t0 := Time.get_ticks_usec()
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	t_build = Time.get_ticks_usec() - t0
	var args := OS.get_cmdline_user_args()
	if not args.is_empty() and Settings.PRESETS.has(args[0]):
		Settings.quality = args[0]
	_run.call_deferred()

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _render_info(label: String) -> void:
	var vp := get_viewport()
	var dc := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var ob := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_OBJECTS_IN_FRAME)
	var pr := vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	var sdc := vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var spr := vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	print("RENDER %-8s draws=%5d objects=%5d prims=%8d | shadow draws=%5d prims=%8d | vram=%.0fMB" % [label, dc, ob, pr, sdc, spr,
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0])

func _run() -> void:
	await _frames(3)
	Settings.auto_res = false
	Settings.apply()
	main.hud._start_game()
	var P: Player = Game.player
	var nodes := 0
	var meshes := 0
	var stack: Array = [main]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		nodes += 1
		if n is MeshInstance3D:
			meshes += 1
		stack.append_array(n.get_children())
	var shapes := 0
	for c in main.builder.cols:
		shapes += 1
	print("BUILD %.0f ms  nodes=%d mesh_instances=%d colliders=%d chars=%d cars=%d" % [t_build / 1000.0, nodes, meshes, shapes, Game.chars.size(), Game.cars.size()])
	var gen: KeysGen = main.world_gen
	var spots := [["spawn", gen.spawn, PI], ["downtown", Vector3(0, 0, -7.5), PI * 0.25], ["bank", Vector3(25, 0, 12.5), 0.0],
		["route1", Vector3(-600, 0, gen.rc(-600) + 9.0), PI / 2], ["canals", Vector3(-800, 0, gen.rc(-800) - 30.0), PI]]
	for s in spots:
		P.teleport(s[1])
		main.streamer.prime(s[1])
		main.camera.yaw = s[2]
		main.camera.pitch = 0.18
		main.camera.snap()
		await _frames(12)
		_render_info(s[0])
	if "split" in OS.get_cmdline_user_args():
		P.teleport(spots[0][1])
		main.camera.yaw = spots[0][2]
		main.camera.snap()
		await _frames(8)
		_render_info("all")
		for c in Game.chars: c.get_node("Inner") if false else null
		var hidden_chars := []
		for c in Game.chars:
			if c.visible:
				hidden_chars.append(c)
				c.visible = false
		main.cull_t = 99.0
		await _frames(4)
		_render_info("no_chars")
		for car in Game.cars:
			car.visible = false
		await _frames(4)
		_render_info("no_cars")
		for c in hidden_chars:
			c.visible = true
		for car in Game.cars:
			car.visible = true
		main.cull_t = 0.0
	# CPU: simulate 20 s of gameplay with the player walking around downtown
	P.teleport(Vector3(0, 0, -7.5))
	var args := OS.get_cmdline_user_args()
	if "nocharproc" in args:
		for c in Game.chars: c.set_process(false)
	if "nocarphys" in args:
		for c in Game.cars: c.set_physics_process(false)
	if "noai" in args:
		main.npc_ai.set_meta("off", true)
	main.profiling = true
	main.prof.clear()
	var ticks := 0
	var t_phys := 0.0
	var t_proc := 0.0
	var worst := 0.0
	var gen_us := 0
	var start := Time.get_ticks_usec()
	for i in 1200:
		P.inp.jy = 1.0 if (i / 200) % 2 == 0 else 0.0
		P.inp.jx = 0.3 if i % 300 < 150 else -0.3
		await get_tree().physics_frame
		ticks += 1
		if i == 600:
			print("   monitors: process=%s physics=%s nav=%s fps=%s" % [Performance.get_monitor(Performance.TIME_PROCESS), Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS), Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS), Performance.get_monitor(Performance.TIME_FPS)])
		var pf := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		var pr := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		gen_us += main.streamer.stats.gen_us
		t_phys += pf
		t_proc += pr
		worst = maxf(worst, pf)
	var wall := (Time.get_ticks_usec() - start) / 1000.0
	print("CPU over %d ticks: wall %.1f ms/tick, physics %.2f ms avg (worst %.1f), process %.2f ms avg" % [ticks, wall / ticks, t_phys / ticks, worst, t_proc / ticks])
	print("   streamer gen step %.3f ms/frame" % (gen_us / 1000.0 / ticks))
	var keys: Array = main.prof.keys()
	keys.sort_custom(func(a, b): return main.prof[a] > main.prof[b])
	for k in keys:
		print("   %-10s %6.3f ms/tick" % [k, main.prof[k] / 1000.0 / ticks])
	print("   nav paths: ", Game.get_meta("nav_calls", 0))
	# CPU while driving fast down Route 1: chunks generate on worker threads ahead of you
	var car: Vehicle = Game.player_car
	car.place(Vector3(-1100, 0, gen.rc(-1100) + 3.0), PI / 2)
	P.inp.jx = 0.0
	P.inp.jy = 0.0
	P.teleport(car.global_position)
	main.streamer.prime(car.global_position)
	P.enter_car(car)
	P.inp.gas = true
	var g0: int = main.streamer.gen_stats.generated
	var worst_frame := 0.0
	var sum_frame := 0.0
	var n := 0
	var last := Time.get_ticks_usec()
	for i in 1500:
		var cp := car.global_position
		var la := Vector3(cp.x + 20.0, 0, gen.rc(cp.x + 20.0) + 3.0)
		P.inp.jx = -clampf(U.ang_diff(car.yaw(), U.ang_to(cp, la)) * 2.4, -1.0, 1.0)
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var ft := (now - last) / 1000.0
		last = now
		if i > 5:
			worst_frame = maxf(worst_frame, ft)
			sum_frame += ft
			n += 1
	print("   nav window raster %.1f ms" % main.nav.last_raster_ms)
	print("DRIVE %.0f m in %d frames: avg frame %.2f ms, worst %.1f ms, chunks generated %d, freed %d, loaded layers %d" % [car.global_position.x + 1100.0, n,
		sum_frame / n, worst_frame, main.streamer.gen_stats.generated - g0, main.streamer.gen_stats.freed, main.streamer.stats.loaded])
	get_tree().quit()
