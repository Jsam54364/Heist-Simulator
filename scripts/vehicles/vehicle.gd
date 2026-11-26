class_name Vehicle
extends RigidBody3D
## Raycast-suspension car: four spring/damper wheels, tyre grip with a friction
## circle (so you can drift and spin the wheels), anti-roll bars, drag and
## downforce. Real rigid-body collisions with walls and other cars.
## Model faces +Z; yaw convention matches U.fwd().

const SPECS := {
	"sedan": {"L": 4.6, "W": 1.9, "mass": 1250.0, "max_speed": 31.0, "accel": 8.5, "brake": 11.0, "grip": 1.45, "steer_max": 0.6, "drag": 0.0011, "wb": 2.7, "max_rev": 9.0, "awd": false},
	"coupe": {"L": 4.4, "W": 1.95, "mass": 1180.0, "max_speed": 42.0, "accel": 12.0, "brake": 12.5, "grip": 1.7, "steer_max": 0.58, "drag": 0.0008, "wb": 2.6, "max_rev": 9.0, "awd": false},
	"suv": {"L": 4.8, "W": 2.05, "mass": 1700.0, "max_speed": 29.0, "accel": 7.5, "brake": 10.0, "grip": 1.25, "steer_max": 0.55, "drag": 0.0015, "wb": 2.9, "max_rev": 8.0, "awd": true},
	"pickup": {"L": 5.2, "W": 2.05, "mass": 1800.0, "max_speed": 30.0, "accel": 8.0, "brake": 10.0, "grip": 1.25, "steer_max": 0.55, "drag": 0.0014, "wb": 3.2, "max_rev": 8.0, "awd": false},
	"taxi": {"L": 4.6, "W": 1.9, "mass": 1300.0, "max_speed": 30.0, "accel": 8.2, "brake": 11.0, "grip": 1.4, "steer_max": 0.6, "drag": 0.0011, "wb": 2.7, "max_rev": 9.0, "awd": false},
	"police": {"L": 4.8, "W": 1.95, "mass": 1400.0, "max_speed": 38.0, "accel": 11.0, "brake": 12.0, "grip": 1.6, "steer_max": 0.58, "drag": 0.0009, "wb": 2.8, "max_rev": 10.0, "awd": true},
	"truck": {"L": 6.4, "W": 2.4, "mass": 5200.0, "max_speed": 19.0, "accel": 4.5, "brake": 8.0, "grip": 1.1, "steer_max": 0.5, "drag": 0.002, "wb": 3.8, "max_rev": 6.0, "awd": true},
}
const CIV := ["sedan", "sedan", "coupe", "suv", "pickup", "taxi"]
const WHEEL_R := 0.36
const REST := 0.45
const MOUNT_Y := 0.75

static var next_id := 1

var kind := "sedan"
var spec: Dictionary
var car_id := 0
var color_idx := 0
var L := 4.6
var W := 1.9

var throttle := 0.0
var steer_in := 0.0
var handbrake := false
var steer := 0.0
var wheels: Array = []
var driver = null          # "player" or null
var npc_driver = null      # Character driving (traffic)
var ai := {}
var trunk: Array = []
var personal := false
var siren := false
var parked := false
var removed := false
var gear := 1
var rpm := 0.0
var slip := 0.0
var braking := false
var hit_cd := 0.0
var stuck_t := 0.0
var reverse_t := 0.0
var prev_vel := Vector3.ZERO
var spring_k := 0.0
var damp_c := 0.0

var body_node: Node3D
var paint_mat: StandardMaterial3D
var body_mi: MeshInstance3D
var _brake_lit := -1
var bar_red: MeshInstance3D
var bar_blue: MeshInstance3D
var skid_last := [null, null]

func setup(p_kind: String, pos: Vector3, p_yaw: float, opts := {}) -> Vehicle:
	if p_kind == "civ":
		p_kind = CIV[randi() % CIV.size()]
	kind = p_kind
	spec = SPECS[kind]
	L = spec.L
	W = spec.W
	car_id = next_id
	next_id += 1
	color_idx = opts.get("color_idx", randi() % Game.CAR_COLORS.size())
	personal = opts.get("personal", false)
	if kind == "taxi":
		color_idx = 4
	position = Vector3(pos.x, 0.05, pos.z)
	rotation.y = p_yaw
	return self

func _ready() -> void:
	mass = spec.mass
	collision_layer = Game.L_VEHICLE
	collision_mask = Game.L_WORLD | Game.L_GLASS | Game.L_VEHICLE | Game.L_GROUND
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.5, 0)
	angular_damp = 0.8
	linear_damp = 0.02
	can_sleep = true
	var pm := PhysicsMaterial.new()
	pm.friction = 0.35
	pm.bounce = 0.05
	physics_material_override = pm
	var shape_h := 2.3 if kind == "truck" else 0.7
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(W, shape_h, L * 0.96)
	cs.shape = bs
	cs.position = Vector3(0, 0.58 + shape_h * 0.5, 0)
	add_child(cs)
	if kind != "truck":
		var cs2 := CollisionShape3D.new()
		var bs2 := BoxShape3D.new()
		bs2.size = Vector3(W - 0.3, 0.45, L * 0.45)
		cs2.shape = bs2
		cs2.position = Vector3(0, 1.48 if kind in ["suv", "pickup"] else 1.2, -0.25)
		add_child(cs2)
	var w_load := mass * 9.8 / 4.0
	spring_k = w_load / 0.11
	damp_c = 2.0 * 0.38 * sqrt(spring_k * mass / 4.0)
	CarModel.build(self)
	for w in wheels:
		var ray := RayCast3D.new()
		ray.position = Vector3(w.mount.x, MOUNT_Y, w.mount.z)
		ray.target_position = Vector3(0, -(REST + WHEEL_R + 0.25), 0)
		ray.collision_mask = Game.L_GROUND | Game.L_WORLD
		ray.add_exception(self)
		add_child(ray)
		w.ray = ray

func yaw() -> float:
	var z := global_basis.z
	return atan2(z.x, z.z)

func fwd_dir() -> Vector3:
	return global_basis.z

func speed() -> float:
	return linear_velocity.dot(global_basis.z)

func set_speed(v: float) -> void:
	linear_velocity = global_basis.z * v

func set_color(idx: int) -> void:
	color_idx = idx
	if paint_mat and kind not in ["police", "truck"]:
		paint_mat.albedo_color = Game.CAR_COLORS[idx]

func place(pos: Vector3, p_yaw: float) -> void:
	global_transform = Transform3D(Basis(Vector3.UP, p_yaw), Vector3(pos.x, 0.05, pos.z))
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	reset_physics_interpolation()

## LOD: far traffic rides its lane kinematically ("rail"), sleeping/parked cars skip
## the suspension script entirely, far cars drop wheel animation and shadows.
var rail := false
var lod_far := false
var _shadow_on := true

func set_rail(on: bool, speed := 0.0) -> void:
	if on == rail:
		return
	rail = on
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = on
	if not on:
		linear_velocity = fwd_dir() * speed
		angular_velocity = Vector3.ZERO

func set_lod(far: bool, shadow: bool) -> void:
	if far != lod_far:
		lod_far = far
		for w in wheels:
			w.pivot.visible = not far
	if shadow != _shadow_on:
		_shadow_on = shadow
		var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for m in find_children("*", "MeshInstance3D", true, false):
			m.cast_shadow = mode

func _physics_process(dt: float) -> void:
	if removed or freeze:
		return
	if sleeping:
		if absf(throttle) > 0.01 or absf(steer_in) > 0.01:
			sleeping = false
		else:
			return
	var b := global_basis
	var up := b.y
	var fwd := b.z
	var v_body := linear_velocity.dot(fwd)
	var sp := absf(v_body)
	# wake when controlled
	if absf(throttle) > 0.01 or absf(steer_in) > 0.01:
		sleeping = false
	# steering, gentler at speed
	var max_steer: float = spec.steer_max * (1.0 - minf(0.72, sp / 46.0))
	steer = move_toward(steer, clampf(steer_in, -1, 1) * max_steer, dt * 3.2)
	braking = handbrake
	var engine_f: float = spec.accel * mass
	var brake_f: float = spec.brake * mass
	var driven := 4 if spec.awd else 2
	var com := global_position + b * center_of_mass
	var grounded := 0
	var max_slip := 0.0
	var comps := [0.0, 0.0, 0.0, 0.0]
	for i in wheels.size():
		var w: Dictionary = wheels[i]
		var ray: RayCast3D = w.ray
		w.grounded = ray.is_colliding()
		if not w.grounded:
			w.comp = 0.0
			w.prev_comp = 0.0
			w.len = REST
			continue
		grounded += 1
		var hit := ray.get_collision_point()
		var n := ray.get_collision_normal()
		var dist := ray.global_position.distance_to(hit)
		var spring_len := clampf(dist - WHEEL_R, 0.0, REST)
		w.len = spring_len
		var comp := REST - spring_len
		var comp_vel: float = (comp - w.prev_comp) / dt
		w.prev_comp = comp
		w.comp = comp
		comps[i] = comp
		var fz := maxf(0.0, spring_k * comp + damp_c * comp_vel)
		if dist - WHEEL_R < 0.0:
			fz += (WHEEL_R - dist) * spring_k * 3.0
		apply_force(up * fz, hit - global_position)
		# tyre frame
		var wf: Vector3 = b * (Vector3(-sin(steer), 0, cos(steer)) if w.front else Vector3(0, 0, 1))
		wf = (wf - n * wf.dot(n)).normalized()
		var wr := wf.cross(n)
		var vp := linear_velocity + angular_velocity.cross(hit - com)
		var v_long := vp.dot(wf)
		var v_lat := vp.dot(wr)
		var rear: bool = not w.front
		var mw := mass / 4.0
		var mu: float = spec.grip * (0.32 if (rear and handbrake) else 1.0)
		var f_lat := -v_lat * mw / dt * 0.55
		var f_long := 0.0
		var is_driven: bool = spec.awd or rear
		if throttle > 0.02:
			if v_body < -0.6:
				f_long += -signf(v_long) * minf(brake_f / 4.0 * throttle, mw * absf(v_long) / dt)
				braking = true
			elif is_driven:
				f_long += throttle * engine_f / driven * maxf(0.0, 1.0 - pow(v_body / spec.max_speed, 2))
		elif throttle < -0.02:
			if v_body > 0.6:
				f_long += -signf(v_long) * minf(brake_f / 4.0 * -throttle, mw * absf(v_long) / dt)
				braking = true
			elif is_driven and v_body > -spec.max_rev:
				f_long += throttle * engine_f * 0.55 / driven
		var roll_res := 0.12 if absf(throttle) > 0.02 else 0.45
		f_long += -v_long * mw * roll_res
		if rear and handbrake:
			f_long += -signf(v_long) * minf(mw * 6.0, mw * absf(v_long) / dt)
		var fmax := mu * fz
		var ft := Vector2(f_long, f_lat)
		if ft.length() > fmax:
			max_slip = maxf(max_slip, absf(v_lat) + (ft.length() - fmax) / maxf(fmax, 1.0) * 2.0)
			ft = ft.normalized() * fmax
		apply_force(wf * ft.x + wr * ft.y, hit + up * 0.35 - global_position)
	# anti-roll bars
	for axle in [[0, 1], [2, 3]]:
		var d: float = (comps[axle[0]] - comps[axle[1]]) * spring_k * 0.9
		if wheels[axle[0]].grounded:
			apply_force(up * d, wheels[axle[0]].ray.global_position - global_position)
		if wheels[axle[1]].grounded:
			apply_force(-up * d, wheels[axle[1]].ray.global_position - global_position)
	# drag + downforce
	var v := linear_velocity
	apply_central_force(-v * v.length() * spec.drag * mass)
	if grounded > 0:
		apply_central_force(-up * v_body * v_body * mass * 0.004)
	# keep upright-ish when flipped and slow
	if up.y < 0.3 and sp < 2.0:
		apply_torque(up.cross(Vector3.UP) * mass * 6.0)
	slip = max_slip
	if throttle > 0.9 and sp < 6.0 and driver == "player" and spec.accel > 9.0:
		slip = maxf(slip, 2.5)
	# impacts
	hit_cd -= dt
	var dv := (linear_velocity - prev_vel).length()
	if dv > 4.0 and hit_cd <= 0.0:
		hit_cd = 0.4
		Game.main.on_vehicle_impact(self, dv)
	prev_vel = linear_velocity
	# gearbox (sound/HUD)
	var frac: float = sp / spec.max_speed
	var gs := [0.0, 0.16, 0.34, 0.54, 0.76, 1.05]
	var g := 1
	while g < 5 and frac > gs[g]:
		g += 1
	gear = 0 if v_body < -0.5 else g
	rpm = clampf((frac - gs[g - 1]) / (gs[g] - gs[g - 1]), 0.0, 1.0)
	if slip > 2.2 and sp > 3.0:
		Game.main.fx.skid(self)
	else:
		skid_last = [null, null]

func _process(dt: float) -> void:
	# wheels follow suspension, spin, steer; body roll/pitch is real physics
	if lod_far or not visible or (sleeping and not siren):
		return
	var v_body := linear_velocity.dot(global_basis.z)
	for w in wheels:
		var wy: float = MOUNT_Y - (w.get("len", REST))
		w.pivot.position.y = lerpf(w.pivot.position.y, wy, minf(1.0, dt * 20.0))
		w.spin.rotation.x += v_body * dt / WHEEL_R
		if w.front:
			w.pivot.rotation.y = -steer
	if body_mi:
		var lit := 1 if (braking or (throttle < -0.02 and v_body > 0.5)) else 0
		if lit != _brake_lit:
			_brake_lit = lit
			body_mi.set_instance_shader_parameter("brake", 4.0 if lit else 0.8)
	if bar_red:
		var on := siren and int(Game.t * 6.0) % 2 == 0
		(bar_red.material_override as StandardMaterial3D).emission_energy_multiplier = (5.0 if on else 0.3) if siren else 0.2
		(bar_blue.material_override as StandardMaterial3D).emission_energy_multiplier = (0.3 if on else 5.0) if siren else 0.2

# ---------- AI driving ----------
func drive_to(tgt: Vector3, vmax: float, dt: float, opts := {}) -> float:
	var a := U.ang_to(global_position, tgt)
	var d := U.ang_diff(yaw(), a)
	var dist := U.d2(global_position, tgt)
	var st := -clampf(d * 2.4, -1, 1)
	var vv := vmax if opts.get("arrive", true) == false else minf(vmax, dist * 0.8 + 3.0)
	if opts.has("next"):
		var nx: Vector3 = opts.next
		var turn := absf(U.ang_diff(a, atan2(nx.x - tgt.x, nx.z - tgt.z)))
		if turn > 0.5 and dist < 35.0:
			vv = minf(vv, 7.0 + dist * 0.55)
	if absf(d) > 0.7:
		vv = minf(vv, 7.0)
	var sp := speed()
	var thr := clampf((vv - sp) * 0.45, -1, 1)
	if reverse_t > 0.0:
		reverse_t -= dt
		thr = -1.0
		st = -st
	elif thr > 0.3 and absf(sp) < 0.8:
		stuck_t += dt
		if stuck_t > 1.2:
			reverse_t = 1.0
			stuck_t = 0.0
	else:
		stuck_t = 0.0
	if opts.get("stop", false):
		thr = -1.0 if sp > 0.3 else (1.0 if sp < -0.3 else 0.0)
	throttle = thr
	steer_in = st
	handbrake = opts.get("handbrake", false)
	return dist

func release() -> void:
	throttle = 0.0
	steer_in = 0.0
	handbrake = false
