extends Node
## Screenshot tour for visual checks (needs a display, e.g. xvfb):
##   godot --path . --rendering-method mobile res://scenes/tests/shots.tscn -- [quality]
## Writes /tmp/hs_view_*.png

var main: Node
const VIEWS := [
	["spawn", Vector3(74, 0, -7.6), -PI / 2, 0.25, false],
	["street", Vector3(0, 0, -7.5), PI * 0.25, 0.16, false],
	["store", Vector3(20, 0, -10.5), PI, 0.2, true],
	["bank", Vector3(25, 0, 12.5), 0.0, 0.15, false],
	["beach", Vector3(165, 0, 20), PI / 2, 0.2, false],
	["drive", Vector3(50, 0, -3), -PI / 2, 0.2, false],
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
	for v in VIEWS:
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
