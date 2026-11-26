class_name Character
extends CharacterBody3D
## Any person in the world (player, partner, NPCs, police). Movement is planar
## (floating motion mode at y = 0); the model is lifted to the ground height.

const ROLE_COLORS := {
	"player": Color("2f6fe0"), "partner": Color("8e5bd6"), "civilian": Color("b9b9b9"), "pedestrian": Color("a9b0b8"),
	"clerk": Color("f5f5f5"), "staff": Color("f5f5f5"), "teller": Color("e8e0c8"), "guard": Color("26324a"), "cop": Color("1b2f63"),
	"fence": Color("6d5a3c"), "truckguard": Color("3a4a3a"), "driver": Color("9aa3ad"),
}

var role := "civilian"
var yaw := 0.0
var hp := 60.0
var max_hp := 60.0
var state := "idle"
var pose := "stand"
var site = null
var home := Vector3.ZERO
var home_yaw := 0.0
var dead := false
var ko := false
var hidden := false
var in_car = null
var armed := false
var show_gun := false
var speed_now := 0.0
var walk_phase := 0.0
var noclip := false

# perception / AI memory
var fear := 0.0
var hero = null
var surrender := 0.0
var exposure := 0.0
var saw_face := false
var saw_crime := false
var saw_outfit := -1
var has_code := false
var has_key := false
var searched := false
var sees := false
var dist_p := 99.0
var cd := 0.0
var perc_t := 0.0
var last_aimed := -99.0
var path: Array = []
var path_t := 0.0
var path_target := Vector3.INF
var stuck := 0.0
var mem := {}

# model
var inner: Node3D
var body_mesh: MeshInstance3D
var arm_l: Node3D
var arm_r: Node3D
var arm_meshes: Array
var gun: MeshInstance3D
var mask_mesh: MeshInstance3D
var ranges := {}
var bag_mesh: MeshInstance3D

func setup(p_role: String, pos: Vector3, opts := {}) -> Character:
	role = p_role
	position = Vector3(pos.x, 0, pos.z)
	yaw = opts.get("yaw", 0.0)
	home = position
	home_yaw = yaw
	hp = opts.get("hp", 60.0)
	max_hp = hp
	site = opts.get("site", null)
	state = opts.get("state", "idle")
	armed = role in ["cop", "guard", "truckguard", "partner", "player"]
	return self

## LOD (set by main every 0.25 s from camera distance): 0 near, 1 mid (animate every
## 2nd frame, move without collision), 2 far (animate every 4th frame, small parts hidden).
var lod := 0
var far_move := false
var body_near: Mesh
var body_far: Mesh
var ranges_far: Dictionary
var meshes: Array = []
var _shadow_on := true
var _anim_acc := 0.0
var _anim_n := 0
var ai_acc := 0.0
var ai_n := 0

func set_lod(level: int, shadow: bool) -> void:
	if level != lod:
		var was := lod
		lod = level
		far_move = level >= 1 and role != "player"
		if (was == 0) != (level == 0):
			# beyond ~30 m: arms are baked into the body mesh (1 draw call per person)
			body_mesh.mesh = body_near if level == 0 else body_far
			for am in arm_meshes:
				am.visible = level == 0
	if shadow != _shadow_on:
		_shadow_on = shadow
		var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for m in meshes:
			m.cast_shadow = mode

func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	collision_layer = Game.L_CHAR
	collision_mask = Game.L_WORLD | Game.L_GLASS | Game.L_VEHICLE
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.32
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	add_child(cs)
	var color: Color = ROLE_COLORS.get(role, Color("aaaaaa"))
	if mem.has("color"):
		color = mem.color
	var leg: Color = Color("141a2a") if role in ["cop", "guard"] else [Color("3a3f47"), Color("2b3a55"), Color("4a4036"), Color("2f2f33")][randi() % 4]
	var m: Dictionary = CharModel.build(self, role, color, leg, CharModel.SKIN[randi() % CharModel.SKIN.size()])
	inner = m.inner
	body_mesh = m.body
	ranges = m.ranges
	body_near = body_mesh.mesh
	body_far = m.body_far
	ranges_far = m.ranges_far
	arm_l = m.arm_l
	arm_r = m.arm_r
	arm_meshes = m.arm_meshes
	gun = m.gun
	mask_mesh = m.mask
	rotation.y = yaw
	walk_phase = randf() * 6.0
	for mi in inner.find_children("*", "MeshInstance3D", true, false):
		mi.layers = 1 | 4   # world + "characters" render layer (room lights reach people)
		meshes.append(mi)

func set_outfit_color(c: Color) -> void:
	body_near = CharModel.recolor_mesh(body_near, ranges, c)
	body_far = CharModel.recolor_mesh(body_far, ranges_far, c)
	body_mesh.mesh = body_far if lod >= 1 else body_near
	for am in arm_meshes:
		CharModel.recolor(am, am.get_meta("ranges"), c)

func set_hidden(h: bool) -> void:
	hidden = h
	visible = not h
	collision_layer = 0 if h else Game.L_CHAR
	collision_mask = 0 if h else (Game.L_WORLD | Game.L_GLASS | Game.L_VEHICLE)

func teleport(p: Vector3) -> void:
	global_position = Vector3(p.x, 0, p.z)
	reset_physics_interpolation()
	path = []

# ---------- movement ----------
func step_toward(target: Vector3, speed: float, dt: float, face := true) -> float:
	var dx := target.x - global_position.x
	var dz := target.z - global_position.z
	var d := sqrt(dx * dx + dz * dz)
	if d < 0.05:
		speed_now = 0.0
		velocity = Vector3.ZERO
		return d
	var s := minf(speed, d / dt)
	if noclip or far_move:
		global_position += Vector3(dx / d, 0, dz / d) * s * dt
	else:
		velocity = Vector3(dx / d * s, 0, dz / d * s)
		move_and_slide()
		global_position.y = 0.0
	speed_now = speed
	if face:
		yaw += U.ang_diff(yaw, atan2(dx, dz)) * minf(1.0, dt * 10.0)
	return d

func move_dir(dir: Vector3, speed: float, dt: float) -> void:
	velocity = dir * speed
	move_and_slide()
	global_position.y = 0.0
	speed_now = speed if dir.length() > 0.01 else 0.0

func nav_move(target: Vector3, speed: float, dt: float, replan := 1.2) -> float:
	path_t -= dt
	if path.is_empty() or path_t <= 0.0 or U.d2(path_target, target) > 2.5:
		if Game.main.nav.take_budget():
			path = Game.main.nav.find_path(global_position, target)
			if path.is_empty():
				path = [Vector3(target.x, 0, target.z)]
			path_t = replan + randf() * 0.4
			path_target = target
		else:
			if path.is_empty():
				path = [Vector3(target.x, 0, target.z)]
			path_t = 0.05
	while path.size() > 1 and U.d2(path[0], global_position) < 0.45:
		path.pop_front()
	var before := global_position
	var rem := step_toward(path[0], speed, dt)
	if U.d2(before, global_position) < speed * dt * 0.2:
		stuck += dt
	else:
		stuck = 0.0
	if stuck > 0.8:
		path_t = 0.0
		stuck = 0.0
	return rem if path.size() == 1 else 99.0

func face_to(p: Vector3, dt: float, rate := 10.0) -> void:
	yaw += U.ang_diff(yaw, U.ang_to(global_position, p)) * minf(1.0, dt * rate)

func can_see(target: Vector3, rng := 25.0, fov_cos := 0.2, eye := 1.6, th := 1.3) -> bool:
	var d := U.d2(global_position, target)
	if d > rng:
		return false
	if d > 2.5:
		var f := U.fwd(yaw)
		if ((target.x - global_position.x) * f.x + (target.z - global_position.z) * f.z) / d < fov_cos:
			return false
	return Game.main.los(global_position + Vector3(0, eye, 0), Vector3(target.x, th, target.z))

func damage(dmg: float, src = null) -> void:
	if dead:
		return
	hp -= dmg
	if hp <= 0.0:
		hp = 0.0
		dead = true
		state = "dead"
		collision_layer = 0
		Game.main.on_char_down(self, src)

func knock_out() -> void:
	ko = true
	state = "ko"
	collision_layer = 0

# ---------- animation ----------
func _process(dt: float) -> void:
	if hidden or not visible:
		return
	if lod > 0:
		_anim_acc += dt
		_anim_n += 1
		if _anim_n < (2 if lod == 1 else 4):
			return
		dt = _anim_acc
		_anim_acc = 0.0
		_anim_n = 0
	rotation.y = yaw
	var target_y := Game.ground_y(global_position.x, global_position.z)
	var al := 0.0
	var ar := 0.0
	var y := 0.0
	var rx := 0.0
	var moving := speed_now > 0.3
	if moving:
		walk_phase += dt * (13.0 if speed_now > 4.0 else 8.0)
	var sw := sin(walk_phase) * (0.9 if speed_now > 4.0 else 0.5) if moving else 0.0
	var p := "down" if (dead or ko) else pose
	match p:
		"handsup":
			al = PI; ar = PI
		"cower":
			al = PI * 0.85; ar = PI * 0.85; y = -0.45
		"kneel":
			al = PI; ar = PI; y = -0.45
		"aim":
			ar = -PI / 2; al = -PI / 2.4
		"down":
			rx = -PI / 2; y = 0.18
		"work":
			walk_phase += dt * 4.0
			al = -0.9 + sin(walk_phase * 2) * 0.2
			ar = -0.9 - sin(walk_phase * 2) * 0.2
		_:
			al = sw; ar = -sw
	var k := minf(1.0, dt * 14.0)
	arm_l.rotation.x = lerpf(arm_l.rotation.x, al, k)
	arm_r.rotation.x = lerpf(arm_r.rotation.x, ar, k)
	var bob := absf(sin(walk_phase)) * 0.05 if moving else 0.0
	inner.position.y = lerpf(inner.position.y, target_y + y + bob, minf(1.0, dt * 12.0))
	inner.rotation.x = lerpf(inner.rotation.x, rx, minf(1.0, dt * 10.0))
	inner.position.z = 0.9 if rx != 0.0 else 0.0
	gun.visible = not dead and not ko and (pose == "aim" or (armed and show_gun))
