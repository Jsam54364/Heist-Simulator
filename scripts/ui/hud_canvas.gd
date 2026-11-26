class_name HudCanvas
extends Control
## Everything drawn over the game view: multi-touch controls (floating joystick,
## look pad, buttons, action pills), wanted stars, money, health, radar blips,
## timers, badges, toasts, the reticle and FOCUS labels. One draw pass per frame.

signal pause_pressed
signal map_pressed

var hud  # Hud
var font: Font
var bold: Font
var touches := {}            # index -> {"kind": "joy"/"look"/"btn", ...}
var joy := {"active": false, "origin": Vector2.ZERO, "pos": Vector2.ZERO, "index": -1}
var buttons: Array = []      # rebuilt every frame by layout()
var toasts: Array = []
var flash_t := 0.0
var sb_pill := StyleBoxFlat.new()
var sb_pill_dis := StyleBoxFlat.new()
var sb_panel := StyleBoxFlat.new()
var sb_badge := StyleBoxFlat.new()
var look_sens := 1.0
const MINI_POS := Vector2(22, 22)
const MINI_SIZE := 176.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font
	var fv := FontVariation.new()
	fv.base_font = font
	fv.variation_embolden = 0.7
	bold = fv
	for sb in [sb_pill, sb_pill_dis, sb_panel, sb_badge]:
		sb.set_corner_radius_all(10)
		sb.anti_aliasing = true
	sb_pill.bg_color = Color(0.06, 0.07, 0.09, 0.82)
	sb_pill.border_color = Color(1, 1, 1, 0.22)
	sb_pill.set_border_width_all(1)
	sb_pill_dis.bg_color = Color(0.06, 0.07, 0.09, 0.55)
	sb_panel.bg_color = Color(0.04, 0.05, 0.06, 0.62)
	sb_badge.set_corner_radius_all(6)
	Game.notified.connect(_on_notify)

func _on_notify(text: String, kind: String) -> void:
	toasts.append({"text": text, "kind": kind, "t": 0.0})
	if toasts.size() > 4:
		toasts.pop_front()

func damage_flash() -> void:
	flash_t = 0.25

# ---------- layout ----------
func btn(id: String, center: Vector2, r: float, label: String, hold := false, active := false, color := Color(1, 1, 1)) -> void:
	buttons.append({"id": id, "c": center, "r": r, "label": label, "hold": hold, "active": active, "color": color, "pill": false})

func pill(id: String, rect: Rect2, a: Dictionary, key: String, progress := -1.0) -> void:
	buttons.append({"id": id, "rect": rect, "label": a.label, "key": key, "disabled": a.get("disabled", false), "progress": progress, "pill": true, "hold": false})

func layout() -> void:
	buttons.clear()
	var P = Game.player
	if P == null or not Game.running or Game.paused or P.dead:
		return
	var S := size
	var W := S.x
	var H := S.y
	btn("pause", Vector2(W * 0.5, 30), 22, "II")
	if P.in_car:
		btn("gas", Vector2(W - 118, H - 128), 64, "GAS", true, P.inp.gas, Color("7cf27c"))
		btn("brake", Vector2(W - 268, H - 84), 52, "BRAKE", true, P.inp.brake, Color("ff6b6b"))
		btn("handbrake", Vector2(W - 150, H - 286), 46, "DRIFT", true, P.inp.handbrake, Color("ffd23f"))
		if absf(P.in_car.speed()) < 1.5 or P.in_car.crouched:
			btn("hide", Vector2(W - 300, H - 236), 36, "HIDE", false, P.in_car.crouched, Color("7cf27c"))
	else:
		if P.weapon:
			btn("fire", Vector2(W - 115, H - 200), 58, "FIRE", true, P.inp.fire, Color("ff5c5c"))
		else:
			btn("run", Vector2(W - 115, H - 200), 48, "RUN", true, P.inp.sprint)
		btn("gun", Vector2(W - 232, H - 92), 42, "GUN", false, P.weapon, Color("ffcf5a"))
		btn("mask", Vector2(W - 335, H - 62), 36, "MASK", false, P.masked, Color("b48cff"))
		btn("focus", Vector2(W - 225, H - 226), 34, "FOCUS", false, Game.focus, Color("2de2e6"))
		if _people_near(P):
			btn("shout", Vector2(W - 330, H - 168), 36, "SHOUT", false, false, Color("ff9a3c"))
		if Game.police.can_surrender() or P.surrendering:
			btn("surrender", Vector2(W - 112, H - 330), 40, "GIVE UP", false, P.surrendering, Color("e6e6e6"))
	# action pills
	var acts = hud.actions
	var x0 := W - 480.0
	var y0 := H - (430.0 if P.in_car else 420.0)
	if P.action != null:
		pill("act0", Rect2(x0, y0, 340, 52), P.action, "E", P.action.t / P.action.dur)
	elif acts != null:
		var keys := ["E", "Q", "Z"]
		for i in mini(3, acts.actions.size()):
			pill("act%d" % i, Rect2(x0, y0 + i * 60, 340, 52), acts.actions[i], keys[i])

func _people_near(P) -> bool:
	for c in Game.chars:
		if c.hidden or c.dead or c.ko or c.role not in ["pedestrian", "driver", "civilian", "staff", "teller", "clerk"]:
			continue
		if U.d2(c.global_position, P.global_position) < 14.0:
			return true
	return false

func hit_button(p: Vector2):
	for b in buttons:
		if b.pill:
			if b.rect.grow(6).has_point(p):
				return b
		elif p.distance_to(b.c) < b.r + 14:
			return b
	return null

# ---------- input ----------
func _input(event: InputEvent) -> void:
	if not Game.running or Game.paused:
		touches.clear()
		joy.active = false
		return
	if event is InputEventScreenTouch:
		var p: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		if event.pressed:
			_touch_down(event.index, p)
		else:
			_touch_up(event.index)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var p: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		var t = touches.get(event.index)
		if t == null:
			return
		if t.kind == "joy":
			joy.pos = p
			_update_joy()
		elif t.kind == "look":
			var rel: Vector2 = event.relative
			Game.main.camera.look(rel.x * 1.15 * look_sens, rel.y * 1.15 * look_sens)
		get_viewport().set_input_as_handled()

func _touch_down(index: int, p: Vector2) -> void:
	var b = hit_button(p)
	if b != null:
		touches[index] = {"kind": "btn", "id": b.id}
		_press(b.id, true)
		return
	if p.distance_to(MINI_POS + Vector2(MINI_SIZE, MINI_SIZE) * 0.5) < MINI_SIZE * 0.5:
		touches[index] = {"kind": "none"}
		map_pressed.emit()
		return
	if p.x < size.x * 0.42 and p.y > 110:
		touches[index] = {"kind": "joy"}
		joy = {"active": true, "origin": p, "pos": p, "index": index}
		_update_joy()
		return
	touches[index] = {"kind": "look"}

func _touch_up(index: int) -> void:
	var t = touches.get(index)
	touches.erase(index)
	if t == null:
		return
	if t.kind == "btn":
		_press(t.id, false)
	elif t.kind == "joy":
		joy.active = false
		Game.player.inp.jx = 0.0
		Game.player.inp.jy = 0.0

func _update_joy() -> void:
	var d: Vector2 = joy.pos - joy.origin
	var R := 70.0
	if d.length() > R * 1.6:
		joy.origin = joy.pos - d.normalized() * R * 1.6
		d = joy.pos - joy.origin
	var v := d / R
	if v.length() > 1.0:
		v = v.normalized()
	Game.player.inp.jx = v.x
	Game.player.inp.jy = -v.y

func _press(id: String, down: bool) -> void:
	var P = Game.player
	match id:
		"gas": P.inp.gas = down
		"brake": P.inp.brake = down
		"handbrake": P.inp.handbrake = down
		"fire": P.inp.fire = down
		"run": P.inp.sprint = down
	if not down:
		return
	match id:
		"gun": P.toggle_weapon()
		"mask": P.toggle_mask()
		"focus": Game.focus = not Game.focus
		"shout": Game.main.npc_ai.shout()
		"surrender": P.give_up()
		"hide": P.toggle_hide()
		"pause": pause_pressed.emit()
		"act0": hud.do_action(0)
		"act1": hud.do_action(1)
		"act2": hud.do_action(2)

func release_all() -> void:
	for idx in touches.keys():
		_touch_up(idx)
	touches.clear()

# ---------- drawing helpers ----------
func text(s: String, pos: Vector2, sz := 16, col := Color.WHITE, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0, f: Font = null, outline := 4) -> void:
	if f == null:
		f = font
	if outline > 0:
		draw_string_outline(f, pos, s, align, width, sz, outline, Color(0, 0, 0, 0.75 * col.a))
	draw_string(f, pos, s, align, width, sz, col)

func centered(s: String, c: Vector2, sz := 16, col := Color.WHITE, f: Font = null, outline := 4) -> void:
	if f == null:
		f = bold
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	text(s, Vector2(c.x - w / 2, c.y + sz * 0.36), sz, col, HORIZONTAL_ALIGNMENT_LEFT, -1, f, outline)

func star_outline(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 11:
		var a := -PI / 2 + i * PI / 5
		var rr := r if i % 2 == 0 else r * 0.45
		pts.append(c + Vector2(cos(a), sin(a)) * rr)
	draw_polyline(pts, Color(0, 0, 0, 0.6), 4.0, true)
	draw_polyline(pts, col, 2.0, true)

func star(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI / 2 + i * PI / 5
		var rr := r if i % 2 == 0 else r * 0.45
		pts.append(c + Vector2(cos(a), sin(a)) * rr)
	draw_colored_polygon(pts, col)
	pts.append(pts[0])
	draw_polyline(pts, Color(0, 0, 0, 0.6), 1.5, true)

func mini_to_screen(wx: float, wz: float, pp: Vector3, th: float, scale: float) -> Vector2:
	var rx := wx - pp.x
	var rz := wz - pp.z
	var cs := cos(th)
	var sn := sin(th)
	var c := MINI_POS + Vector2(MINI_SIZE, MINI_SIZE) * 0.5
	return c + Vector2(rx * cs - rz * sn, rx * sn + rz * cs) * scale

# ---------- draw ----------
func _process(dt: float) -> void:
	var vs := get_viewport_rect().size
	if size != vs:
		position = Vector2.ZERO
		size = vs
	for t in toasts:
		t.t += dt
	while not toasts.is_empty() and toasts[0].t > 5.0:
		toasts.pop_front()
	flash_t = maxf(0.0, flash_t - dt)
	layout()
	queue_redraw()

func _draw() -> void:
	var P = Game.player
	if P == null or not Game.running:
		return
	var S := size
	var W := S.x
	var H := S.y
	# damage flash / low health pulse
	var fa := flash_t * 2.4 if flash_t > 0.0 else (0.18 + sin(Game.t * 5.0) * 0.08 if P.hp < 30.0 and not P.dead else 0.0)
	if fa > 0.0:
		draw_rect(Rect2(Vector2.ZERO, S), Color(0.75, 0.0, 0.05, fa * 0.6))
	_draw_labels()
	_draw_minimap_overlay()
	# health + armor under the radar
	var bx := MINI_POS.x + 8
	var by := MINI_POS.y + MINI_SIZE + 10
	var bw := MINI_SIZE - 16
	draw_rect(Rect2(bx, by, bw, 7), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(bx, by, bw * clampf(P.hp / 100.0, 0, 1), 7), Color("e04848") if P.hp < 35.0 else Color("5ccf6b"))
	if P.armor > 0.0:
		draw_rect(Rect2(bx, by + 9, bw, 5), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(bx, by + 9, bw * clampf(P.armor / 50.0, 0, 1), 5), Color("5aa9ff"))
	# badges + timers (left column)
	var y := by + 28.0
	for b in hud.badges:
		var w := font.get_string_size(b[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 16
		sb_badge.bg_color = {"bad": Color(0.75, 0.12, 0.18, 0.85), "good": Color(0.1, 0.55, 0.3, 0.85), "dim": Color(0.2, 0.22, 0.25, 0.8)}.get(b[1], Color(0.12, 0.13, 0.16, 0.85))
		draw_style_box(sb_badge, Rect2(bx - 8, y, w, 22))
		text(b[0], Vector2(bx, y + 16), 13, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, -1, bold, 0)
		y += 26
	y += 4
	for tm in hud.timers:
		var col: Color = {"bad": Color("ff6b6b"), "warn": Color("ffcf5a"), "good": Color("7cf27c")}.get(tm[1], Color.WHITE)
		text(tm[0], Vector2(bx - 6, y + 16), 15, col, HORIZONTAL_ALIGNMENT_LEFT, -1, bold, 4)
		y += 24
	# wanted stars (top right): hollow = response (suspect unknown), white = pursuit,
	# flashing = visual lost, red = search area
	var w := Game.wanted
	var n_st: int = Game.MAX_STARS
	for i in n_st:
		var on: bool = i < w.stars
		var cen := Vector2(W - 30 - (n_st - 1 - i) * 30, 36)
		if not on:
			star(cen, 12, Color(1, 1, 1, 0.14))
			continue
		match w.state:
			"response":
				star_outline(cen, 12, Color(1, 1, 1, 0.95))
			"lost":
				star(cen, 12, Color(1, 1, 1, 0.95 if int(Game.t * 4.0) % 2 == 0 else 0.3))
			"search":
				star(cen, 12, Color("ff4d5e") if int(Game.t * 2.0) % 2 == 0 else Color("ff8a95"))
			_:
				star(cen, 12, Color(1, 1, 1, 0.97))
	# heat icons under the stars: what the police have on you
	var icons := []
	var HT := Game.heat
	if HT.face > 0.0:
		icons.append(["FACE", Color("ff6b6b")])
	if HT.outfit >= 0 and HT.outfit == Game.outfit:
		icons.append(["OUTFIT", Color("ffcf5a")])
	if HT.car_id >= 0:
		icons.append(["CAR", Color("ffcf5a") if not (P.in_car and P.in_car.car_id == HT.car_id) else Color("ff6b6b")])
	if HT.weapon > 0.0:
		icons.append(["GUN", Color("ffcf5a")])
	if HT.partner > 0.0:
		icons.append(["PARTNER", Color("b48cff")])
	if HT.get("cctv", 0) > 0:
		icons.append(["ONLINE" if HT.cctv == 2 else "CCTV", Color("2de2e6")])
	var ix := W - 22.0
	for ic in icons:
		var tw := font.get_string_size(ic[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 12
		ix -= tw
		sb_badge.bg_color = Color(0.05, 0.06, 0.08, 0.85)
		draw_style_box(sb_badge, Rect2(ix, 54, tw, 18))
		draw_rect(Rect2(ix, 54, 3, 18), ic[1])
		text(ic[0], Vector2(ix + 7, 67), 11, ic[1], HORIZONTAL_ALIGNMENT_LEFT, -1, bold, 0)
		ix -= 4
	if w.stars > 0 or Game.profile() != "PROFESSIONAL":
		var prof := Game.profile()
		var ps := "PROFILE: " + prof
		var pw := bold.get_string_size(ps, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		text(ps, Vector2(W - 22 - pw, 88), 11, {"PROFESSIONAL": Color("9fe8b0"), "HARDENED": Color("ffcf5a"), "VIOLENT": Color("ff9a3c"), "PSYCHO": Color("ff4d5e")}[prof], HORIZONTAL_ALIGNMENT_LEFT, -1, bold, 3)
	var my := 104.0
	for row in hud.money_rows:
		var lw := 230.0
		text(row[0], Vector2(W - 22 - lw, my), 13, Color(1, 1, 1, 0.7), HORIZONTAL_ALIGNMENT_LEFT, -1, bold, 3)
		text(row[1], Vector2(W - 22 - lw, my), 20 if row[2] else 17, row[3], HORIZONTAL_ALIGNMENT_RIGHT, lw, bold, 4)
		my += 24 if row[2] else 21
	# goal bar
	var gw := 240.0
	var gx := W * 0.5 - gw / 2
	draw_rect(Rect2(gx, 58, gw, 4), Color(0, 0, 0, 0.5))
	draw_rect(Rect2(gx, 58, gw * clampf(Game.money.bank / 250000.0, 0, 1), 4), Color("7cf27c"))
	centered("GOAL  %s / $250,000 banked" % U.money(Game.money.bank), Vector2(W * 0.5, 74), 12, Color(1, 1, 1, 0.75), font, 3)
	# toasts
	var ty := 98.0
	for t in toasts:
		var a := clampf(5.0 - t.t, 0.0, 1.0) * clampf(t.t * 6.0, 0.0, 1.0)
		var col: Color = {"bad": Color("ff6b6b"), "warn": Color("ffcf5a"), "good": Color("7cf27c")}.get(t.kind, Color.WHITE)
		col.a = a
		var tw := minf(W * 0.5, font.get_string_size(t.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x + 30)
		sb_panel.bg_color = Color(0.03, 0.04, 0.05, 0.72 * a)
		draw_style_box(sb_panel, Rect2(W * 0.5 - tw / 2, ty, tw, 30))
		draw_rect(Rect2(W * 0.5 - tw / 2, ty + 4, 3, 22), col)
		text(t.text, Vector2(W * 0.5 - tw / 2 + 14, ty + 21), 16, Color(1, 1, 1, a), HORIZONTAL_ALIGNMENT_LEFT, tw - 20, font, 0)
		ty += 36
	# reticle + target
	if P.weapon and P.in_car == null and not P.dead:
		var c := S * 0.5
		var hot = P.aim_target != null
		var rc := Color("ff4d4d") if hot else Color(1, 1, 1, 0.9)
		var g := 5.0 if hot else 8.0
		for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
			draw_line(c + d * g, c + d * (g + 9), Color(0, 0, 0, 0.6), 4)
			draw_line(c + d * g, c + d * (g + 9), rc, 2)
		draw_circle(c, 2, rc)
		if hot:
			centered(hud.target_text, c + Vector2(0, 46), 17, Color.WHITE, bold, 5)
	# speedometer
	if P.in_car:
		var car = P.in_car
		var sc := Vector2(W * 0.5, H - 70)
		sb_panel.bg_color = Color(0.03, 0.04, 0.05, 0.62)
		draw_style_box(sb_panel, Rect2(sc.x - 90, sc.y - 44, 180, 80))
		centered(str(roundi(absf(car.speed()) * 2.237)), sc + Vector2(-14, -6), 38, Color.WHITE, bold, 0)
		text("MPH", sc + Vector2(30, -12), 12, Color(1, 1, 1, 0.6), HORIZONTAL_ALIGNMENT_LEFT, -1, bold, 0)
		text("R" if car.gear == 0 else str(car.gear), sc + Vector2(30, 8), 18, Color("ffcf5a"), HORIZONTAL_ALIGNMENT_LEFT, -1, bold, 0)
		draw_rect(Rect2(sc.x - 74, sc.y + 22, 148, 5), Color(1, 1, 1, 0.15))
		var rp: float = 0.15 + car.rpm * 0.85
		draw_rect(Rect2(sc.x - 74, sc.y + 22, 148 * rp, 5), Color("ff6b6b") if rp > 0.9 else Color("ffcf5a"))
	# touch controls
	if hud.show_touch:
		if joy.active:
			draw_circle(joy.origin, 74, Color(0, 0, 0, 0.22))
			draw_arc(joy.origin, 74, 0, TAU, 48, Color(1, 1, 1, 0.35), 2, true)
			var kd: Vector2 = (joy.pos - joy.origin).limit_length(70)
			draw_circle(joy.origin + kd, 32, Color(1, 1, 1, 0.55))
		else:
			var hc := Vector2(150, H - 150)
			draw_arc(hc, 64, 0, TAU, 48, Color(1, 1, 1, 0.16), 2, true)
			draw_circle(hc, 26, Color(1, 1, 1, 0.12))
	for b in buttons:
		if b.pill:
			var r: Rect2 = b.rect
			draw_style_box(sb_pill_dis if b.disabled else sb_pill, r)
			if b.progress >= 0.0:
				draw_rect(Rect2(r.position.x + 6, r.end.y - 7, (r.size.x - 12) * clampf(b.progress, 0, 1), 4), Color("7cf27c"))
			if not b.disabled:
				draw_circle(Vector2(r.position.x + 26, r.position.y + r.size.y / 2), 15, Color(1, 1, 1, 0.92))
				centered(b.key if not hud.show_touch else "", Vector2(r.position.x + 26, r.position.y + r.size.y / 2), 15, Color(0.05, 0.05, 0.05), bold, 0)
			text(b.label, Vector2(r.position.x + (50 if not b.disabled else 16), r.position.y + r.size.y / 2 + 6), 16, Color(1, 1, 1, 0.5 if b.disabled else 1.0), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 60, bold, 0)
		elif hud.show_touch or b.id == "pause":
			var col: Color = b.color
			var fill := Color(col.r, col.g, col.b, 0.42) if b.active else Color(0.03, 0.04, 0.05, 0.42)
			draw_circle(b.c, b.r, fill)
			draw_arc(b.c, b.r, 0, TAU, 48, Color(col.r, col.g, col.b, 0.85 if b.active else 0.5), 2.5, true)
			centered(b.label, b.c, clampi(int(b.r * 0.38), 11, 20), Color.WHITE, bold, 3)

func _draw_minimap_overlay() -> void:
	var P = Game.player
	var mm = hud.minimap
	if mm == null:
		return
	var pp: Vector3 = P.in_car.global_position if P.in_car else P.global_position
	var scale: float = mm.scale_px
	var th: float = Game.main.camera.yaw - PI
	var c := MINI_POS + Vector2(MINI_SIZE, MINI_SIZE) * 0.5
	var R := MINI_SIZE * 0.5 - 8
	for p in hud.pois:
		var sp := mini_to_screen(p.x, p.z, pp, th, scale)
		var d := sp.distance_to(c)
		if d > R:
			if p.t == "$":
				continue
			sp = c + (sp - c) / d * R
		draw_circle(sp, 8, Color(0, 0, 0, 0.78))
		centered(p.t, sp, 11, p.c, bold, 0)
	for b in hud.blips():
		var sp := mini_to_screen(b.x, b.z, pp, th, scale)
		if sp.distance_to(c) > R + 4:
			continue
		match b.kind:
			"dot": draw_circle(sp, b.r, b.c)
			"heli": draw_arc(sp, b.r, 0, TAU, 20, b.c, 2.0, true)
			_: draw_rect(Rect2(sp - Vector2(b.r, b.r) * 0.5, Vector2(b.r, b.r)), b.c)
	var pyaw: float = P.in_car.yaw() if P.in_car else P.yaw
	var rel: float = pyaw - Game.main.camera.yaw
	var arrow := PackedVector2Array([Vector2(0, -9), Vector2(7, 7), Vector2(0, 3), Vector2(-7, 7)])
	var xf := Transform2D(-rel, c)
	var pts := xf * arrow
	draw_colored_polygon(pts, Color.WHITE)
	pts.append(pts[0])
	draw_polyline(pts, Color.BLACK, 1.5, true)
	var ring := Color(1, 1, 1, 0.65)
	if Game.wanted.stars > 0:
		ring = Color("ff3b4f") if int(Game.t * 4.0) % 2 else Color("3b6bff")
	draw_arc(c, MINI_SIZE * 0.5 - 1, 0, TAU, 64, ring, 3.0, true)

func _draw_labels() -> void:
	var cam: Camera3D = Game.main.camera
	var P = Game.player
	var items := []
	var pp: Vector3 = P.global_position
	if Game.focus:
		for it in Game.interactables:
			var lab = it.focus.call() if it.focus is Callable else it.focus
			if lab == null or lab == "":
				continue
			if U.d2(it.pos, pp) > 32.0:
				continue
			items.append([it.pos + Vector3(0, 1.3, 0), lab, it.focus_color])
		for s in Game.sites:
			for cm in s.cameras:
				if cm.destroyed or U.d2(cm.pos, pp) > 32.0:
					continue
				items.append([cm.pos + Vector3(0, 0.35, 0), "CLOUD CAM" if cm.cloud else "CAMERA", Color("2de2e6") if cm.cloud else Color("ff5c74")])
		for c in Game.chars:
			if c.hidden or c.dead or c.ko or U.d2(c.global_position, pp) > 30.0:
				continue
			var lp: Vector3 = c.global_position + Vector3(0, 2.25, 0)
			if c.role in ["guard", "truckguard"]:
				items.append([lp, "GUARD - SURRENDERED" if c.state == "surrendered" else "GUARD%s%s" % [" - has code" if c.has_code else "", " - has key" if c.has_key else ""], Color("ffd54a")])
			elif c.has_key and c.site != null:
				items.append([lp, "HAS KEY", Color("ffd54a")])
			elif c.hero and c.role == "civilian" and c.site != null and c.site.robbery_active:
				items.append([lp, "WANNABE HERO", Color("ff9a3c")])
	for c in Game.chars:
		if c.hidden or c.dead:
			continue
		if c.ko and (c.has_code or c.has_key) and not c.searched and U.d2(c.global_position, pp) < 10.0:
			items.append([c.global_position + Vector3(0, 0.7, 0), "SEARCH", Color("ffd54a")])
			continue
		if c.ko or U.d2(c.global_position, pp) > 45.0:
			continue
		# always-on warnings: people calling the cops, filming, sneaking out
		var cp: float = Game.main.npc_ai.caller_progress(c)
		if cp >= 0.0:
			items.append([c.global_position + Vector3(0, 2.25, 0), "CALLING 911 %d%%" % roundi(cp * 100.0), Color("ff5c74")])
		elif c.state == "film":
			items.append([c.global_position + Vector3(0, 2.25, 0), "FILMING YOU", Color("2de2e6")])
		elif c.state == "sneak":
			items.append([c.global_position + Vector3(0, 2.25, 0), "SNEAKING OUT", Color("ff9a3c")])
		elif c.mem.get("tied", false) and Game.focus:
			items.append([c.global_position + Vector3(0, 1.6, 0), "TIED", Color("9fe8b0")])
	for it in items:
		var wp: Vector3 = it[0]
		wp.y += Game.ground_y(wp.x, wp.z)
		if cam.is_position_behind(wp):
			continue
		var sp := cam.unproject_position(wp)
		if sp.x < -50 or sp.x > size.x + 50 or sp.y < -20 or sp.y > size.y + 20:
			continue
		var s: String = it[1]
		var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 14
		draw_rect(Rect2(sp.x - w / 2, sp.y - 10, w, 20), Color(0.04, 0.05, 0.06, 0.78))
		draw_rect(Rect2(sp.x - w / 2, sp.y - 10, 3, 20), it[2])
		text(s, Vector2(sp.x - w / 2 + 8, sp.y + 5), 12, it[2], HORIZONTAL_ALIGNMENT_LEFT, -1, bold, 0)
