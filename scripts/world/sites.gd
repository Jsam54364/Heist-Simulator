class_name SiteBuilder
extends RefCounted
## Robbery targets (Quik-E 24/7, Diamond Dash Jewelers, Leonida Federal Savings) and
## support locations (fence, safehouse, garage, Pay 'N' Spray, ATMs), with their
## interiors, interactables, doors, cameras and staff. Port of sites.js.

var B: MeshBuilder
var R: Node
var cur_group: Node3D = null
const PRODUCT := [0xe2434b, 0xf2a531, 0x2e6fd1, 0x2c8f6e, 0xffd23f, 0x8b4bd1, 0xffffff, 0xe85d9a, 0x1d9fb5]

func _init(builder: MeshBuilder) -> void:
	B = builder
	R = Game.robbery

static func col(h: int) -> Color:
	return Color.hex((h << 8) | 0xff)

func act(label: String, dur: float, run = null, opts := {}) -> Dictionary:
	var a := {"label": label, "dur": dur, "run": run, "disabled": run == null and opts.get("disabled", false)}
	a.merge(opts, true)
	return a

func inter(o: Dictionary) -> Dictionary:
	var it := {"r": 1.6, "site": null, "focus": null, "focus_color": Color.WHITE}
	it.merge(o, true)
	Game.interactables.append(it)
	return it

func dyn(x: float, y: float, z: float, w: float, h: float, d: float, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(w, h, d)
	mi.mesh = bm
	mi.material_override = mat
	mi.position = Vector3(x, y + h / 2, z)
	(parent if parent else (cur_group if cur_group else Game.world)).add_child(mi)
	return mi

func noise(pos: Vector3, r: float) -> void:
	Game.add_noise(pos, r)

# ---------- geometry helpers ----------
func _segs(a1: float, a2: float, gaps: Array) -> Array:
	var out := []
	var cur := a1
	var g := gaps.duplicate()
	g.sort_custom(func(p, q): return p[0] < q[0])
	for gp in g:
		if gp[0] > cur:
			out.append([cur, gp[0]])
		cur = maxf(cur, gp[1])
	if a2 > cur:
		out.append([cur, a2])
	return out

func wall_x(z: float, x1: float, x2: float, gaps := [], h := 4.0, mat: Material = null, t := 0.3, color := Color.WHITE) -> void:
	if mat == null:
		mat = Mats.m("plaster")
	for s in _segs(x1, x2, gaps):
		B.box((s[0] + s[1]) / 2, 0, z, s[1] - s[0], h, t, mat, {"color": color})
	for gp in gaps:
		B.box((gp[0] + gp[1]) / 2, 2.7, z, gp[1] - gp[0], h - 2.7, t, mat, {"color": color})

func wall_z(x: float, z1: float, z2: float, gaps := [], h := 4.0, mat: Material = null, t := 0.3, color := Color.WHITE) -> void:
	if mat == null:
		mat = Mats.m("plaster")
	for s in _segs(z1, z2, gaps):
		B.box(x, 0, (s[0] + s[1]) / 2, t, h, s[1] - s[0], mat, {"color": color})
	for gp in gaps:
		B.box(x, 2.7, (gp[0] + gp[1]) / 2, t, h - 2.7, gp[1] - gp[0], mat, {"color": color})

func storefront_x(z: float, x1: float, x2: float, gaps: Array, tint: Color) -> void:
	var paint := Mats.m("paint_gloss")
	for s in _segs(x1, x2, gaps):
		var cx: float = (s[0] + s[1]) / 2
		var w: float = s[1] - s[0]
		B.box(cx, 0, z, w, 0.9, 0.3, paint, {"color": tint})
		B.box(cx, 0.9, z, w, 1.8, 0.12, Mats.m("window_glass"), {"layer": "glass", "shadow": false})
		var k: float = s[0] + 2.0
		while k < s[1] - 0.5:
			B.box(k, 0.9, z, 0.12, 1.8, 0.18, paint, {"color": tint, "collide": false})
			k += 2.0
	B.box((x1 + x2) / 2, 2.7, z, x2 - x1, 1.5, 0.3, paint, {"color": tint})

func add_building(n: String, x1: float, x2: float, z1: float, z2: float, garage := false) -> Dictionary:
	var b := {"name": n, "rect": Rect2(x1, z1, x2 - x1, z2 - z1), "garage": garage}
	Game.buildings.append(b)
	return b

func upper(x1: float, x2: float, z1: float, z2: float, floors: int, mat: Material, color: Color, trim := Color("f4f1ea")) -> void:
	var cx := (x1 + x2) / 2
	var cz := (z1 + z2) / 2
	var w := x2 - x1 + 0.3
	var d := z2 - z1 + 0.3
	var paint := Mats.m("paint")
	B.box(cx, 4, cz, w, floors * 3.4, d, mat, {"color": color, "collide": false})
	B.box(cx, 3.9, cz, w + 0.4, 0.35, d + 0.4, paint, {"color": trim, "collide": false, "shadow": false})
	var top := 4.0 + floors * 3.4
	B.box(cx, top - 0.15, cz, w + 0.6, 0.5, d + 0.6, paint, {"color": trim, "collide": false})
	B.box(cx, top, cz, w, 0.12, d, Mats.m("roof_gravel"), {"collide": false})
	for pc in [[x1, z1], [x2, z1], [x1, z2], [x2, z2]]:
		B.box(pc[0], 4, pc[1], 0.7, floors * 3.4, 0.7, paint, {"color": trim, "collide": false, "shadow": false})
	for ac in [[cx - w / 4, cz], [cx + w / 4, cz - d / 5]]:
		B.box(ac[0], top, ac[1], 1.6, 1.1, 1.2, paint, {"color": col(0xb9bdc2), "collide": false})
	B.add_col(Vector3(x1 - 0.15, 4, z1 - 0.15), Vector3(x2 + 0.15, top + 1, z2 + 0.15))
	# far LOD: ground floor as a shopfront band + facade above; occlude only the upper
	# floors so the open ground-floor interior never hides what's behind its windows
	B.building_volume(Vector3(x1, 0, z1), Vector3(x2, top, z2), Mats.far_cell(mat), color, 4.0, 4.2)

func lights(x1: float, x2: float, z1: float, z2: float, step := 3.2) -> void:
	var x := x1 + step / 2
	while x < x2:
		var z := z1 + step / 2
		while z < z2:
			B.box(x, 3.9, z, 1.2, 0.06, 0.4, Mats.m("light_panel"), {"collide": false, "shadow": false})
			z += step
		x += step
	interior_light(x1, x2, z1, z2)

## Warm ceiling lights + an interior reflection probe, so rooms are lit by their
## fixtures (and reflect them on polished floors) instead of by the blue sky.
func interior_light(x1: float, x2: float, z1: float, z2: float) -> void:
	var parent: Node3D = cur_group if cur_group else Game.world
	var w := x2 - x1
	var d := z2 - z1
	var nx := maxi(1, roundi(w / 8.0))
	var nz := maxi(1, roundi(d / 8.0))
	for i in nx:
		for j in nz:
			var l := OmniLight3D.new()
			l.position = Vector3(x1 + (i + 0.5) * w / nx, 3.55, z1 + (j + 0.5) * d / nz)
			l.light_color = Color(1.0, 0.9, 0.78)
			l.light_energy = 1.1
			l.light_indirect_energy = 0.5
			l.light_specular = 0.4
			l.omni_range = maxf(w / nx, d / nz) * 1.05 + 1.5
			l.omni_attenuation = 0.8
			l.shadow_enabled = false
			# only rooms + people are lit (streets aren't paying for room lights), and
			# lights switch off with distance
			l.light_cull_mask = 2 | 4
			l.distance_fade_enabled = true
			l.distance_fade_begin = 40.0
			l.distance_fade_length = 12.0
			l.add_to_group("interior_light")
			parent.add_child(l)
	var rp := ReflectionProbe.new()
	rp.position = Vector3((x1 + x2) / 2, 2.0, (z1 + z2) / 2)
	rp.size = Vector3(w + 0.4, 4.0, d + 0.4)
	rp.interior = true
	rp.box_projection = true
	rp.ambient_mode = ReflectionProbe.AMBIENT_COLOR
	rp.ambient_color = Color(0.86, 0.8, 0.72)
	rp.ambient_color_energy = 0.55
	rp.update_mode = ReflectionProbe.UPDATE_ONCE
	rp.max_distance = 30.0
	if "reflection_mask" in rp:
		rp.set("reflection_mask", 2 | 4)
	rp.add_to_group("interior_probe")
	parent.add_child(rp)

func products(x1: float, x2: float, y: float, z: float, depth: float, face: float) -> void:
	var x := x1 + 0.2
	while x < x2 - 0.1:
		var h := 0.2 + randf() * 0.22
		B.box(x, y, z + face * 0.02, 0.26, h, depth, Mats.m("paint_gloss"), {"color": col(PRODUCT[randi() % PRODUCT.size()]), "collide": false, "shadow": false})
		x += 0.32 + randf() * 0.1

func plant(x: float, z: float, s := 1.0) -> void:
	B.box(x, 0.15, z, 0.5 * s, 0.5 * s, 0.5 * s, Mats.m("paint"), {"color": col(0x8a5a3c), "collide": false})
	B.cylinder(x, 0.65 * s, z, 0.55 * s, 1.4 * s, Mats.m("leaf"), col(0x3f8f3a), 7, 0.0)
	B.add_col(Vector3(x - 0.3, 0, z - 0.3), Vector3(x + 0.3, 1.6, z + 0.3))

func sign_label(text: String, x: float, y: float, z: float, color: Color, h := 1.2, yaw := INF) -> void:
	if yaw == INF:
		yaw = 0.0 if z < 0 else PI
	var l := Label3D.new()
	l.text = text
	l.font_size = 96
	l.pixel_size = h / 110.0
	l.modulate = color
	l.outline_size = 14
	l.outline_modulate = Color(0.05, 0.05, 0.07)
	l.position = Vector3(x, y, z) + U.fwd(yaw) * 0.06
	l.rotation.y = yaw
	l.double_sided = false
	Game.world.add_child(l)
	var back_w := text.length() * h * 0.52 + h * 0.6
	var bm := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(back_w, h * 1.15, 0.08)
	bm.mesh = b
	bm.material_override = Mats.solid(Color(0.08, 0.09, 0.11), 0.6)
	bm.position = Vector3(x, y, z)
	bm.rotation.y = yaw
	Game.world.add_child(bm)

# ---------- shared site pieces ----------
func safe(site: Dictionary, x: float, z: float, face_yaw: float, loot_fn: Callable) -> void:
	B.box(x, 0, z, 0.9, 1.1, 0.8, Mats.m("safe"))
	var door := dyn(x + sin(face_yaw) * 0.42, 0.1, z + cos(face_yaw) * 0.42, absf(cos(face_yaw)) * 0.7 + 0.04, 0.9, absf(sin(face_yaw)) * 0.7 + 0.04, Mats.m("interact"))
	site.safe_door = door
	var pos := Vector3(x + sin(face_yaw) * 0.9, 0, z + cos(face_yaw) * 0.9)
	inter({
		"pos": pos, "site": site, "focus_color": Color("7cf27c"),
		"focus": func(): return ("SAFE - code " + site.code) if Game.known_codes.has(site.id) else "SAFE - needs code",
		"actions": func():
			if site.safe_open:
				return [act("Grab safe contents", 2.0, func(): if loot_fn.call(site.safe_loot): site.safe_loot = 0.0, {"crime": true})] if site.safe_loot > 0 else []
			var a := []
			if Game.known_codes.has(site.id):
				a.append(act("Open safe (code %s)" % site.code, 2.0, func(): open_safe(site); R.crime(site, "safe"), {"crime": true}))
			else:
				a.append(act("Safe locked - find the code", 0.0, null, {"disabled": true}))
			a.append(act("Force safe open (loud)", 7.0, func():
				open_safe(site)
				R.crime(site, "force")
				noise(pos, 20)
				if site.alarm_armed:
					R.trigger_alarm(site, "Safe forced open"), {"crime": true, "drill": true}))
			return a,
	})

func open_safe(site: Dictionary) -> void:
	site.safe_open = true
	site.safe_door.rotation.y = 1.4
	Sfx.play("click")

func code_source(site: Dictionary, pos: Vector3, label: String) -> void:
	inter({
		"pos": pos, "site": site, "focus_color": Color("7cf27c"),
		"focus": func(): return ("CODE " + site.code) if Game.known_codes.has(site.id) else label.to_upper(),
		"actions": func():
			if Game.known_codes.has(site.id):
				return []
			return [act("Read sticky note" if label == "Sticky note" else "Check computer screen", 1.2, func():
				Game.known_codes[site.id] = true
				Game.notify("Safe code for %s: %s" % [site.name, site.code], "good")
				Sfx.play("good"))],
	})

func alarm_panel(site: Dictionary, x: float, y: float, z: float, w: float, d: float) -> void:
	var m := dyn(x, y, z, w, 0.45, d, Mats.m("alarm"))
	site.alarm_mesh = m
	inter({
		"pos": Vector3(x, 0, z), "site": site, "r": 1.8, "focus_color": Color("f2d230"),
		"focus": func(): return "ALARM - TRIGGERED" if site.alarm_triggered else ("ALARM PANEL" if site.alarm_armed else "ALARM - OFF"),
		"actions": func():
			if site.alarm_triggered:
				return [act("Alarm already triggered", 0.0, null, {"disabled": true})]
			if not site.alarm_armed:
				return []
			return [act("Disable alarm", 2.5, func():
				site.alarm_armed = false
				m.material_override = Mats.m("counter")
				Game.notify("Alarm disabled - smashing cases and kicking doors is quiet now", "good")
				Sfx.play("good"), {"crime": true})],
	})

func dvr(site: Dictionary, x: float, z: float, w: float, d: float) -> void:
	B.box(x, 0, z, w, 1.6, d, Mats.m("dvr"))
	inter({
		"pos": Vector3(x, 0, z), "site": site, "r": 1.8, "focus_color": Color("3f8fff"),
		"focus": func(): return "FOOTAGE - DESTROYED" if site.footage.destroyed else "SECURITY FOOTAGE",
		"actions": func():
			if site.footage.destroyed:
				return []
			return [act("Destroy security footage", 2.0, func():
				site.footage = {"face": false, "outfit": -1, "destroyed": true}
				Game.notify("Local footage wiped. Cloud cameras already uploaded what they saw.", "good")
				Sfx.play("glass", 0.5), {"crime": true})],
	})

func staff_door(site: Dictionary, o: Dictionary, outside: Callable) -> Dictionary:
	var door: Dictionary = R.make_door(site, o)
	inter({
		"pos": door.pos, "site": site, "r": 1.9, "focus_color": Color("ff6b6b") if door.kind == "reinforced" else Color.WHITE,
		"focus": func(): return null if door.open else ("REINFORCED DOOR - C4" if door.kind == "reinforced" else "LOCKED DOOR - snap gun"),
		"actions": func():
			if door.open:
				return []
			if not outside.call(Game.player.global_position):
				return [act("Open door", 0.6, func(): R.open_door(door))]
			if door.kind == "reinforced":
				if Game.tools.c4 > 0:
					return [act("Plant C4", 1.5, func(): R.plant_c4(door.pos, site, func(): R.open_door(door, true)), {"crime": true})]
				return [act("Reinforced - needs C4", 0.0, null, {"disabled": true})]
			var a := []
			if Game.keys.has(site.id):
				a.append(act("Unlock with key", 0.8, func(): R.open_door(door); R.crime(site, "enter")))
			if Game.tools.snap:
				a.append(act("Snap gun the lock (quiet)", 2.0, func(): R.open_door(door); Sfx.play("click"); R.crime(site, "enter"), {"crime": true}))
			a.append(act("Kick door (loud)", 1.2, func():
				R.open_door(door)
				Sfx.play("kick")
				noise(door.pos, 18)
				R.crime(site, "kick")
				if site.alarm_armed:
					R.trigger_alarm(site, "Door kicked in"), {"crime": true}))
			if not Game.tools.snap and not Game.keys.has(site.id):
				a.push_front(act("Locked - snap gun or key", 0.0, null, {"disabled": true}))
			return a,
	})
	return door

func spawn(site: Dictionary, role: String, x: float, z: float, opts := {}) -> Character:
	opts["site"] = site
	var c: Character = Game.main.spawn_char(role, Vector3(x, 0, z), opts)
	site.npcs.append(c)
	return c

# ---------- CONVENIENCE STORE (LOW) ----------
func build_store() -> void:
	var S: Dictionary = R.make_site({
		"id": "store", "name": "Quik-E 24/7", "sec": "LOW", "bounds": Rect2(12, -21, 16, 12),
		"door": Vector3(20, 0, -7.4), "crowd": Vector3(18.5, 0, -11), "alarm_stars": 2, "leave_stars": 1, "payout": "$3k-6k cash",
		"public": Rect2(13, -15.8, 7, 5.8),
	})
	cur_group = S.group
	B.box(20, 0.15, -15, 16, 0.03, 12, Mats.m("checker_floor"), {"layer": "ground", "shadow": false})
	storefront_x(-9, 12, 28, [[18.5, 21.5]], col(0x2f8f5b))
	var cream := col(0xfff2c2)
	wall_x(-21, 12, 28, [[13.5, 15]], 4, null, 0.3, cream)
	wall_z(12, -21, -9, [], 4, null, 0.3, cream)
	wall_z(28, -21, -9, [], 4, null, 0.3, cream)
	wall_x(-16.5, 12, 28, [[15, 16.5], [24, 25.5]], 4, null, 0.3, col(0xece8e1))
	wall_z(22, -21, -16.5, [], 4, null, 0.3, col(0xece8e1))
	add_building("store", 12, 28, -21, -9)
	upper(12, 28, -21, -9, 2, Mats.m("facade_stucco"), cream)
	sign_label("QUIK-E 24/7", 20, 5.2, -8.55, Color("ffcf33"), 1.4)
	var counter := Mats.m("counter")
	B.box(23.75, 0, -12, 5.5, 1.0, 0.8, counter)
	B.box(16, 0, -12.7, 4, 1.5, 0.6, Mats.m("plaster"), {"color": col(0xd9dce0)})
	B.box(16, 0, -14.9, 4, 1.5, 0.6, Mats.m("plaster"), {"color": col(0xd9dce0)})
	B.box(12.25, 0.15, -12.5, 0.2, 2.1, 4, Mats.m("paint"), {"color": col(0xf4f4f4), "collide": false})
	for y in [0.15, 0.6, 1.1, 1.6, 2.15]:
		B.box(12.6, y, -12.5, 0.8, 0.08, 4, Mats.m("paint"), {"color": col(0xf4f4f4), "collide": false})
	B.add_col(Vector3(12.15, 0, -14.5), Vector3(13.0, 2.2, -10.5))
	# dressing
	for z in [-12.7, -14.9]:
		for side in [-1.0, 1.0]:
			for y in [0.25, 0.75, 1.2]:
				products(14, 18, y + 0.15, z + side * 0.36, 0.12, side)
	B.box(12.95, 0.15, -12.5, 0.08, 1.9, 3.9, Mats.m("window_glass"), {"collide": false, "shadow": false})
	for y in [0.15, 0.6, 1.1, 1.6]:
		var z := -14.3
		while z < -10.8:
			B.box(12.7, y + 0.23, z, 0.14, 0.3, 0.14, Mats.m("paint_gloss"), {"color": col(PRODUCT[randi() % 9]), "collide": false, "shadow": false})
			z += 0.22
	B.box(25.6, 1.15, -12, 0.9, 0.5, 0.5, Mats.m("paint"), {"color": col(0xffd23f), "collide": false})
	B.box(24.5, 2.2, -13.9, 3, 0.6, 0.08, Mats.m("paint"), {"color": col(0x2c8f6e), "collide": false})
	B.box(20, 0.17, -9.9, 2.4, 0.02, 1.2, Mats.m("paint"), {"color": col(0x2f3a46), "collide": false})
	lights(12, 28, -16.5, -9)
	interior_light(12, 28, -21, -16.5)
	var reg := dyn(23.5, 1.0, -12, 0.45, 0.28, 0.38, Mats.m("interact"))
	S.register_mesh = reg
	inter({
		"pos": Vector3(23.5, 0, -12.9), "site": S, "r": 1.4, "focus_color": Color("ef8a2b"),
		"focus": func(): return "REGISTER" if S.register > 0 else null,
		"actions": func():
			if S.register <= 0:
				return []
			var clerk = S.get("clerk")
			if clerk != null and is_instance_valid(clerk) and not clerk.dead and not clerk.ko:
				return [act("Aim at the clerk to empty it", 0.0, null, {"disabled": true})]
			return [act("Empty register yourself", 5.0, func():
				R.add_cash(S.register, S)
				S.register = 0.0
				R.crime(S, "steal"), {"crime": true})],
	})
	safe(S, 13, -20.3, 0.0, func(v): R.add_cash(v, S); return true)
	B.box(18.5, 0, -20.4, 2, 0.8, 0.8, Mats.m("wood_planks"))
	dyn(18.9, 0.8, -20.3, 0.16, 0.02, 0.16, Mats.m("note"))
	code_source(S, Vector3(18.5, 0, -19.4), "Sticky note")
	alarm_panel(S, 21.82, 1.2, -18.6, 0.05, 0.36)
	dvr(S, 27.3, -20.4, 0.8, 0.6)
	staff_door(S, {"x": 14.25, "z": -21.0, "w": 1.5, "d": 0.34, "kind": "locked"}, func(p): return p.z < -21)
	R.make_camera(S, Vector3(12.45, 3.4, -9.45), Vector3(24, 0.8, -13.5))
	R.make_camera(S, Vector3(12.45, 3.4, -16.95), Vector3(15, 0.3, -20.5))
	S.on_reset = func():
		S.register = float(randi_range(600, 1400))
		S.safe_loot = float(randi_range(2500, 5000))
		S.safe_open = false
		S.safe_door.rotation.y = 0.0
		S.register_mesh.material_override = Mats.m("interact")
		S.clerk = spawn(S, "clerk", 24, -13.3, {"yaw": 0.0})
		spawn(S, "civilian", 16, -11.3)
		spawn(S, "civilian", 18.6, -13.8)

# ---------- JEWELRY STORE (MEDIUM) ----------
func build_jewelry() -> void:
	var S: Dictionary = R.make_site({
		"id": "jewel", "name": "Diamond Dash Jewelers", "sec": "MEDIUM", "bounds": Rect2(-34, -23, 18, 14),
		"door": Vector3(-25, 0, -7.4), "crowd": Vector3(-25, 0, -11), "alarm_stars": 3, "leave_stars": 2, "payout": "$12k-25k jewelry",
		"public": Rect2(-30, -14.5, 10, 4.5),
	})
	cur_group = S.group
	B.box(-25, 0.15, -16, 18, 0.03, 14, Mats.m("carpet"), {"layer": "ground", "shadow": false})
	storefront_x(-9, -34, -16, [[-26.5, -23.5]], col(0x2a2440))
	var lav := col(0xd8ccff)
	wall_x(-23, -34, -16, [[-32, -30.5]], 4, null, 0.3, lav)
	wall_z(-34, -23, -9, [], 4, null, 0.3, lav)
	wall_z(-16, -23, -9, [], 4, null, 0.3, lav)
	wall_x(-17, -34, -16, [[-20, -18.5]], 4, null, 0.3, col(0xf1eadf))
	wall_z(-22, -23, -17, [[-20.6, -19.1]], 4, null, 0.3, col(0xece8e1))
	add_building("jewel", -34, -16, -23, -9)
	upper(-34, -16, -23, -9, 3, Mats.m("facade_brick"), col(0xf3e1d6))
	sign_label("DIAMOND DASH", -25, 5.2, -8.55, Color("7fe3ff"), 1.4)
	plant(-33.2, -9.9)
	plant(-16.8, -9.9)
	for z in [-11.0, -15.0]:
		B.box(-33.8, 0.9, z, 0.06, 1.8, 2.2, Mats.m("chrome_mirror") if false else Mats.m("paint_gloss"), {"color": col(0xcfe6ff), "collide": false})
		B.box(-16.2, 0.9, z, 0.06, 1.8, 2.2, Mats.m("paint_gloss"), {"color": col(0xcfe6ff), "collide": false})
	B.box(-24, 2.6, -16.9, 6, 0.8, 0.06, Mats.m("paint"), {"color": col(0x2a2440), "collide": false})
	lights(-34, -16, -17, -9, 3)
	interior_light(-34, -16, -23, -17)
	B.box(-24, 0, -15.5, 6, 1.0, 0.6, Mats.m("marble"))
	S.cases = []
	for cp in [[-31.8, -11.5], [-31.8, -14.4], [-27.2, -12.8], [-22.8, -12.8], [-18.2, -11.5], [-18.2, -14.4]]:
		var x: float = cp[0]
		var z: float = cp[1]
		B.box(x, 0, z, 1.4, 0.95, 0.8, Mats.m("marble"))
		var glass := dyn(x, 0.95, z, 1.36, 0.3, 0.76, Mats.m("window_glass"))
		var gems := []
		for k in 3:
			gems.append(dyn(x - 0.4 + k * 0.4, 0.97, z, 0.18, 0.08, 0.18, Mats.m("jewel")))
		var cs := {"glass": glass, "gems": gems, "smashed": false, "value": 0.0, "pos": Vector3(x, 0, z)}
		S.cases.append(cs)
		inter({
			"pos": Vector3(x, 0, z), "site": S, "r": 1.5, "focus_color": Color("7fe3ff"),
			"focus": func(): return null if cs.smashed else "DISPLAY CASE",
			"actions": func():
				if cs.smashed:
					return []
				return [act("Smash case & grab jewelry", 1.0, func():
					if not R.add_loot("jewelry", cs.value, false, null, S):
						return
					cs.smashed = true
					cs.glass.visible = false
					for g in cs.gems:
						g.visible = false
					Sfx.play("glass")
					R.puff(Vector3(x, 1.1, z), Color("bfe9ff"), 10, 0.8)
					noise(cs.pos, 14)
					R.crime(S, "smash")
					if S.alarm_armed:
						R.trigger_alarm(S, "Display case smashed"), {"crime": true})],
		})
	safe(S, -33.2, -22.2, PI / 2, func(v): return R.add_loot("jewelry", v, false, null, S))
	B.box(-29, 0, -22.3, 2, 0.8, 0.8, Mats.m("wood_planks"))
	dyn(-29, 0.8, -22.4, 0.6, 0.45, 0.08, Mats.m("note"))
	code_source(S, Vector3(-29, 0, -21.4), "Computer")
	alarm_panel(S, -26.5, 1.2, -22.82, 0.36, 0.05)
	dvr(S, -16.75, -22.3, 0.6, 0.8)
	staff_door(S, {"x": -19.25, "z": -17.0, "w": 1.5, "d": 0.34, "kind": "locked"}, func(p): return p.z > -17)
	staff_door(S, {"x": -31.25, "z": -23.0, "w": 1.5, "d": 0.34, "kind": "locked"}, func(p): return p.z < -23)
	R.make_camera(S, Vector3(-33.55, 3.4, -9.45), Vector3(-24, 0.8, -14))
	R.make_camera(S, Vector3(-16.45, 3.4, -9.45), Vector3(-26, 0.8, -14), true)
	R.make_camera(S, Vector3(-33.55, 3.4, -17.45), Vector3(-30, 0.3, -22))
	S.on_reset = func():
		S.safe_loot = float(randi_range(6000, 10000))
		S.safe_open = false
		S.safe_door.rotation.y = 0.0
		for c in S.cases:
			c.smashed = false
			c.value = float(randi_range(1200, 2500))
			c.glass.visible = true
			for g in c.gems:
				g.visible = true
		var clerk := spawn(S, "staff", -24, -16.3, {"yaw": 0.0})
		clerk.has_key = true
		var guard := spawn(S, "guard", -19.5, -10.6, {"yaw": PI * 0.85, "hp": 70.0})
		guard.has_code = randf() < 0.6
		spawn(S, "civilian", -29, -11.2)
		spawn(S, "civilian", -21, -13.6)

# ---------- BANK (HIGH) ----------
func build_bank() -> void:
	var S: Dictionary = R.make_site({
		"id": "bank", "name": "Leonida Federal Savings", "sec": "HIGH", "bounds": Rect2(13, 9, 24, 22),
		"door": Vector3(25, 0, 7.4), "crowd": Vector3(25, 0, 13), "alarm_stars": 3, "leave_stars": 3, "payout": "up to $200k marked bills",
		"public": Rect2(15, 10.5, 18, 5.5),
	})
	cur_group = S.group
	B.box(25, 0.15, 20, 24, 0.03, 22, Mats.m("marble"), {"layer": "ground", "shadow": false})
	storefront_x(9, 13, 37, [[23.5, 26.5]], col(0x6d7f8f))
	var stone := col(0xf2ece2)
	var inner_c := col(0xe9e2d4)
	wall_z(13, 9, 31, [[27, 28.5]], 4, null, 0.3, stone)
	wall_z(37, 9, 31, [[21.6, 23.1]], 4, null, 0.3, stone)
	wall_x(31, 13, 37, [], 4, null, 0.3, stone)
	wall_x(21, 13, 37, [[17, 18.5], [29.5, 31]], 4, null, 0.3, inner_c)
	wall_z(21, 21, 31, [], 4, null, 0.3, inner_c)
	wall_x(23.5, 21, 29, [[24, 26]], 4, Mats.m("metal_brushed"), 0.5)
	wall_z(29, 23.5, 31, [], 4, Mats.m("metal_brushed"), 0.5)
	wall_x(23.5, 29, 37, [[33, 34.5]], 4, null, 0.3, inner_c)
	add_building("bank", 13, 37, 9, 31)
	upper(13, 37, 9, 31, 5, Mats.m("facade_office"), stone)
	sign_label("LEONIDA FEDERAL SAVINGS", 25, 5.2, 8.55, Color("9fe8b0"), 1.4)
	for x in [16.0, 21.0, 29.0, 34.0]:
		B.box(x, 0.15, 10.4, 0.8, 3.85, 0.8, Mats.m("marble"))
		B.box(x, 0.15, 10.4, 1.1, 0.3, 1.1, Mats.m("paint"), {"color": inner_c, "collide": false})
		B.box(x, 3.7, 10.4, 1.1, 0.3, 1.1, Mats.m("paint"), {"color": inner_c, "collide": false})
	var sx := 15.0
	while sx <= 31.0:
		B.box(sx, 0.15, 15.8, 0.08, 0.95, 0.08, Mats.m("metal_brushed"), {"collide": false})
		if sx + 2.3 <= 31.1:
			B.box(sx + 1.15, 0.95, 15.8, 2.2, 0.06, 0.06, Mats.m("paint"), {"color": col(0xb0263a), "collide": false})
		sx += 2.3
	sign_label("LEONIDA FEDERAL", 23, 3.1, 20.8, Color("9fe8b0"), 0.7, PI)
	plant(14, 9.9)
	plant(36, 9.9)
	lights(13, 37, 9, 21, 3.4)
	lights(21, 29, 23.5, 31, 2.6)
	interior_light(13, 21, 21, 31)
	interior_light(29, 37, 21, 31)
	B.box(23.27, 0, 17.4, 20.25, 1.1, 0.8, Mats.m("marble"))
	S.drawers = []
	for x in [17.0, 23.0, 29.0]:
		var m := dyn(x, 1.1, 17.4, 0.6, 0.12, 0.5, Mats.m("interact"))
		var dr := {"x": x, "mesh": m, "value": 0.0, "dye": false, "taken": false}
		S.drawers.append(dr)
		inter({
			"pos": Vector3(x, 0, 18.3), "site": S, "r": 1.3, "focus_color": Color("ef8a2b"),
			"focus": func(): return null if dr.taken else "TELLER DRAWER",
			"actions": func():
				if dr.taken:
					return []
				if Game.player.global_position.z < 17.85:
					return [act("Get behind the counter", 0.0, null, {"disabled": true})]
				return [act("Grab teller drawer", 2.2, func():
					if not R.add_loot("marked", dr.value, dr.dye, S.door, S):
						return
					dr.taken = true
					dr.mesh.visible = false
					R.crime(S, "steal"), {"crime": true})],
		})
	safe(S, 13.8, 30.2, PI / 2, func(v): return R.add_loot("marked", v, randf() < 0.5, S.door, S))
	B.box(17.5, 0, 29.8, 2, 0.8, 0.8, Mats.m("wood_planks"))
	dyn(17.5, 0.8, 29.9, 0.6, 0.45, 0.08, Mats.m("note"))
	code_source(S, Vector3(17.5, 0, 28.9), "Computer")
	alarm_panel(S, 29.3, 1.2, 27, 0.05, 0.36)
	dvr(S, 36.4, 30.3, 0.6, 0.8)
	staff_door(S, {"x": 30.25, "z": 21.0, "w": 1.5, "d": 0.34, "kind": "locked"}, func(p): return p.z < 21)
	staff_door(S, {"x": 13.0, "z": 27.75, "w": 0.34, "d": 1.5, "kind": "locked"}, func(p): return p.x < 13)
	staff_door(S, {"x": 37.0, "z": 22.35, "w": 0.34, "d": 1.5, "kind": "reinforced"}, func(p): return p.x > 37)
	# vault door on a hinge
	var V: Dictionary = R.vault
	var pivot := Node3D.new()
	pivot.position = Vector3(24, 0, 23.5)
	S.group.add_child(pivot)
	var vd := MeshInstance3D.new()
	var vm := BoxMesh.new()
	vm.size = Vector3(2, 2.65, 0.5)
	vd.mesh = vm
	vd.material_override = Mats.m("vault")
	vd.position = Vector3(1, 1.325, 0)
	pivot.add_child(vd)
	var wheel := MeshInstance3D.new()
	var wm := CylinderMesh.new()
	wm.top_radius = 0.38
	wm.bottom_radius = 0.38
	wm.height = 0.1
	wheel.mesh = wm
	wheel.material_override = Mats.m("lockbox")
	wheel.rotation.x = PI / 2
	wheel.position = Vector3(1, 1.3, -0.3)
	pivot.add_child(wheel)
	V.pivot = pivot
	var vbody := StaticBody3D.new()
	vbody.collision_layer = Game.L_WORLD
	var vcs := CollisionShape3D.new()
	var vbs := BoxShape3D.new()
	vbs.size = Vector3(2, 2.65, 0.5)
	vcs.shape = vbs
	vbody.add_child(vcs)
	vbody.position = Vector3(25, 1.325, 23.5)
	S.group.add_child(vbody)
	V.shape = vcs
	V.col = Game.main.builder_cols_add(Vector3(24, 0, 23.25), Vector3(26, 2.65, 23.75), "vault")
	V.site = S
	V.bounds = Rect2(21.3, 23.8, 7.4, 6.9)
	inter({"pos": Vector3(25, 0, 22.4), "site": S, "r": 1.5, "focus_color": Color("2de2e6"),
		"focus": func(): return "VAULT - opens for cash truck" if V.state == "closed" else "VAULT OPEN",
		"actions": func(): return [act("Vault only opens for an armored truck delivery", 0.0, null, {"disabled": true})] if V.state == "closed" else []})
	B.box(25, 0, 27.4, 3.2, 0.9, 1.0, Mats.m("metal_brushed"))
	B.box(25, 0, 30.3, 6, 1.0, 0.6, Mats.m("metal_brushed"))
	S.stacks = []
	for sp in [[24, 0.9, 27.4], [25, 0.9, 27.4], [26, 0.9, 27.4], [23, 1.0, 30.3], [25, 1.0, 30.3], [27, 1.0, 30.3]]:
		var m := dyn(sp[0], sp[1], sp[2], 0.6, 0.35, 0.4, Mats.m("cash"))
		var st := {"mesh": m, "value": 0.0, "taken": false}
		S.stacks.append(st)
		inter({
			"pos": Vector3(sp[0], 0, sp[2] - 0.9 if sp[2] < 29 else sp[2] - 0.8), "site": S, "r": 1.1, "focus_color": Color("4caf50"),
			"focus": func(): return null if st.taken else "CASH STACK",
			"actions": func():
				if st.taken:
					return []
				return [act("Grab cash stack", 2.4, func():
					if not R.add_loot("marked", st.value, randf() < 0.25, S.door, S):
						return
					st.taken = true
					st.mesh.visible = false
					S.vault_hit = true
					R.crime(S, "vault"), {"crime": true})],
		})
	S.lockboxes = []
	for lp in [[1.0, 25.4], [1.6, 25.4], [1.0, 26.6], [1.6, 26.6]]:
		var m := dyn(21.32, lp[0], lp[1], 0.3, 0.42, 0.55, Mats.m("lockbox"))
		var lb := {"mesh": m, "value": 0.0, "type": "jewelry", "open": false}
		S.lockboxes.append(lb)
		inter({
			"pos": Vector3(22.2, 0, lp[1]), "site": S, "r": 1.0, "focus_color": Color("cfd8dc"),
			"focus": func(): return null if lb.open else "LOCKBOX",
			"actions": func():
				if lb.open:
					return []
				var run := func():
					if not R.add_loot(lb.type, lb.value, false, S.door, S):
						return
					lb.open = true
					lb.mesh.material_override = Mats.m("counter")
					S.vault_hit = true
					R.crime(S, "vault")
				return [act("Snap lockbox", 1.4, run, {"crime": true})] if Game.tools.snap else [act("Pry lockbox open", 4.5, run, {"crime": true, "drill": true})],
		})
	R.make_camera(S, Vector3(13.55, 3.4, 9.45), Vector3(25, 0.8, 16))
	R.make_camera(S, Vector3(36.45, 3.4, 9.45), Vector3(22, 0.8, 16), true)
	R.make_camera(S, Vector3(36.6, 3.4, 21.4), Vector3(25, 0.6, 22.6))
	R.make_camera(S, Vector3(21.5, 3.4, 30.5), Vector3(26, 0.3, 25), true)
	S.on_reset = func():
		S.safe_loot = float(randi_range(12000, 20000))
		S.safe_open = false
		S.safe_door.rotation.y = 0.0
		for d in S.drawers:
			d.taken = false
			d.value = float(randi_range(2500, 4500))
			d.dye = randf() < 0.5
			d.mesh.visible = true
		for s in S.stacks:
			s.taken = false
			s.value = float(randi_range(15000, 24000))
			s.mesh.visible = true
		for l in S.lockboxes:
			l.open = false
			l.type = "jewelry" if randf() < 0.5 else "marked"
			l.value = float(randi_range(4000, 10000))
			l.mesh.material_override = Mats.m("lockbox")
		var g1 := spawn(S, "guard", 15.6, 11.6, {"yaw": PI * 0.75, "hp": 70.0})
		var g2 := spawn(S, "guard", 34.4, 11.6, {"yaw": -PI * 0.75, "hp": 70.0})
		g1.has_code = randf() < 0.5
		g2.has_key = true
		for x in [17.0, 23.0, 29.0]:
			var t := spawn(S, "teller", x, 18.9, {"yaw": PI})
			if x == 29.0:
				t.has_key = true
		spawn(S, "civilian", 20, 12.6)
		spawn(S, "civilian", 26, 14.6)
		spawn(S, "civilian", 30.5, 13)

func add_delivery() -> void:
	var S: Dictionary = R.vault.site
	var m := dyn(25, 0, 25.4, 0.8, 0.5, 0.6, Mats.m("cash"), S.group)
	var st := {"taken": false, "value": float(randi_range(25000, 35000))}
	inter({
		"pos": Vector3(25, 0, 24.6), "site": S, "r": 1.1, "focus_color": Color("4caf50"),
		"focus": func(): return null if st.taken else "CASH DELIVERY",
		"actions": func():
			if st.taken:
				return []
			return [act("Grab delivery case", 2.0, func():
				if not R.add_loot("marked", st.value, false, S.door, S):
					return
				st.taken = true
				m.visible = false
				S.vault_hit = true
				R.crime(S, "vault"), {"crime": true})],
	})

func drop_case(pos: Vector3) -> void:
	var m := dyn(pos.x + 0.5, 0.15, pos.z, 0.6, 0.4, 0.4, Mats.m("cash"), Game.world)
	var st := {"taken": false, "value": float(randi_range(14000, 20000))}
	inter({
		"pos": Vector3(pos.x + 0.5, 0, pos.z), "r": 1.3, "focus_color": Color("4caf50"),
		"focus": func(): return null if st.taken else "CASH CASE",
		"actions": func():
			if st.taken:
				return []
			return [act("Grab cash case", 1.5, func():
				if not R.add_loot("marked", st.value, false, null, R.vault.site):
					return
				st.taken = true
				m.visible = false
				if Game.wanted.stars < 2:
					Game.police.raise_stars(2, Game.player.global_position, "Armored truck robbery"), {"crime": true})],
	})

# ---------- support locations ----------
func build_fence() -> void:
	cur_group = null
	B.box(-72, 0.15, -15, 16, 0.03, 12, Mats.m("wood_planks"), {"layer": "ground", "shadow": false})
	storefront_x(-9, -80, -64, [[-73.5, -70.5]], col(0x7a2350))
	var pink := col(0xffc7d6)
	wall_x(-21, -80, -64, [], 4, null, 0.3, pink)
	wall_z(-80, -21, -9, [], 4, null, 0.3, pink)
	wall_z(-64, -21, -9, [], 4, null, 0.3, pink)
	B.box(-72, 0, -15.4, 6, 1.0, 0.8, Mats.m("wood_planks"))
	B.box(-72, 1.0, -15.4, 6, 0.04, 0.8, Mats.m("window_glass"), {"collide": false, "shadow": false})
	B.box(-78.5, 0, -15, 1, 1.8, 8, Mats.m("wood_planks"))
	add_building("fence", -80, -64, -21, -9)
	upper(-80, -64, -21, -9, 2, Mats.m("facade_stucco"), pink)
	sign_label("YASMANI'S PAWN", -72, 5.2, -8.55, Color("ff9ad5"), 1.4)
	B.box(-64.6, 0.15, -15, 0.8, 2.2, 10, Mats.m("wood_planks"))
	for y in [0.5, 1.1, 1.7]:
		var z := -19.5
		while z < -10.5:
			B.box(-64.9, y + 0.15, z, 0.4, 0.3, 0.4, Mats.m("paint_gloss"), {"color": col(PRODUCT[randi() % 9]), "collide": false, "shadow": false})
			z += 0.55
	lights(-80, -64, -21, -9)
	Game.main.spawn_char("fence", Vector3(-72, 0, -16.8), {"yaw": 0.0})
	inter({"pos": Vector3(-72, 0, -14.4), "r": 2.2, "focus": "FENCE", "focus_color": Color("ff9ad5"),
		"actions": func():
			if Game.wanted.stars > 0:
				return [act("Yasmani won't deal while you're wanted", 0.0, null, {"disabled": true})]
			return [act("Talk to Yasmani (fence & tools)", 0.0, func(): Game.shop_requested.emit())]})

func atm(x: float, z: float, yaw: float) -> void:
	B.box(x, 0, z, 0.8, 1.6, 0.5, Mats.m("paint_gloss"), {"color": col(0xef8a2b)})
	dyn(x + sin(yaw) * 0.26, 1.1, z + cos(yaw) * 0.26, 0.5 if absf(cos(yaw)) > 0.5 else 0.02, 0.35, 0.02 if absf(cos(yaw)) > 0.5 else 0.5, Mats.solid(Color("9fe8b0"), 0.3, 0.0, 1.2), Game.world)
	var p := Vector3(x + sin(yaw) * 0.9, 0, z + cos(yaw) * 0.9)
	inter({"pos": p, "r": 1.5, "focus": "ATM", "focus_color": Color("9fe8b0"),
		"actions": func():
			if Game.money.cash > 0:
				return [act("Deposit %s cash" % U.money(Game.money.cash), 1.0, func():
					Game.notify("Deposited %s - it's safe in the bank" % U.money(Game.money.cash), "good")
					Game.money.bank += Game.money.cash
					Game.money.cash = 0.0
					Sfx.play("cash"))]
			return [act("No cash on hand to deposit", 0.0, null, {"disabled": true})]})

func build_safehouse() -> void:
	B.box(74, 0.15, -16.5, 16, 0.03, 15, Mats.m("wood_planks"), {"layer": "ground", "shadow": false})
	var mint := col(0xbfeee0)
	wall_x(-9, 66, 82, [[72.5, 75.5]], 4, null, 0.3, mint)
	wall_x(-24, 66, 82, [], 4, null, 0.3, mint)
	wall_z(66, -24, -9, [], 4, null, 0.3, mint)
	wall_z(82, -24, -9, [], 4, null, 0.3, mint)
	add_building("safehouse", 66, 82, -24, -9)
	upper(66, 82, -24, -9, 3, Mats.m("facade_stucco"), mint)
	sign_label("SAFEHOUSE", 74, 5.2, -8.55, Color.WHITE, 1.2)
	B.box(79.5, 0, -21.5, 3, 0.6, 2, Mats.m("paint"), {"color": col(0x3d5a80)})
	B.box(67.2, 0, -21.5, 1, 2.2, 3, Mats.m("wood_planks"), {"color": col(0xd9c2a8)})
	B.box(72, 0.15, -14, 3.4, 0.5, 1.1, Mats.m("paint"), {"color": col(0x3d5a80)})
	B.box(72, 0.65, -14.5, 3.4, 0.6, 0.25, Mats.m("paint"), {"color": col(0x3d5a80), "collide": false})
	B.box(72, 0.15, -18.5, 1.8, 0.55, 0.5, Mats.m("paint"), {"color": col(0x2a2d31)})
	B.box(72, 0.7, -18.5, 1.6, 0.9, 0.08, Mats.m("paint_gloss"), {"color": col(0x101215), "collide": false})
	B.box(72, 0.17, -16.2, 4, 0.02, 3, Mats.m("carpet"), {"collide": false, "shadow": false})
	B.box(80.8, 0.15, -12, 1.2, 0.95, 4, Mats.m("marble"))
	lights(66, 82, -24, -9, 4)
	inter({"pos": Vector3(68.6, 0, -21.5), "r": 1.8, "focus": "WARDROBE",
		"actions": func(): return [act("Change outfit", 1.5, func(): Game.main.player_ctl.change_outfit("wardrobe"))]})
	inter({"pos": Vector3(79.5, 0, -19.6), "r": 1.8, "focus": "BED",
		"actions": func():
			if Game.wanted.stars > 0:
				return [act("Can't rest while wanted", 0.0, null, {"disabled": true})]
			return [act("Rest (heal + pass time)", 2.0, func():
				Game.player.hp = 100.0
				Game.heat.face = maxf(0.0, Game.heat.face - 120.0)
				Game.heat.outfit_t = maxf(0.0, Game.heat.outfit_t - 120.0)
				if Game.heat.outfit_t <= 0.0:
					Game.heat.outfit = -1
				Game.notify("Rested. Health restored, heat cooled off.", "good"))]})

func build_garage() -> void:
	B.box(-27, 0.15, 25, 26, 0.03, 26, Mats.m("concrete"), {"layer": "ground", "shadow": false, "color": col(0x9a9a96)})
	var c := col(0xd9d6cf)
	var conc := Mats.m("concrete")
	wall_x(12, -40, -14, [[-30, -22]], 4, conc, 0.3, c)
	wall_x(38, -40, -14, [], 4, conc, 0.3, c)
	wall_z(-40, 12, 38, [], 4, conc, 0.3, c)
	wall_z(-14, 12, 38, [[24, 31]], 4, conc, 0.3, c)
	for x in [-34.0, -27.0, -20.0]:
		for z in [19.0, 26.0, 33.0]:
			B.box(x, 0, z, 0.6, 4, 0.6, conc, {"color": col(0xcfcac2)})
	var x := -38.0
	while x < -15.0:
		for z in [15.5, 35.5]:
			B.box(x, 0.18, z, 0.12, 0.01, 4, Mats.m("line_white"), {"collide": false, "shadow": false})
		x += 3.2
	add_building("garage", -40, -14, 12, 38, true)
	for y in [4.0, 7.4, 10.8]:
		B.box(-27, y, 25, 26.3, 0.35, 26.3, conc, {"color": col(0xbdb9b2), "collide": y == 4.0})
		if y < 10.8:
			for px in [-34.0, -27.0, -20.0]:
				for pz in [19.0, 26.0, 33.0]:
					B.box(px, y + 0.35, pz, 0.6, 3.05, 0.6, conc, {"color": col(0xcfcac2), "collide": false})
		for pc in [[-40, 12], [-14, 12], [-40, 38], [-14, 38]]:
			B.box(pc[0], y + 0.35, pc[1], 0.6, 3.05 if y < 10.8 else 1.0, 0.6, conc, {"color": col(0xbfbab2), "collide": false})
		B.box(-27, y + 0.35, 12, 26.3, 1.0, 0.25, conc, {"color": c, "collide": false})
		B.box(-27, y + 0.35, 38, 26.3, 1.0, 0.25, conc, {"color": c, "collide": false})
		B.box(-40, y + 0.35, 25, 0.25, 1.0, 26.3, conc, {"color": c, "collide": false})
		B.box(-14, y + 0.35, 25, 0.25, 1.0, 26.3, conc, {"color": c, "collide": false})
		for k in 3:
			var px := -37.0 + k * 9.0 + randf() * 2.0
			var pz := 16.0 if k % 2 else 34.0
			B.box(px, y + 0.35, pz, 1.9, 0.75, 4.2, Mats.m("paint_gloss"), {"color": [col(0xc0392b), col(0x2471a3), col(0xe0e0e0), col(0x2b2b2b)][(k + int(y)) % 4], "collide": false})
			B.box(px, y + 1.1, pz - 0.2, 1.6, 0.55, 2.1, Mats.m("paint_gloss"), {"color": col(0x1c2733), "collide": false})
	B.add_col(Vector3(-40, 4, 12), Vector3(-14, 11.5, 38))
	sign_label("PARKING  P", -26, 5.0, 11.55, Color("7fb2ff"), 1.4)
	Game.garage_bounds = Rect2(-40, 12, 26, 26)
	interior_light(-40, -14, 12, 38)

func build_spray() -> void:
	B.box(70, 0.15, 18, 12, 0.03, 12, Mats.m("concrete"), {"layer": "ground", "shadow": false})
	var pk := col(0xffd9ec)
	wall_z(64, 12, 24, [], 4, null, 0.3, pk)
	wall_z(76, 12, 24, [], 4, null, 0.3, pk)
	wall_x(24, 64, 76, [], 4, null, 0.3, pk)
	B.box(70, 3.6, 12, 12, 0.4, 0.3, Mats.m("paint"), {"color": col(0xff6fb5)})
	B.box(70, 4.0, 18, 12.3, 0.3, 12.3, Mats.m("roof_gravel"))
	add_building("spray", 64, 76, 12, 24)
	sign_label("PAY 'N' SPRAY", 70, 4.8, 11.55, Color("ff6fb5"), 1.2)
	var door := MeshInstance3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3(11.6, 2.4, 0.15)
	door.mesh = dm
	door.material_override = Mats.m("metal_brushed")
	door.position = Vector3(70, 4, 12.2)
	Game.world.add_child(door)
	R.spray.door = door
	R.spray.bounds = Rect2(65, 13, 10, 10.5)
	interior_light(64, 76, 12, 24)
	var z := MeshInstance3D.new()
	var zm := BoxMesh.new()
	zm.size = Vector3(9, 0.02, 9)
	z.mesh = zm
	z.material_override = Mats.m("zone")
	z.position = Vector3(70, 0.2, 18.5)
	Game.world.add_child(z)

## Ground-floor rooms of enterable buildings. Geometry inside them goes to the
## "interior" LOD layer / render layer, which only room lights and room probes affect.
const INTERIORS := [Rect2(12, -21, 16, 12), Rect2(-34, -23, 18, 14), Rect2(13, 9, 24, 22), Rect2(-80, -21, 16, 12),
	Rect2(66, -24, 16, 15), Rect2(-40, 12, 26, 26), Rect2(64, 12, 12, 12)]

func build() -> void:
	B.interior_rects = INTERIORS.duplicate()
	build_store()
	build_jewelry()
	build_bank()
	build_fence()
	build_safehouse()
	build_garage()
	build_spray()
	cur_group = null
	atm(34.5, -8.4, 0.0)
	atm(-61.5, -8.4, 0.0)
	atm(17, 8.4, PI)

func spawn_parked_cars() -> void:
	for pc in [[-36, 18.5, 0.0, 5], [-17.5, 33, PI, 1], [-37.8, -14, 0.0, 3], [39.1, 17, 0.0, 4], [30.1, -15.5, PI, 7]]:
		var car: Vehicle = Game.main.spawn_car("civ", Vector3(pc[0], 0, pc[1]), pc[2], {"color_idx": pc[3]})
		car.parked = true

func reset_all() -> void:
	for s in Game.sites:
		s.on_reset.call()
