extends Node
## Screenshot tour for visual checks (needs a display, e.g. xvfb):
##   godot --path . --rendering-method mobile res://scenes/tests/shots.tscn -- [quality]
## Writes /tmp/hs_view_*.png

var main: Node
## [name, position, camera yaw, pitch, aim+focus] - built at runtime from the Key Lento layout
func views(gen: KeysGen) -> Array:
	var sh: Vector2 = gen.stilt_house.get_center()
	return [
		["spawn", gen.spawn, PI, 0.2, false],
		["stilt_house", Vector3(sh.x + 6.0, 0, sh.y + 40.0), PI + 0.15, 0.12, false],
		["street", Vector3(0, 0, -7.5), PI * 0.25, 0.16, false],
		["store", Vector3(20, 0, -10.5), PI, 0.2, true],
		["bank", Vector3(25, 0, 12.5), 0.0, 0.15, false],
		["strip", Vector3(470, 0, gen.rc(470) + 8.5), PI / 2 + 0.2, 0.14, false],
		["marina", Vector3(-455, 0, gen.rc(-500) - gen.north_w(-500) + 70.0), PI + 0.5, 0.16, false],
		["whale", Vector3(738, 0, gen.rc(738) + 2.0), -2.4, 0.08, false],
		["motel", Vector3(580, 0, gen.rc(580) - 2.0), 0.0, 0.14, false],
		["canals", Vector3(-800, 0, gen.rc(-800) - 30.0), PI, 0.3, false],
		["bridge", Vector3(-1230, 0, gen.rc(-1230) + 2.0), -PI / 2, 0.1, false],
		["drive", Vector3(-640, 0, gen.rc(-640) + 3.0), PI / 2, 0.2, false],
	]

func _ready() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	var args := OS.get_cmdline_user_args()
	if not args.is_empty() and Settings.PRESETS.has(args[0]):
		Settings.quality = args[0]
	_run.call_deferred()

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _run() -> void:
	await _frames(3)
	Settings.auto_res = false
	Settings.apply()
	main.hud._start_game()
	var P: Player = Game.player
	for v in views(main.world_gen):
		main.streamer.prime(v[1])
		if v[0] == "drive":
			var car: Vehicle = Game.player_car
			car.place(v[1], v[2])
			P.enter_car(car)
			P.inp.gas = true
		else:
			P.teleport(v[1])
		main.camera.yaw = v[2]
		main.camera.pitch = v[3]
		main.camera.snap()
		if v[4]:
			P.toggle_weapon()
			Game.focus = true
		await _frames(45 if v[0] == "drive" else 20)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("/tmp/hs_view_%s.png" % v[0])
		print("saved ", v[0], "  fps=", Engine.get_frames_per_second())
		if v[4]:
			P.toggle_weapon()
			Game.focus = false
	get_tree().quit()
