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
var in_car = null:
	set(v):
		if v == in_car:
			return
		_leave_seat()
		in_car = v
		if v != null:
			_take_seat()
var seat := -1             # index in in_car.occupants (0 = driver)
var crouching := false
var aim_pitch := 0.0       # -1 (down) .. 1 (up), used while aiming
var air_y := 0.0           # jump height above the ground (visual; movement stays planar)
var air_v := 0.0
var _jump_wait := -1.0
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
var model: HumanModel
var gun: MeshInstance3D
var mask_mesh: MeshInstance3D
var bag_mesh: MeshInstance3D
var look := {}

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
	if shadow != _shadow_on:
		_shadow_on = shadow
		model.set_shadow(shadow)

func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	collision_layer = Game.L_CHAR
	collision_mask = Game.L_WORLD | Game.L_GLASS | Game.L_VEHICLE | Game.L_SHORE
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.32
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	add_child(cs)
	var o := {"color": mem.get("color", Color(0, 0, 0, 0)), "swat": mem.get("swat", false)}
	if role == "player":
		o.top_part = Game.OUTFITS[Game.outfit].get("part", "tee")
	if mem.has("female"):
		o.female = mem.female
	look = Outfits.for_role(role, o)
	model = HumanModel.new()
	model.name = "Model"
	add_child(model)
	model.build(look)
	inner = model
	gun = model.gun
	mask_mesh = null
	rotation.y = yaw
	walk_phase = randf() * 6.0

func set_outfit_color(c: Color) -> void:
	model.set_color("top", c)

## jump: a short anticipation (jump_start one-shot) then lift-off; landing plays jump_land
func jump(v := 4.3) -> void:
	if air_y > 0.0 or _jump_wait >= 0.0 or dead or ko or hidden:
		return
	_jump_wait = 0.09
	model.shot("jump_start")

func airborne() -> bool:
	return air_y > 0.0 or _jump_wait >= 0.0

func _update_air(dt: float) -> void:
	if _jump_wait >= 0.0:
		_jump_wait -= dt
		if _jump_wait < 0.0:
			air_v = 4.3
			air_y = 0.001
	if air_y > 0.0:
		air_v -= 13.0 * dt
		air_y += air_v * dt
		if air_y <= 0.0:
			air_y = 0.0
			air_v = 0.0
			model.shot("jump_land")

## seats: 0 driver, 1 front passenger, 2-3 rear. Seated people stay visible, posed in the car.
func _take_seat() -> void:
	var car = in_car
	if not ("occupants" in car):
		return
	var want := 0
	if role == "player":
		var cur = car.occupants[0]
		if cur != null and is_instance_valid(cur) and cur != self:
			cur.seat = -1
			car.occupants[0] = null
			for j in range(1, car.occupants.size()):
				if car.occupants[j] == null:
					car.occupants[j] = cur
					cur.seat = j
					break
	elif car.driver == "player" or car == Game.player_car:
		want = 1
	for i in range(want, car.occupants.size()):
		if car.occupants[i] == null or not is_instance_valid(car.occupants[i]):
			car.occupants[i] = self
			seat = i
			return
	seat = -1

func _leave_seat() -> void:
	if in_car != null and is_instance_valid(in_car) and seat >= 0 and "occupants" in in_car and seat < in_car.occupants.size():
		if in_car.occupants[seat] == self:
			in_car.occupants[seat] = null
	seat = -1

func riding() -> bool:
	return hidden and in_car != null and is_instance_valid(in_car) and seat >= 0 and not in_car.removed

func set_hidden(h: bool) -> void:
	hidden = h
	visible = not h or riding()
	collision_layer = 0 if h else Game.L_CHAR
	collision_mask = 0 if h else (Game.L_WORLD | Game.L_GLASS | Game.L_VEHICLE | Game.L_SHORE)

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
	if model and not hidden:
		model.shot("hit")
		_flash = 1.0
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
var _flash := 0.0

func _process(dt: float) -> void:
	var ride := riding()
	if (hidden and not ride) or (not visible and not ride):
		return
	if ride and not visible:
		visible = true
	if lod > 0:
		_anim_acc += dt
		_anim_n += 1
		if _anim_n < (2 if lod == 1 else 4):
			return
		dt = _anim_acc
		_anim_acc = 0.0
		_anim_n = 0
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - dt * 5.0)
		model.flash(_flash * 0.6)
	_update_air(dt)
	var mode := "loco"
	var stance := "stand"
	var opts := {"gun": false}
	if ride:
		var car = in_car
		var st: Transform3D = car.seat_transform(seat)
		inner.global_transform = car.get_global_transform_interpolated() * st
		mode = "drive" if seat == 0 else "sit"
		opts.steer = -clampf(car.steer / 0.6, -1.0, 1.0)
		opts.speed = 0.0
		model.drive(dt, mode, stance, inner.global_position, yaw, opts)
		return
	rotation.y = yaw
	inner.position = Vector3(0, Game.ground_y(global_position.x, global_position.z) + air_y, 0)
	inner.rotation = Vector3.ZERO
	if dead or ko:
		mode = "dead"
	elif air_y > 0.18:
		mode = "air"
	else:
		match pose:
			"handsup", "cower", "phone", "film", "wave", "work", "text":
				mode = pose
			"kneel":
				mode = "tied" if mem.get("tied", false) else "kneel"
			"aim":
				stance = "crouch_aim" if crouching else "aim"
				opts.pitch = aim_pitch
			_:
				if crouching:
					stance = "crouch"
				elif speed_now > 4.4 and state == "flee":
					stance = "panic"
		if mode == "phone" and mem.get("texter", false):
			mode = "text"
	opts.gun = not dead and not ko and (pose == "aim" or (armed and show_gun))
	model.drive(dt, mode, stance, global_position, yaw, opts)
