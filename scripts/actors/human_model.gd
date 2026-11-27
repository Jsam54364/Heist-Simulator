class_name HumanModel
extends Node3D
## The visual person. Bodies, clothes, shoes, hair cards, eyes and gear come from CC0
## MakeHuman assets, fitted and rigged in Blender (tools/blender/make_mh_humans.py) into
## assets/models/human_m.glb / human_f.glb - one skeleton + every part mesh + all clips per
## gender - with textures in shared atlases (assets/characters/). An outfit is assembled
## at runtime into ONE skinned mesh with two surfaces (opaque atlas + alpha-tested hair),
## i.e. two draw calls per person; skin covered by clothing is dropped using the coverage
## bits stored in the body's vertex colours. Assembled meshes are cached per outfit.
## Driven by a shared AnimationTree:
##
##   stand  BlendSpace1D idle / walk / jog / sprint     (speed, clip speed matched to ground speed)
##   aim    BlendSpace2D aim_idle + 4-way aim walks     (local velocity) - strafing TPS locomotion
##   crouch BlendSpace1D crouch_idle / crouch_walk, crouch_aim, panic_run
##     -> "stance" Transition (0.2 s crossfades)
##   upper-body Blend2 (spine, arms, head) with aim pitch BlendSpace1D aim_down/aim_idle/aim_up
##     -> "mode" Transition: locomotion or a full-body pose (handsup, cower, kneel, tied, phone,
##        text, film, wave, work, drive (steer blendspace), sit, deaths, jump air) - 0.25 s blends
##   OneShots on top: fire + reload + hit (upper body only), punch, smash, dodge, jump
##        start/land, enter/exit car (full body), each with fade in/out.
##
## The tree is evaluated manually (Character drives advance()) so distant people animate
## at a fraction of the frame rate.

const LOOPS := ["idle", "walk", "jog", "sprint", "panic_run", "crouch_walk", "crouch_idle", "aim_idle", "aim_crouch", "aim_walk_f", "aim_jog_f",
	"aim_walk_l", "aim_walk_r", "aim_walk_b", "jump_air", "handsup", "cower", "kneel_hands", "tied", "phone", "text", "film", "wave",
	"work", "drive", "sit"]
const HANDS := ["hand.L", "fingers.L", "fingers_mid.L", "fingers_tip.L", "thumb.L", "thumb_tip.L",
	"hand.R", "fingers.R", "fingers_mid.R", "fingers_tip.R", "thumb.R", "thumb_tip.R", "weapon.R", "prop.R"]
const ARMS := ["shoulder.L", "upper_arm.L", "upper_arm_twist.L", "elbow.L", "forearm.L", "forearm_twist.L",
	"shoulder.R", "upper_arm.R", "upper_arm_twist.R", "elbow.R", "forearm.R", "forearm_twist.R"] + HANDS
const UPPER := ["spine", "chest", "neck", "head"] + ARMS
const MODES := ["loco", "handsup", "cower", "kneel", "tied", "phone", "text", "film", "wave", "work", "drive", "sit", "dead_b", "dead_f", "air"]
const STANCES := ["stand", "aim", "crouch", "crouch_aim", "panic"]
const SHOTS := ["fire", "reload", "hit", "punch", "smash", "dodge", "jump_start", "jump_land", "enter_car", "exit_car"]
const SKEL := "HumanRig/Skeleton3D"
const HAIR_SLOT := 7
const MATTE_FIXED := ["duty_belt"]

static var scenes := {}          # "m" / "f" -> PackedScene
static var catalogue := {}       # humans.json
static var part_mesh := {}       # "m:tee" -> ArrayMesh (as imported)
static var body_masks := {}      # "m" -> PackedInt32Array coverage bits per body vertex
static var skins := {}           # "m" -> Skin (shared by every part of that rig)
static var built := {}           # outfit key -> ArrayMesh (assembled)
static var props := {}
static var tree_root: AnimationNodeBlendTree
static var mat_op: ShaderMaterial
static var mat_hair: ShaderMaterial
static var ready_shared := false
## ground speed (m/s) each locomotion clip was captured at (measured from the mocap)
static var SPD := {"walk": 1.03, "jog": 2.98, "sprint": 5.0, "panic_run": 3.7, "crouch_walk": 0.63, "aim_walk_f": 1.03, "aim_jog_f": 2.98,
	"aim_walk_b": 0.8, "aim_walk_l": 0.8, "aim_walk_r": 0.8}

var inst: Node3D
var skel: Skeleton3D
var anim: AnimationPlayer
var tree: AnimationTree
var mesh_mi: MeshInstance3D
var meshes: Array = []
var gun: MeshInstance3D
var phone: MeshInstance3D
var bag: MeshInstance3D
var mask: MeshInstance3D         # legacy: masks are outfit parts now (see set_part)
var g := "m"
var female := false
var spec := {}
var parts: Array = []
var _mode := ""
var _stance := ""
var _last_pos := Vector3.INF
var _vel := Vector3.ZERO
var _speed := 0.0
var _death := "dead_b"
var _hit := 0.0

static func _shared() -> void:
	if ready_shared:
		return
	ready_shared = true
	catalogue = JSON.parse_string(FileAccess.get_file_as_string("res://assets/characters/humans.json"))
	mat_op = ShaderMaterial.new()
	mat_op.shader = load("res://assets/shaders/character.gdshader")
	mat_op.set_shader_parameter("albedo_atlas", load("res://assets/characters/atlas_albedo.webp"))
	mat_op.set_shader_parameter("normal_atlas", load("res://assets/characters/atlas_normal.webp"))
	mat_hair = ShaderMaterial.new()
	mat_hair.shader = load("res://assets/shaders/character_hair.gdshader")
	mat_hair.set_shader_parameter("hair_atlas", load("res://assets/characters/atlas_hair.webp"))
	var ps: Node = (load("res://assets/models/props.glb") as PackedScene).instantiate()
	for mi in ps.find_children("*", "MeshInstance3D", true, false):
		props[String(mi.name)] = mi.mesh
	ps.free()
	for gk in ["m", "f"]:
		scenes[gk] = load("res://assets/models/human_%s.glb" % gk)
		var probe: Node = scenes[gk].instantiate()
		# loop the cycles, and give each loop one extra frame so the last key blends back
		# into the first without a hitch (settings live on the shared Animation resources)
		var ap: AnimationPlayer = probe.get_node("AnimationPlayer")
		for n in ap.get_animation_list():
			var an: Animation = ap.get_animation(n)
			if n in LOOPS and an.loop_mode == Animation.LOOP_NONE:
				an.loop_mode = Animation.LOOP_LINEAR
				an.length += 1.0 / 30.0
		for mi in probe.find_children("*", "MeshInstance3D", true, false):
			part_mesh[gk + ":" + String(mi.name)] = mi.mesh
			if mi.skin and not skins.has(gk):
				skins[gk] = mi.skin
		# coverage bits of the body (4 bytes in the vertex colour)
		var cols: PackedColorArray = (part_mesh[gk + ":body"] as Mesh).surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		var bm := PackedInt32Array()
		bm.resize(cols.size())
		for i in cols.size():
			var c: Color = cols[i]
			bm[i] = roundi(c.r * 255.0) | (roundi(c.g * 255.0) << 8) | (roundi(c.b * 255.0) << 16) | (roundi(c.a * 255.0) << 24)
		body_masks[gk] = bm
		probe.free()
	for k in catalogue.get("m", {}).get("clip_speeds", {}):
		var v: float = catalogue.m.clip_speeds[k]
		if v > 0.2:
			SPD[k] = v
	tree_root = _build_tree()

## one skinned mesh (2 surfaces) for a gender + part list; cached
static func assemble(gk: String, plist: Array) -> ArrayMesh:
	var key := gk + "|" + ",".join(plist)
	if built.has(key):
		return built[key]
	var meta: Dictionary = catalogue[gk].parts
	var hide := 0
	for p in plist:
		var b: int = int(meta.get(p, {}).get("bit", -1))
		if b >= 0:
			hide |= 1 << b
	var out := ArrayMesh.new()
	for pass_hair in [false, true]:
		var acc := {}
		var always := ["body", "eyes"] if not plist.has("eyes_alt") else ["body"]
		for p in (always + plist if not pass_hair else plist):
			if not meta.has(p) or not part_mesh.has(gk + ":" + p):
				continue
			var m: Dictionary = meta[p]
			var slot: int = int(m.slot)
			if p in MATTE_FIXED:
				slot = 8
			if (slot == HAIR_SLOT) != pass_hair:
				continue
			_append(acc, (part_mesh[gk + ":" + p] as Mesh).surface_get_arrays(0), slot, float(m.get("lum", 0.5)), body_masks[gk] if p == "body" else PackedInt32Array(), hide, 1.0 if p in ["face_hair", "eyelashes"] else 0.0)
		if acc.is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		for k in acc:
			arr[k] = acc[k]
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.surface_set_material(out.get_surface_count() - 1, mat_hair if pass_hair else mat_op)
	if built.size() > 96:
		built.clear()
	built[key] = out
	return out

static func _append(acc: Dictionary, a: Array, slot: int, lum: float, mask: PackedInt32Array, hide: int, flag := 0.0) -> void:
	var base: int = acc[Mesh.ARRAY_VERTEX].size() if acc.has(Mesh.ARRAY_VERTEX) else 0
	var n: int = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	for k in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
		if a[k] == null:
			continue
		if not acc.has(k):
			acc[k] = a[k].duplicate()
		else:
			acc[k].append_array(a[k])
	var col := PackedColorArray()
	col.resize(n)
	col.fill(Color(slot / 255.0, lum, flag, 1.0))
	if acc.has(Mesh.ARRAY_COLOR):
		acc[Mesh.ARRAY_COLOR].append_array(col)
	else:
		acc[Mesh.ARRAY_COLOR] = col
	var src: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var idx: PackedInt32Array = acc.get(Mesh.ARRAY_INDEX, PackedInt32Array())
	var start := idx.size()
	idx.resize(start + src.size())
	var w := start
	var masked := not mask.is_empty() and hide != 0
	for t in range(0, src.size(), 3):
		var i0 := src[t]
		var i1 := src[t + 1]
		var i2 := src[t + 2]
		if masked and (mask[i0] & hide) != 0 and (mask[i1] & hide) != 0 and (mask[i2] & hide) != 0:
			continue
		idx[w] = i0 + base
		idx[w + 1] = i1 + base
		idx[w + 2] = i2 + base
		w += 3
	idx.resize(w)
	acc[Mesh.ARRAY_INDEX] = idx

static func _clip(n: String) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = n
	return a

static func _filter(node: AnimationNode, bones: Array) -> void:
	node.filter_enabled = true
	for b in bones:
		node.set_filter_path(NodePath(SKEL + ":" + b), true)

static func _build_tree() -> AnimationNodeBlendTree:
	var bt := AnimationNodeBlendTree.new()
	var x := 0.0
	# --- locomotion sets
	var stand := AnimationNodeBlendSpace1D.new()
	for p in [["idle", 0.0], ["walk", SPD.walk], ["jog", SPD.jog], ["sprint", SPD.sprint]]:
		stand.add_blend_point(_clip(p[0]), p[1], -1, p[0])
	stand.min_space = 0.0
	stand.max_space = 7.0
	bt.add_node("stand", stand, Vector2(0, 0))
	var aim := AnimationNodeBlendSpace2D.new()
	aim.add_blend_point(_clip("aim_idle"), Vector2(0, 0), -1, "aim_idle")
	aim.add_blend_point(_clip("aim_walk_f"), Vector2(0, SPD.aim_walk_f), -1, "aim_walk_f")
	aim.add_blend_point(_clip("aim_jog_f"), Vector2(0, SPD.aim_jog_f), -1, "aim_jog_f")
	aim.add_blend_point(_clip("aim_walk_b"), Vector2(0, -SPD.aim_walk_b), -1, "aim_walk_b")
	aim.add_blend_point(_clip("aim_walk_l"), Vector2(SPD.aim_walk_l, 0), -1, "aim_walk_l")
	aim.add_blend_point(_clip("aim_walk_r"), Vector2(-SPD.aim_walk_r, 0), -1, "aim_walk_r")
	aim.min_space = Vector2(-3.5, -3.5)
	aim.max_space = Vector2(3.5, 3.5)
	bt.add_node("aim", aim, Vector2(0, 150))
	var cr := AnimationNodeBlendSpace1D.new()
	cr.add_blend_point(_clip("crouch_idle"), 0.0, -1, "crouch_idle")
	cr.add_blend_point(_clip("crouch_walk"), SPD.crouch_walk, -1, "crouch_walk")
	cr.max_space = 2.0
	bt.add_node("crouch", cr, Vector2(0, 300))
	bt.add_node("crouch_aim", _clip("aim_crouch"), Vector2(0, 450))
	bt.add_node("panic", _clip("panic_run"), Vector2(0, 600))
	for n in ["stand", "aim", "crouch", "panic"]:
		var ts := AnimationNodeTimeScale.new()
		bt.add_node("ts_" + n, ts, Vector2(200, STANCES.find(n) * 150))
		bt.connect_node("ts_" + n, 0, n)
	var st := AnimationNodeTransition.new()
	for s in STANCES:
		st.add_input(s)
	st.xfade_time = 0.22
	bt.add_node("stance", st, Vector2(400, 200))
	bt.connect_node("stance", 0, "ts_stand")
	bt.connect_node("stance", 1, "ts_aim")
	bt.connect_node("stance", 2, "ts_crouch")
	bt.connect_node("stance", 3, "crouch_aim")
	bt.connect_node("stance", 4, "ts_panic")
	# --- aim pitch replaces the upper body while aiming
	var pitch := AnimationNodeBlendSpace1D.new()
	pitch.add_blend_point(_clip("aim_down"), -1.0, -1, "aim_down")
	pitch.add_blend_point(_clip("aim_idle"), 0.0, -1, "aim_idle")
	pitch.add_blend_point(_clip("aim_up"), 1.0, -1, "aim_up")
	pitch.min_space = -1.0
	pitch.max_space = 1.0
	bt.add_node("pitch", pitch, Vector2(400, 450))
	var up := AnimationNodeBlend2.new()
	_filter(up, UPPER)
	bt.add_node("upper", up, Vector2(600, 300))
	bt.connect_node("upper", 0, "stance")
	bt.connect_node("upper", 1, "pitch")
	# --- full-body modes
	var md := AnimationNodeTransition.new()
	for m in MODES:
		md.add_input(m)
	md.xfade_time = 0.25
	bt.add_node("mode", md, Vector2(900, 300))
	bt.connect_node("mode", 0, "upper")
	var clips := {"handsup": "handsup", "cower": "cower", "kneel": "kneel_hands", "tied": "tied", "phone": "phone", "text": "text",
		"film": "film", "wave": "wave", "work": "work", "sit": "sit", "dead_b": "death_back", "dead_f": "death_fwd", "air": "jump_air"}
	var i := 1
	for m in MODES.slice(1):
		if m == "drive":
			var dr := AnimationNodeBlendSpace1D.new()
			dr.add_blend_point(_clip("drive_r"), -1.0, -1, "drive_r")
			dr.add_blend_point(_clip("drive"), 0.0, -1, "drive")
			dr.add_blend_point(_clip("drive_l"), 1.0, -1, "drive_l")
			dr.min_space = -1.0
			dr.max_space = 1.0
			bt.add_node("m_drive", dr, Vector2(700, 600 + i * 60))
		else:
			bt.add_node("m_" + m, _clip(clips[m]), Vector2(700, 600 + i * 60))
		bt.connect_node("mode", i, "m_" + m)
		i += 1
	# --- one-shots
	var prev := "mode"
	var px := 1100.0
	for s in SHOTS:
		var os := AnimationNodeOneShot.new()
		os.fadein_time = 0.04 if s == "fire" else 0.12
		os.fadeout_time = 0.1 if s == "fire" else 0.18
		if s in ["fire", "reload", "hit"]:
			_filter(os, UPPER if s != "fire" else ARMS + ["chest", "neck", "head"])
		bt.add_node("os_" + s, os, Vector2(px, 300))
		var clip: String = s
		bt.add_node("c_" + s, _clip(clip), Vector2(px, 500))
		bt.connect_node("os_" + s, 0, prev)
		bt.connect_node("os_" + s, 1, "c_" + s)
		prev = "os_" + s
		px += 200.0
	bt.connect_node("output", 0, prev)
	return bt

## spec (Outfits.for_role): {g: "m"/"f", skin, skin_tint, parts: [...], top, bottom, shoes, hat,
## gear, hair: Color (alpha = tint strength; 0 keeps the texture's colours)}
func build(p_spec: Dictionary) -> void:
	_shared()
	spec = p_spec
	g = spec.get("g", "f" if spec.get("female", false) else "m")
	female = g == "f"
	parts = spec.get("parts", []).duplicate()
	inst = scenes[g].instantiate()
	add_child(inst)
	inst.scale = Vector3.ONE * float(catalogue[g].scale) * spec.get("size", 1.0)
	skel = inst.get_node(SKEL)
	anim = inst.get_node("AnimationPlayer")
	for c in skel.get_children():
		if c is MeshInstance3D:
			c.free()
	mesh_mi = MeshInstance3D.new()
	mesh_mi.name = "Person"
	mesh_mi.layers = 1 | 4
	skel.add_child(mesh_mi)
	mesh_mi.skin = skins[g]
	mesh_mi.skeleton = NodePath("..")
	meshes.append(mesh_mi)
	_rebuild()
	# props on the hand sockets
	# prop bones point their Y axis along the barrel / phone length (Blender bone
	# convention); the meshes are modelled barrel +Z / length +Y, so re-orient them
	gun = _attach("weapon.R", props.get("pistol"), Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)))
	phone = _attach("prop.R", props.get("phone"), Basis(Vector3.UP, PI))
	tree = AnimationTree.new()
	tree.tree_root = tree_root
	tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	inst.add_child(tree)
	tree.anim_player = tree.get_path_to(anim)
	tree.active = true
	_death = "dead_b" if randf() < 0.6 else "dead_f"
	tree.set("parameters/stand/blend_position", 0.0)

func _rebuild() -> void:
	mesh_mi.mesh = assemble(g, parts)
	apply_colors()

## show / hide an outfit part (e.g. the player's balaclava; it replaces the hair)
func set_part(p: String, on: bool) -> void:
	if on == (p in parts):
		return
	if on:
		parts.append(p)
		if p in ["mask", "helmet"]:
			for h in parts.duplicate():
				if String(h).begins_with("hair_"):
					parts.erase(h)
					spec["_hidden_hair"] = h
	else:
		parts.erase(p)
		if spec.has("_hidden_hair") and not ("mask" in parts or "helmet" in parts):
			parts.append(spec["_hidden_hair"])
			spec.erase("_hidden_hair")
	parts.sort()
	_rebuild()

func has_part(p: String) -> bool:
	return p in parts

func apply_colors() -> void:
	var m := mesh_mi
	m.set_instance_shader_parameter("skin_offset", spec.get("skin_offset", Vector2.ZERO))
	m.set_instance_shader_parameter("skin_tint", spec.get("skin_tint", Color.WHITE))
	for k in ["top", "bottom", "shoes", "hat", "gear"]:
		var c: Color = spec.get(k, Color(0, 0, 0, 0))
		m.set_instance_shader_parameter(("shoe" if k == "shoes" else k) + "_color", c)
	m.set_instance_shader_parameter("hair_color", spec.get("hair", Color(0, 0, 0, 0)))
	m.set_instance_shader_parameter("hit", _hit)

func set_color(key: String, c: Color) -> void:
	spec[key] = c
	apply_colors()

func flash(v: float) -> void:
	_hit = v
	mesh_mi.set_instance_shader_parameter("hit", v)

func set_shadow(on: bool) -> void:
	var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for m in meshes:
		m.cast_shadow = mode

func _attach(bone: String, mesh: Mesh, fix := Basis.IDENTITY) -> MeshInstance3D:
	if mesh == null:
		return null
	var ba := BoneAttachment3D.new()
	ba.bone_name = bone
	skel.add_child(ba)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.basis = fix
	mi.layers = 1 | 4
	mi.visible = false
	ba.add_child(mi)
	meshes.append(mi)
	return mi

## world-space muzzle of the held pistol (tracers / flashes start here)
func muzzle() -> Vector3:
	return gun.global_transform * Vector3(0, 0.055, 0.18)

## a duffel on the back (carried loot)
func add_bag() -> MeshInstance3D:
	var ba := BoneAttachment3D.new()
	ba.bone_name = "chest"
	skel.add_child(ba)
	bag = MeshInstance3D.new()
	bag.mesh = props.get("duffel")
	bag.position = Vector3(0, 0.05, -0.2)
	bag.rotation = Vector3(0.15, 0, 0.5)
	bag.visible = false
	bag.layers = 1 | 4
	ba.add_child(bag)
	meshes.append(bag)
	return bag

func shot(n: String) -> void:
	tree.set("parameters/os_%s/request" % n, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)

func shot_active(n: String) -> bool:
	return tree.get("parameters/os_%s/active" % n)

## Called by Character with the time since the last evaluation.
## mode: one of MODES (or "loco"), stance: one of STANCES.
func drive(dt: float, mode: String, stance: String, world_pos: Vector3, yaw: float, opts := {}) -> void:
	if dt <= 0.0:
		return
	# local velocity from movement (smoothed)
	if _last_pos != Vector3.INF:
		var v := (world_pos - _last_pos) / dt
		v.y = 0.0
		if v.length() > 12.0:
			v = Vector3.ZERO     # teleports
		_vel = _vel.lerp(v, minf(1.0, dt * 10.0))
	_last_pos = world_pos
	var sp: float = opts.get("speed", _vel.length())
	_speed = lerpf(_speed, sp, minf(1.0, dt * 8.0))
	if mode == "dead":
		mode = _death
	if mode != _mode:
		_mode = mode
		tree.set("parameters/mode/transition_request", mode)
	if stance != _stance:
		_stance = stance
		tree.set("parameters/stance/transition_request", stance)
	match stance:
		"stand":
			tree.set("parameters/stand/blend_position", minf(_speed, SPD.sprint))
			# play at the speed the feet actually travel: inside the captured range the blend
			# itself matches, outside it the clip is sped up / slowed down
			var nat := clampf(_speed, SPD.walk, SPD.sprint)
			tree.set("parameters/ts_stand/scale", clampf(_speed / nat, 0.6, 1.4) if _speed > 0.3 else 1.0)
		"aim", "crouch_aim":
			var f := Vector3(sin(yaw), 0, cos(yaw))
			var l := Vector3(cos(yaw), 0, -sin(yaw))
			var lv := Vector2(_vel.dot(l), _vel.dot(f))
			var asp := lv.length()
			var nat: float = SPD.aim_walk_f
			if lv.y > absf(lv.x):
				nat = clampf(asp, SPD.aim_walk_f, SPD.get("aim_jog_f", SPD.aim_walk_f))
			elif lv.y < -absf(lv.x):
				nat = SPD.aim_walk_b
			else:
				nat = SPD.aim_walk_l
			tree.set("parameters/aim/blend_position", lv.limit_length(maxf(nat, 0.01)) if asp > nat else lv)
			tree.set("parameters/ts_aim/scale", clampf(asp / nat, 0.6, 2.3) if asp > 0.3 else 1.0)
		"crouch":
			tree.set("parameters/crouch/blend_position", minf(_speed, SPD.crouch_walk))
			tree.set("parameters/ts_crouch/scale", clampf(_speed / SPD.crouch_walk, 0.6, 2.0) if _speed > SPD.crouch_walk else 1.0)
		"panic":
			tree.set("parameters/ts_panic/scale", clampf(_speed / SPD.panic_run, 0.7, 1.45))
	var aiming: bool = stance in ["aim", "crouch_aim"]
	tree.set("parameters/upper/blend_amount", 1.0 if aiming and mode == "loco" else 0.0)
	if aiming:
		tree.set("parameters/pitch/blend_position", opts.get("pitch", 0.0))
	if mode == "drive":
		tree.set("parameters/m_drive/blend_position", opts.get("steer", 0.0))
	if gun:
		gun.visible = opts.get("gun", false)
	if phone:
		phone.visible = mode in ["phone", "text", "film"]
	tree.advance(dt)
