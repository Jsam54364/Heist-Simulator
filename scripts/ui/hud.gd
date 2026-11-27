class_name Hud
extends CanvasLayer
## HUD state + screens: radar, start screen, pause/settings, WASTED/BUSTED, the
## fence's shop and the full-screen map. Gameplay overlay drawing lives in HudCanvas.

var canvas: HudCanvas
var minimap := {"rect": null, "mat": null, "scale_px": 1.5}
var map_tex: ImageTexture
var actions = null
var badges: Array = []
var timers: Array = []
var money_rows: Array = []
var target_text := ""
var pois: Array = []
var show_touch := true
var hud_t := 0.0
var screens := {}
var shop_list: VBoxContainer
var shop_money: Label
var death_title: Label
var death_body: Label
var start_btn: Button
var quality_btn: Button
var fps_btn: Button
var autores_btn: Button
var steer_btn: Button
var lfire_btn: Button
var fps_label: Label
const MAP_PX := KeysGen.MAP_PX
const MX0 := KeysGen.X0
const MZ0 := KeysGen.Z0
const MW := KeysGen.X1 - KeysGen.X0
const MH := KeysGen.Z1 - KeysGen.Z0
const TOOLS := [
	{"id": "snap", "name": "Snap Gun", "price": 2500, "desc": "Silently breaks locks on back doors, staff doors and vault lockboxes."},
	{"id": "suppressor", "name": "Suppressor", "price": 2000, "desc": "Shoot cameras without alerting the whole block."},
	{"id": "c4", "name": "C4 charge", "price": 1500, "desc": "Blows reinforced doors. Always loud, always trips the alarm.", "stack": true},
	{"id": "jammer", "name": "Dye-Pack Jammer", "price": 6000, "desc": "Stops dye packs in bank money from exploding when you leave."},
	{"id": "armor", "name": "Body Armor", "price": 800, "desc": "Absorbs gunfire. Refills to full.", "stack": true},
	{"id": "zipties", "name": "Zip-ties (x4)", "price": 120, "desc": "Restrain hostages so they can't run, call 911 or hit alarms.", "stack": true},
]

func _ready() -> void:
	layer = 5
	show_touch = DisplayServer.is_touchscreen_available() or OS.has_feature("mobile")
	_build_map_texture()
	_build_minimap()
	canvas = HudCanvas.new()
	canvas.hud = self
	add_child(canvas)
	canvas.pause_pressed.connect(func(): open_screen("pause"))
	canvas.map_pressed.connect(func(): open_screen("map"))
	fps_label = Label.new()
	fps_label.anchor_top = 1.0
	fps_label.anchor_bottom = 1.0
	fps_label.offset_left = 8
	fps_label.offset_top = -22
	fps_label.offset_bottom = -4
	fps_label.add_theme_font_size_override("font_size", 13)
	fps_label.add_theme_constant_override("outline_size", 4)
	fps_label.add_theme_color_override("font_outline_color", Color.BLACK)
	fps_label.visible = Settings.show_fps
	add_child(fps_label)
	_build_screens()
	var gen: KeysGen = Game.main.world_gen
	var sh: Vector2 = gen.stilt_house.get_center()
	pois = [
		{"x": 20.0, "z": -15.0, "t": "$", "c": Color("7cf27c")}, {"x": -25.0, "z": -16.0, "t": "$$", "c": Color("7fe3ff")},
		{"x": 25.0, "z": 20.0, "t": "$$$", "c": Color("ffd23f")}, {"x": -72.0, "z": -15.0, "t": "F", "c": Color("ff9ad5")},
		{"x": sh.x, "z": sh.y, "t": "H", "c": Color.WHITE}, {"x": 70.0, "z": 18.0, "t": "S", "c": Color("ff6fb5")},
		{"x": -27.0, "z": 25.0, "t": "P", "c": Color("7fb2ff")}, {"x": Game.police.station.x, "z": Game.police.station.z + 18.0, "t": "*", "c": Color("6fa0ff")},
	]
	for l in gen.lots:
		if l.get("brian", false):
			pois.append({"x": l.rect.get_center().x, "z": l.rect.get_center().y, "t": "F", "c": Color("7fd4ff")})

# ---------- map texture ----------
func _build_map_texture() -> void:
	var img: Image = Game.main.world_gen.map_image.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	var rect := func(x1: float, z1: float, w: float, d: float, c: Color):
		var r := Rect2i(int((x1 - MX0) * MAP_PX), int((z1 - MZ0) * MAP_PX), maxi(1, int(w * MAP_PX)), maxi(1, int(d * MAP_PX)))
		img.fill_rect(r.intersection(Rect2i(0, 0, img.get_width(), img.get_height())), c)
	var site_col := {"store": Color("2f8f5b"), "jewel": Color("5a4a9a"), "bank": Color("9a8a3a"), "fence": Color("8a3a6a"),
		"safehouse": Color("3a8a7a"), "garage": Color("4a5a7a"), "spray": Color("9a4a7a")}
	for b in Game.buildings:
		rect.call(b.rect.position.x, b.rect.position.y, b.rect.size.x, b.rect.size.y, site_col.get(b.name, Color("555c66")))
	map_tex = ImageTexture.create_from_image(img)

func _build_minimap() -> void:
	var cr := ColorRect.new()
	cr.position = HudCanvas.MINI_POS
	cr.size = Vector2(HudCanvas.MINI_SIZE, HudCanvas.MINI_SIZE)
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sm := ShaderMaterial.new()
	sm.shader = load("res://assets/shaders/minimap.gdshader")
	sm.set_shader_parameter("map_tex", map_tex)
	sm.set_shader_parameter("world_size", Vector2(MW, MH))
	sm.set_shader_parameter("water", Color("1c4054"))
	cr.material = sm
	add_child(cr)
	minimap.rect = cr
	minimap.mat = sm

func _update_minimap() -> void:
	var P = Game.player
	var pp: Vector3 = P.in_car.global_position if P.in_car else P.global_position
	var scale := 1.0 if P.in_car else 1.5
	minimap.scale_px = scale
	var span_m := HudCanvas.MINI_SIZE / scale
	var sm: ShaderMaterial = minimap.mat
	sm.set_shader_parameter("center_uv", Vector2((pp.x - MX0) / MW, (pp.z - MZ0) / MH))
	sm.set_shader_parameter("span_uv", Vector2(span_m / MW, span_m / MH))
	sm.set_shader_parameter("rot", Game.main.camera.yaw - PI)
	var w := Game.wanted
	if w.stars > 0 and (w.searching or w.state == "response"):
		sm.set_shader_parameter("search_uv", Vector2((w.last.x - MX0) / MW, (w.last.z - MZ0) / MH))
		sm.set_shader_parameter("search_r", Game.police.search_radius() if w.searching else 22.0)
		sm.set_shader_parameter("search_color", (Color(1, 0.23, 0.3, 0.3) if int(Game.t * 2.0) % 2 else Color(0.23, 0.42, 1, 0.3)) if w.searching else Color(1, 1, 1, 0.18))
	else:
		sm.set_shader_parameter("search_r", 0.0)
	var hz = null
	for z in Game.hot_zones:
		if hz == null or U.d2(z.pos, pp) < U.d2(hz.pos, pp):
			hz = z
	if hz != null:
		sm.set_shader_parameter("hot_uv", Vector2((hz.pos.x - MX0) / MW, (hz.pos.z - MZ0) / MH))
		sm.set_shader_parameter("hot_r", hz.r)
	else:
		sm.set_shader_parameter("hot_r", 0.0)

func blips() -> Array:
	var out := []
	var pt = Game.partner
	if pt and not pt.hidden:
		out.append({"x": pt.global_position.x, "z": pt.global_position.z, "kind": "dot", "c": Color("b48cff"), "r": 3.0})
	var pc = Game.player_car
	if pc and Game.player.in_car != pc and is_instance_valid(pc):
		out.append({"x": pc.global_position.x, "z": pc.global_position.z, "kind": "sq", "c": Color("2de2e6"), "r": 6.0})
	var fl := Color("ff3b4f") if int(Game.t * 4.0) % 2 else Color("3b6bff")
	for u in Game.police.units:
		if not is_instance_valid(u.car):
			continue
		var cp: Vector3 = u.car.global_position
		if u.state == "patrol":
			out.append({"x": cp.x, "z": cp.z, "kind": "sq", "c": Color("8fa6ff"), "r": 5.0})
			continue
		out.append({"x": cp.x, "z": cp.z, "kind": "sq", "c": fl, "r": 6.0})
		for c in u.cops:
			if is_instance_valid(c) and not c.hidden and not c.dead:
				out.append({"x": c.global_position.x, "z": c.global_position.z, "kind": "dot", "c": fl, "r": 2.6})
	var h = Game.police.heli.node
	if h != null:
		out.append({"x": h.position.x, "z": h.position.z, "kind": "heli", "c": fl, "r": 7.0})
	var tc = Game.robbery.truck.car
	if tc != null and is_instance_valid(tc):
		out.append({"x": tc.global_position.x, "z": tc.global_position.z, "kind": "sq", "c": Color("f4f4f4"), "r": 7.0})
	return out

# ---------- per-frame state ----------
func do_action(i: int) -> void:
	var P = Game.player
	if P.action != null:
		if i == 0:
			P.action = null
		return
	if actions != null and i < actions.actions.size():
		P.start_action(actions.actions[i], actions.target)

func update_state(dt: float) -> void:
	var P = Game.player
	actions = P.current_actions() if not P.dead else null
	_update_minimap()
	if fps_label.visible:
		var st: Dictionary = Game.main.streamer.stats
		fps_label.text = "%d fps  |  3D %d%%  |  chunks %d near, %d far, %d loading" % [Engine.get_frames_per_second(),
			roundi(get_viewport().scaling_3d_scale * 100.0), st.loaded, st.far, st.queued]
	var t = P.aim_target
	if t != null and P.weapon:
		var s := Player.role_name(t).capitalize()
		if t.role == "clerk" and t.state == "comply" and t.site.register > 0:
			s += " - emptying register %d%%" % roundi(t.mem.get("reg", 0.0) * 100.0)
		elif t.role in ["guard", "truckguard"] and t.state == "alert":
			s += " - surrendering %d%%" % roundi(t.surrender * 100.0)
		elif t.state == "surrendered":
			s += " - surrendered"
		elif t.fear > 0.3:
			s += " - terrified"
		target_text = s
	hud_t -= dt
	if hud_t > 0.0:
		return
	hud_t = 0.1
	var bw := Robbery.bag_weight(Game.bag)
	money_rows = [["BANK", U.money(Game.money.bank), true, Color("7cf27c")], ["CASH", U.money(Game.money.cash), true, Color.WHITE],
		["BAG %d%%" % roundi(bw / Game.bag_cap * 100.0), U.money(Robbery.bag_value(Game.bag)), false, Color("ffcf5a")]]
	if not Game.partner_bag.is_empty():
		money_rows.append(["PARTNER", U.money(Robbery.bag_value(Game.partner_bag)), false, Color("b48cff")])
	if Game.player_car and not Game.player_car.trunk.is_empty():
		money_rows.append(["TRUNK", U.money(Robbery.bag_value(Game.player_car.trunk)), false, Color("2de2e6")])
	var H := Game.heat
	badges = []
	if P.masked:
		badges.append(["MASK ON", ""])
	if H.face > 0.0:
		badges.append(["IDENTIFIED " + U.fmt_time(H.face), "bad"])
	if H.outfit >= 0:
		badges.append(["OUTFIT KNOWN" if H.outfit == Game.outfit else "OLD OUTFIT KNOWN", "bad" if H.outfit == Game.outfit else "dim"])
	if H.car_id >= 0:
		var mine: bool = P.in_car != null and P.in_car.car_id == H.car_id
		badges.append(["CAR KNOWN" if mine else ("%s CAR KNOWN" % Game.CAR_COLOR_NAMES[clampi(H.car_color, 0, 7)]).to_upper(), "bad" if mine else "dim"])
	if Game.in_garage:
		badges.append(["IN COVER", "good"])
	timers = []
	var V: Dictionary = Game.robbery.vault
	if V.state in ["open", "opening"]:
		timers.append(["VAULT OPEN " + U.fmt_time(maxf(0.0, V.open_time - (V.t if V.state == "open" else 0.0))), "warn"])
	if V.state == "closing":
		timers.append(["VAULT CLOSING", "bad"])
	var dye: float = Game.robbery.dye_warning()
	if dye >= 0.0:
		timers.append(["DYE PACK %d / 75 m" % roundi(dye), "bad" if dye > 55.0 else "warn"])
	if P.bust_t > 0.0:
		timers.append(["BEING ARRESTED %d%%" % roundi(P.bust_t / 2.2 * 100.0), "bad"])
	var w := Game.wanted
	var pp: Vector3 = P.in_car.global_position if P.in_car else P.global_position
	var caller = Game.main.npc_ai.active_caller()
	if caller != null:
		var cp: float = Game.main.npc_ai.caller_progress(caller)
		if cp >= 0.0:
			timers.append(["WITNESS CALLING 911 %d%% - %d m" % [roundi(cp * 100.0), roundi(U.d2(caller.global_position, pp))], "bad"])
	match w.state:
		"response":
			if w.eta > 0.5:
				timers.append(["POLICE RESPONDING - ETA " + U.fmt_time(w.eta), "bad"])
			elif w.eta >= 0.0:
				timers.append(["POLICE ON SCENE - suspect unknown", "warn"])
			else:
				timers.append(["POLICE DISPATCHED", "warn"])
		"pursuit":
			timers.append(["PURSUIT - break line of sight", "bad"])
		"lost":
			timers.append(["VISUAL LOST - keep moving", "warn"])
		"search":
			if U.d2(pp, w.last) > Game.police.search_radius():
				timers.append(["LOSING THEM %d%%" % roundi(w.clear / (8.0 + w.stars * 4.0) * 100.0), "warn"])
			else:
				timers.append(["%s %d%%" % ["HIDDEN" if w.hidden else "SEARCH AREA - leave or hide", roundi(w.clear / (8.0 + w.stars * 4.0) * 100.0)], "good" if w.hidden else "warn"])
	if w.stars == 0 and w.get("suspicion", 0.0) > 0.05:
		timers.append(["POLICE SUSPICIOUS %d%%" % roundi(w.suspicion * 100.0), "warn"])
	if Game.police.in_hot_zone(pp):
		timers.append(["HOT ZONE - police are watching", "warn"])
	if P.in_car and P.in_car.crouched:
		timers.append(["HIDING IN CAR", "good"])
	if P.surrendering:
		timers.append(["SURRENDERING - don't move", "warn"])
	if P.in_car and P.in_car.tracker and not P.in_car.personal and P.in_car.kind != "police":
		timers.append(["STOLEN CAR HAS A TRACKER %d%%" % roundi(minf(1.0, Game.police.tracker_t / 25.0) * 100.0), "warn"])
	if Game.sites.size() > 2 and U.d2(P.global_position, Game.sites[2].door) < 70.0 and Game.robbery.truck.state == "wait":
		timers.append(["ARMORED TRUCK IN " + U.fmt_time(Game.robbery.truck.t), ""])
	if Game.robbery.spray.busy > 0.0:
		timers.append(["RESPRAYING...", "good"])

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var P = Game.player
		if screens.has("start") and screens.start.visible:
			if event.physical_keycode in [KEY_ENTER, KEY_SPACE]:
				_start_game()
			return
		if event.physical_keycode == KEY_ESCAPE:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			elif _open_screen_name() != "":
				close_screens()
			else:
				open_screen("pause")
			return
		if not Game.running or Game.paused or P == null:
			return
		match event.physical_keycode:
			KEY_E: do_action(0)
			KEY_Q: do_action(1)
			KEY_Z: do_action(2)
			KEY_R:
				if P.weapon and P.mag < P.MAG:
					P.reload()
				else:
					P.toggle_weapon()
			KEY_X: P.toggle_weapon()
			KEY_C: P.toggle_crouch()
			KEY_SPACE:
				if not P.in_car:
					P.do_jump()
			KEY_M: P.toggle_mask()
			KEY_V, KEY_TAB: Game.focus = not Game.focus
			KEY_T: open_screen("map")
			KEY_G: Game.main.npc_ai.shout()
			KEY_B: P.give_up()
			KEY_H: P.toggle_hide()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and Game.running and not Game.paused:
		Game.main.camera.look(event.relative.x, event.relative.y)
	elif event is InputEventMouseButton and event.pressed and event.device != InputEvent.DEVICE_ID_EMULATION and not show_touch:
		if Game.running and not Game.paused and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

# ---------- screens ----------
func _panel(name: String, w := 760.0, h := 540.0) -> VBoxContainer:
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.04, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.visible = false
	add_child(dim)
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.08, 0.1, 0.96)
	sb.set_corner_radius_all(16)
	sb.set_content_margin_all(24)
	sb.border_color = Color(1, 1, 1, 0.08)
	sb.set_border_width_all(1)
	pc.add_theme_stylebox_override("panel", sb)
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.custom_minimum_size = Vector2(w, h)
	pc.size = Vector2(w, h)
	pc.position = -Vector2(w, h) * 0.5
	pc.grow_horizontal = Control.GROW_DIRECTION_BOTH
	pc.grow_vertical = Control.GROW_DIRECTION_BOTH
	dim.add_child(pc)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	pc.add_child(vb)
	screens[name] = dim
	return vb

func _label(t: String, sz := 18, col := Color.WHITE, wrap := true) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

func _button(t: String, cb: Callable, primary := false) -> Button:
	var b := Button.new()
	b.text = t
	b.custom_minimum_size = Vector2(0, 58)
	b.add_theme_font_size_override("font_size", 22)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("e8b931") if primary else Color(1, 1, 1, 0.1)
	sb.set_corner_radius_all(12)
	b.add_theme_stylebox_override("normal", sb)
	var sbh := sb.duplicate()
	sbh.bg_color = sb.bg_color.lightened(0.15)
	b.add_theme_stylebox_override("hover", sbh)
	b.add_theme_stylebox_override("pressed", sbh)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var sbd := sb.duplicate()
	sbd.bg_color = Color(1, 1, 1, 0.04)
	b.add_theme_stylebox_override("disabled", sbd)
	if primary:
		b.add_theme_color_override("font_color", Color(0.08, 0.06, 0.02))
		b.add_theme_color_override("font_hover_color", Color(0.08, 0.06, 0.02))
		b.add_theme_color_override("font_pressed_color", Color(0.08, 0.06, 0.02))
	b.pressed.connect(cb)
	return b

func _build_screens() -> void:
	# start
	var v := _panel("start", 820, 600)
	v.add_child(_label("HEIST SIMULATOR", 46, Color("e8b931"), false))
	v.add_child(_label("Case the joint. Mask up. Get out before the dye pack pops.", 18, Color(1, 1, 1, 0.7)))
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	var tips := _label("""- Key Lento, Leonida Keys. You start at the stilt house on the bay; your pickup is parked on the shore.
- Three targets in town, east along Route 1: 24/7 Supermarket ($), Diamond Dash Jewelers ($$), Leonida Federal Savings ($$$).
- Wear the mask inside or cameras and witnesses get your face. Change outfits in your car's trunk.
- SHOUT puts a crowd on the floor. Cover them, zip-tie them or let your partner hold them - unwatched hostages sneak out or call 911.
- Witnesses phone the police: aim at them or shout to stop the call. Hollow stars = police responding, they don't know who you are yet.
- Once spotted: break line of sight, leave the red search area or hide (HIDE in a parked car, the garage). Escapes leave a hot zone.
- 3+ stars bring K9 units and roadblocks, 4+ SWAT, spike strips and the helicopter. GIVE UP to surrender (not as a Psycho).
- Sell loot at Yasmani's pawn shop in town or to Brian at the boat works (F), then deposit cash at an ATM.""", 16, Color(1, 1, 1, 0.85))
	tips.custom_minimum_size = Vector2(760, 0)
	sc.add_child(tips)
	var keys := _label("Keyboard: WASD move/drive, mouse look, click fire, hold right mouse to aim, R draw/reload, X holster, C crouch, Space jump (handbrake in a car), N horn, Shift sprint, E/Q/Z actions, M mask, V focus, G shout, B give up, H hide in car, T map.", 13, Color(1, 1, 1, 0.5))
	keys.visible = not show_touch
	v.add_child(keys)
	start_btn = _button("START", _start_game, true)
	v.add_child(start_btn)
	screens.start.visible = true
	# pause / settings
	v = _panel("pause", 560, 640)
	v.add_child(_label("PAUSED", 36, Color("e8b931"), false))
	v.add_child(_button("Resume", close_screens, true))
	v.add_child(_button("Map", func(): open_screen("map")))
	quality_btn = _button("Graphics: ", func():
		Settings.cycle_quality()
		_refresh_settings())
	v.add_child(quality_btn)
	fps_btn = _button("Frame rate: ", func():
		Settings.cycle_fps()
		_refresh_settings())
	v.add_child(fps_btn)
	autores_btn = _button("Auto resolution: ", func():
		Settings.toggle_auto_res()
		_refresh_settings())
	v.add_child(autores_btn)
	steer_btn = _button("Steering: ", func():
		Settings.steer_mode = "stick" if Settings.steer_mode == "buttons" else "buttons"
		Settings.save()
		_refresh_settings())
	v.add_child(steer_btn)
	lfire_btn = _button("Left fire button: ", func():
		Settings.left_fire = not Settings.left_fire
		Settings.save()
		_refresh_settings())
	v.add_child(lfire_btn)
	v.add_child(_button("Show FPS", func():
		Settings.show_fps = not Settings.show_fps
		Settings.save()
		fps_label.visible = Settings.show_fps))
	v.add_child(_button("How to play", func():
		start_btn.text = "RESUME"
		open_screen("start")))
	_refresh_settings()
	# death
	v = _panel("death", 640, 420)
	death_title = _label("WASTED", 64, Color("e04848"), false)
	death_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(death_title)
	death_body = _label("", 18)
	death_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(death_body)
	v.add_child(_button("Continue", func(): Game.main.respawn(), true))
	# shop
	v = _panel("shop", 860, 640)
	var head := HBoxContainer.new()
	head.add_child(_label("YASMANI'S PAWN", 30, Color("ff9ad5"), false))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	shop_money = _label("", 16, Color(1, 1, 1, 0.8), false)
	head.add_child(shop_money)
	v.add_child(head)
	var ssc := ScrollContainer.new()
	ssc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ssc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(ssc)
	shop_list = VBoxContainer.new()
	shop_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shop_list.add_theme_constant_override("separation", 10)
	ssc.add_child(shop_list)
	v.add_child(_button("Leave", close_screens, true))
	# map
	v = _panel("map", 1080, 660)
	var mt := TextureRect.new()
	mt.texture = map_tex
	mt.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mt.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mt.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(mt)
	var ov := MapOverlay.new()
	ov.hud = self
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	mt.add_child(ov)
	v.add_child(_button("Close", close_screens, true))

func _refresh_settings() -> void:
	quality_btn.text = "Graphics: " + Settings.quality.capitalize()
	fps_btn.text = "Frame rate: %d fps%s" % [Settings.fps_cap, " (battery saver)" if Settings.fps_cap == 30 else ""]
	autores_btn.text = "Auto resolution: " + ("On" if Settings.auto_res else "Off")
	steer_btn.text = "Steering: " + ("Left / right buttons" if Settings.steer_mode == "buttons" else "Joystick")
	lfire_btn.text = "Left fire button: " + ("On" if Settings.left_fire else "Off")

func _start_game() -> void:
	screens.start.visible = false
	Game.paused = false
	if not Game.running:
		Game.running = true
		Game.notify("Take the pickup east along Route 1 into town - the 24/7 Supermarket is an easy first score.")
		get_tree().create_timer(4.5).timeout.connect(func(): Game.notify("Tip: tap FOCUS to reveal cameras, alarm panels and safe codes"))

func _open_screen_name() -> String:
	for k in screens:
		if screens[k].visible:
			return k
	return ""

func open_screen(n: String) -> void:
	for k in screens:
		screens[k].visible = k == n
	Game.paused = n != "death"
	canvas.release_all()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if n == "shop":
		render_shop()

func close_screens() -> void:
	if screens.death.visible:
		return
	for k in screens:
		screens[k].visible = false
	Game.paused = false

func show_death(kind: String, body: String) -> void:
	death_title.text = kind
	death_title.add_theme_color_override("font_color", Color("e04848") if kind == "WASTED" else Color("4f8bff"))
	death_body.text = body
	open_screen("death")

func hide_death() -> void:
	screens.death.visible = false
	Game.paused = false

# ---------- fence ----------
func _carried() -> Dictionary:
	var items := Game.bag.duplicate()
	var pt = Game.partner
	var with_partner: bool = pt != null and not pt.hidden and U.d2(pt.global_position, Game.player.global_position) < 8.0
	if with_partner:
		items.append_array(Game.partner_bag)
	return {"items": items, "with_partner": with_partner}

func _pay(n: float) -> bool:
	if Game.money.bank + Game.money.cash < n:
		return false
	var b := minf(Game.money.bank, n)
	Game.money.bank -= b
	Game.money.cash -= n - b
	return true

func _shop_row(title: String, desc: String, btn_text: String, enabled: bool, cb: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_label(title, 20, Color.WHITE, false))
	col.add_child(_label(desc, 14, Color(1, 1, 1, 0.6)))
	row.add_child(col)
	var b := _button(btn_text, cb)
	b.custom_minimum_size = Vector2(220, 54)
	b.disabled = not enabled
	row.add_child(b)
	shop_list.add_child(row)

func render_shop() -> void:
	for c in shop_list.get_children():
		c.queue_free()
	var items: Array = _carried().items
	var jew := 0.0
	var mk := 0.0
	for i in items:
		if i.type == "jewelry":
			jew += i.value
		elif i.type == "marked":
			mk += i.value
	shop_list.add_child(_label("FENCE YOUR LOOT", 15, Color("ffcf5a"), false))
	_shop_row("Jewelry", "%s in bags - pays 65%%" % U.money(jew), "Sell %s" % U.money(jew * 0.65), jew > 0, func(): _sell("jewelry", 0.65))
	_shop_row("Marked bills", "%s in bags - launders at 55%%" % U.money(mk), "Launder %s" % U.money(mk * 0.55), mk > 0, func(): _sell("marked", 0.55))
	shop_list.add_child(_label("TOOLS", 15, Color("ffcf5a"), false))
	var P = Game.player
	for t in TOOLS:
		var owned := ""
		if t.id == "c4":
			owned = "  (%d owned)" % Game.tools.c4
		elif t.id == "armor":
			owned = "  (%d/50)" % roundi(P.armor)
		elif t.id == "zipties":
			owned = "  (%d owned)" % Game.tools.get("zipties", 0)
		elif Game.tools[t.id]:
			owned = "  (owned)"
		var dis: bool = (not t.get("stack", false) and Game.tools[t.id]) or (t.id == "armor" and P.armor >= 50.0)
		_shop_row(t.name + owned, t.desc, U.money(t.price), not dis, func(): _buy(t))
	shop_money.text = "Bank %s  -  Cash %s" % [U.money(Game.money.bank), U.money(Game.money.cash)]

func _sell(type: String, rate: float) -> void:
	var total := 0.0
	var arrs := [Game.bag, Game.partner_bag] if _carried().with_partner else [Game.bag]
	for arr in arrs:
		for i in range(arr.size() - 1, -1, -1):
			if arr[i].type == type:
				total += arr[i].value
				arr.remove_at(i)
	var got := roundf(total * rate)
	Game.money.cash += got
	Game.stats.laundered += got
	Sfx.play("cash")
	Game.notify("The fence paid %s cash" % U.money(got), "good")
	render_shop()

func _buy(t: Dictionary) -> void:
	if not _pay(t.price):
		Game.notify("Not enough money", "bad")
		Sfx.play("bad")
	else:
		match t.id:
			"c4": Game.tools.c4 += 1
			"zipties": Game.tools.zipties = Game.tools.get("zipties", 0) + 4
			"armor":
				Game.player.armor = 50.0
				Game.tools.armor = true
			_: Game.tools[t.id] = true
		Sfx.play("good")
		Game.notify("Bought " + t.name, "good")
	render_shop()


class MapOverlay extends Control:
	var hud
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _process(_dt: float) -> void:
		if is_visible_in_tree():
			queue_redraw()
	func _draw() -> void:
		var tr := get_parent() as TextureRect
		var asp := Hud.MW / Hud.MH
		var sz := tr.size
		var w := sz.x
		var h := sz.x / asp
		if h > sz.y:
			h = sz.y
			w = h * asp
		var o := (sz - Vector2(w, h)) * 0.5
		var to := func(x: float, z: float) -> Vector2: return o + Vector2((x - Hud.MX0) / Hud.MW * w, (z - Hud.MZ0) / Hud.MH * h)
		var f := ThemeDB.fallback_font
		for p in hud.pois:
			var sp: Vector2 = to.call(p.x, p.z)
			draw_circle(sp, 13, Color(0, 0, 0, 0.8))
			var tw := f.get_string_size(p.t, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
			draw_string(f, sp + Vector2(-tw / 2, 5), p.t, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, p.c)
		for b in hud.blips():
			var sp: Vector2 = to.call(b.x, b.z)
			draw_circle(sp, b.r * 0.8, b.c)
		var P = Game.player
		var pp: Vector3 = P.in_car.global_position if P.in_car else P.global_position
		var sp: Vector2 = to.call(pp.x, pp.z)
		var yaw: float = P.in_car.yaw() if P.in_car else P.yaw
		var xf := Transform2D(-yaw + PI, sp)
		draw_colored_polygon(xf * PackedVector2Array([Vector2(0, -11), Vector2(8, 8), Vector2(0, 4), Vector2(-8, 8)]), Color.WHITE)
		if Game.wanted.stars > 0 and (Game.wanted.searching or Game.wanted.state == "response"):
			var c: Vector2 = to.call(Game.wanted.last.x, Game.wanted.last.z)
			draw_circle(c, maxf(4.0, (Game.police.search_radius() if Game.wanted.searching else 22.0) / Hud.MW * w), Color(1, 0.25, 0.3, 0.22) if Game.wanted.searching else Color(1, 1, 1, 0.2))
		for z in Game.hot_zones:
			var c: Vector2 = to.call(z.pos.x, z.pos.z)
			draw_arc(c, maxf(4.0, z.r / Hud.MW * w), 0, TAU, 32, Color(1, 0.55, 0.2, 0.8), 2.0, true)
