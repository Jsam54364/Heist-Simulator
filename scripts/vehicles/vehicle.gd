class_name Vehicle
extends RigidBody3D
## Car = ONE rigid body with ONE convex collider (a chamfered car-shaped hull that rides
## up kerbs), driven by a two-axle tyre model in the spirit of GTA 6: real weight transfer
## (brake = nose dives and the front bites, throttle = squat and the rear can step out),
## slip-angle grip that peaks and then lets go (so you can hold a slide), power oversteer
## on rear-drive cars, handbrake turns, speed-sensitive steering, and a light stability
## assist so it stays drivable on a touch screen. Suspension, roll and pitch are visual.
## Model faces +Z; yaw convention matches U.fwd().

const SPECS := {
	# mass kg, top speed m/s, engine accel m/s2, brake m/s2, grip mu, steer rad, wheelbase m,
	# drive: "rwd" | "fwd" | "awd", roof height m (collider)
	"sedan": {"L": 4.6, "W": 1.9, "mass": 1450.0, "max_speed": 44.0, "accel": 7.2, "brake": 9.0, "grip": 1.05, "steer_max": 0.62, "wb": 2.7, "drive": "fwd", "roof": 1.45, "max_rev": 9.0},
	"coupe": {"L": 4.4, "W": 1.95, "mass": 1380.0, "max_speed": 56.0, "accel": 10.5, "brake": 10.5, "grip": 1.15, "steer_max": 0.6, "wb": 2.6, "drive": "rwd", "roof": 1.32, "max_rev": 9.0},
	"suv": {"L": 4.8, "W": 2.05, "mass": 2100.0, "max_speed": 42.0, "accel": 6.2, "brake": 8.2, "grip": 0.98, "steer_max": 0.56, "wb": 2.9, "drive": "awd", "roof": 1.8, "max_rev": 8.0},
	"pickup": {"L": 5.2, "W": 2.05, "mass": 2200.0, "max_speed": 41.0, "accel": 6.6, "brake": 8.0, "grip": 0.95, "steer_max": 0.56, "wb": 3.2, "drive": "rwd", "roof": 1.8, "max_rev": 8.0},
	"taxi": {"L": 4.6, "W": 1.9, "mass": 1500.0, "max_speed": 42.0, "accel": 7.0, "brake": 9.0, "grip": 1.03, "steer_max": 0.62, "wb": 2.7, "drive": "rwd", "roof": 1.45, "max_rev": 9.0},
	"police": {"L": 4.8, "W": 1.95, "mass": 1750.0, "max_speed": 54.0, "accel": 9.6, "brake": 10.5, "grip": 1.12, "steer_max": 0.6, "wb": 2.8, "drive": "rwd", "roof": 1.5, "max_rev": 10.0},
	"swat": {"L": 5.6, "W": 2.2, "mass": 3600.0, "max_speed": 40.0, "accel": 6.0, "brake": 7.5, "grip": 1.0, "steer_max": 0.52, "wb": 3.4, "drive": "awd", "roof": 2.5, "max_rev": 7.0},
	"truck": {"L": 6.4, "W": 2.4, "mass": 6200.0, "max_speed": 28.0, "accel": 3.8, "brake": 6.5, "grip": 0.95, "steer_max": 0.5, "wb": 3.8, "drive": "awd", "roof": 2.9, "max_rev": 6.0},
}
const CIV := ["sedan", "sedan", "coupe", "suv", "pickup", "taxi", "sedan", "pickup"]
const WHEEL_R := 0.36
const MOUNT_Y := 0.75
const REST := 0.36           # visual suspension travel reference (wheel centre below mount)
const COM_Y := 0.42
const G := 9.81

static var next_id := 1

var kind := "sedan"
var spec: Dictionary
var car_id := 0
var color_idx := 0
var L := 4.6
var W := 1.9

# inputs (player or AI)
var throttle := 0.0
var steer_in := 0.0
var handbrake := false
# state
var steer := 0.0
var wheels: Array = []
var driver = null          # "player" or null
var npc_driver = null      # Character driving
var ai := {}
var trunk: Array = []
var personal := false
var siren := false
var parked := false
var removed := false
var tracker := false       # stolen cars with a tracker get reported
var tires_burst := 0       # spike strips / shot tyres
var in_water := false
var crouched := false      # player ducking in a parked car (hiding)
var gear := 1
var rpm := 0.0
var slip := 0.0
var braking := false
var grounded := false
var hit_cd := 0.0
var stuck_t := 0.0
var reverse_t := 0.0
var prev_vel := Vector3.ZERO
var a_long := 0.0          # smoothed longitudinal / lateral acceleration (weight transfer + visuals)
var a_lat := 0.0
var surface_grip := 1.0

var body_node: Node3D
var paint_mat: StandardMaterial3D
var body_mi: MeshInstance3D
var _brake_lit := -1
var bar_red: MeshInstance3D
var bar_blue: MeshInstance3D
var skid_last := [null, null]
var ray: RayCast3D
var _vis_pitch := 0.0
var _vis_roll := 0.0
var _vis_pv := 0.0
var _vis_rv := 0.0

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
	tracker = opts.get("tracker", kind == "police" or randf() < 0.2)
	if kind == "taxi":
		color_idx = 4
	position = Vector3(pos.x, 0.06, pos.z)
	rotation.y = p_yaw
	return self

## The single collider: a car-shaped convex hull. Its underside is chamfered on all four
## sides so the car slides up kerbs and over bumps instead of snagging on them.
func _hull() -> ConvexPolygonShape3D:
	var hw := W * 0.5
	var hl := L * 0.5
	var roof: float = spec.roof
	var pts := PackedVector3Array()
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			pts.append(Vector3(sx * (hw - 0.18), 0.0, sz * (hl - 0.7)))        # flat skid plate
			pts.append(Vector3(sx * hw, 0.38, sz * hl))                         # bumper corners
			pts.append(Vector3(sx * hw, 0.95, sz * (hl - 0.05)))                # belt line
	var cab_f := hl * (0.35 if kind in ["pickup", "truck", "swat"] else 0.15)
	var cab_r := -hl * (0.15 if kind == "pickup" else 0.62)
	if kind in ["truck", "swat"]:
		cab_r = -hl * 0.95
	for sx in [-1.0, 1.0]:
		pts.append(Vector3(sx * (hw - 0.22), roof, cab_f))
		pts.append(Vector3(sx * (hw - 0.22), roof, cab_r))
	var s := ConvexPolygonShape3D.new()
	s.points = pts
	return s

func _ready() -> void:
	mass = spec.mass
	collision_layer = Game.L_VEHICLE
	collision_mask = Game.L_WORLD | Game.L_GLASS | Game.L_VEHICLE | Game.L_GROUND
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, COM_Y, 0)
	angular_damp = 0.25
	linear_damp = 0.0
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE     # no hidden project-default drag
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	can_sleep = true
	continuous_cd = true
	var pm := PhysicsMaterial.new()
	pm.friction = 0.0           # tyre grip comes from the model, not from the hull scraping
	pm.bounce = 0.08
	physics_material_override = pm
	var cs := CollisionShape3D.new()
	cs.shape = _hull()
	add_child(cs)
	CarModel.build(self)
	ray = RayCast3D.new()
	ray.position = Vector3(0, 0.6, 0)
	ray.target_position = Vector3(0, -1.0, 0)
	ray.collision_mask = Game.L_GROUND | Game.L_WORLD
	ray.add_exception(self)
	add_child(ray)

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
	if paint_mat and kind not in ["police", "truck", "swat"]:
		paint_mat.albedo_color = Game.CAR_COLORS[idx]

func place(pos: Vector3, p_yaw: float) -> void:
	global_transform = Transform3D(Basis(Vector3.UP, p_yaw), Vector3(pos.x, 0.06, pos.z))
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	reset_physics_interpolation()

func burst_tire() -> void:
	if tires_burst < 4:
		tires_burst += 1
		Sfx.play("boom", 0.35, 1.8)

## LOD: far traffic rides its lane kinematically ("rail"), sleeping/parked cars skip the
## tyre script entirely, far cars drop wheel animation and shadows.
var rail := false
var lod_far := false
var _shadow_on := true

func set_rail(on: bool, spd := 0.0) -> void:
	if on == rail:
		return
	rail = on
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = on
	if not on:
		linear_velocity = fwd_dir() * spd
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

## Lateral tyre force curve: rises with slip angle, peaks around 8-9 degrees, then falls
## off to ~75% when sliding - that drop is what lets a car step out and hold a drift.
static func _tyre_curve(alpha: float) -> float:
	var a := absf(alpha)
	var peak := 0.15
	var f: float
	if a < peak:
		f = a / peak * (1.6 - 0.6 * a / peak)
	else:
		f = lerpf(1.0, 0.8, clampf((a - peak) / 0.6, 0.0, 1.0))
	return signf(alpha) * f

func _physics_process(dt: float) -> void:
	if removed or freeze:
		return
	var controlled: bool = absf(throttle) > 0.01 or absf(steer_in) > 0.01 or handbrake
	if sleeping:
		if controlled:
			sleeping = false
		else:
			return
	var b := global_basis
	var up := b.y
	var fwd := b.z
	var side := b.x                       # car's left
	var v := linear_velocity
	var v_long := v.dot(fwd)
	var sp := absf(v_long)
	var v_prev := prev_vel
	prev_vel = v
	_hit_check(v - v_prev)
	# water: engine floods, the car wallows and sinks
	in_water = global_position.y < -0.55
	if in_water:
		apply_central_force(-v * mass * 1.6 + Vector3.UP * mass * G * 0.82)
		apply_torque(-angular_velocity * mass * 2.0)
		throttle = 0.0
		slip = 0.0
		return
	# ground contact (one ray under the centre of the car)
	grounded = ray.is_colliding()
	var n := ray.get_collision_normal() if grounded else Vector3.UP
	if grounded:
		var gp := ray.get_collision_point()
		surface_grip = Game.main.world_gen.grip_at(gp.x, gp.z) if Game.main and Game.main.world_gen else 1.0
	# smoothed accelerations (for weight transfer and the visual body motion)
	var acc := (v - v_prev) / dt
	a_long = lerpf(a_long, acc.dot(fwd), minf(1.0, dt * 8.0))
	a_lat = lerpf(a_lat, acc.dot(side), minf(1.0, dt * 8.0))
	# steering: quick at parking speed, calmer at speed; a little self-centring
	var max_steer: float = spec.steer_max * lerpf(1.0, 0.3, clampf(sp / 38.0, 0.0, 1.0))
	var target_steer := clampf(steer_in, -1.0, 1.0) * max_steer
	steer = move_toward(steer, target_steer, dt * (4.0 if absf(target_steer) > absf(steer) else 6.0))
	braking = false
	if not grounded:
		slip = 0.0
		rpm = lerpf(rpm, absf(throttle), dt * 3.0)
		return
	var wb: float = spec.wb
	var a := wb * 0.5
	var com := global_position + b * center_of_mass
	var mu: float = spec.grip * surface_grip * (1.0 - 0.12 * tires_burst)
	# static + dynamic axle loads (longitudinal weight transfer)
	var h := COM_Y + 0.15
	var transfer := clampf(mass * a_long * h / wb, -mass * G * 0.35, mass * G * 0.35)
	var n_f := maxf(0.0, mass * G * 0.5 - transfer)
	var n_r := maxf(0.0, mass * G * 0.5 + transfer)
	# drivetrain
	var top: float = spec.max_speed * (1.0 - 0.15 * tires_burst)
	var drive_f := 0.0
	var brake_total := 0.0
	if throttle > 0.02:
		if v_long < -0.8:
			brake_total = throttle * spec.brake * mass
		else:
			drive_f = throttle * spec.accel * mass * clampf(1.0 - pow(maxf(v_long, 0.0) / top, 2.2), 0.0, 1.0)
	elif throttle < -0.02:
		if v_long > 0.8:
			brake_total = -throttle * spec.brake * mass
		elif v_long > -spec.max_rev:
			drive_f = throttle * spec.accel * mass * 0.6
	braking = brake_total > 0.0
	var split_r := 1.0 if spec.drive == "rwd" else (0.0 if spec.drive == "fwd" else 0.6)
	var axles := [
		{"pos": fwd * a, "dir": b * Vector3(-sin(steer), 0, cos(steer)), "n": n_f, "drive": drive_f * (1.0 - split_r), "brake": brake_total * 0.62, "rear": false},
		{"pos": -fwd * a, "dir": fwd, "n": n_r, "drive": drive_f * split_r, "brake": brake_total * 0.38, "rear": true},
	]
	var max_slip := 0.0
	var lat_slip_rear := 0.0
	for ax in axles:
		var dir: Vector3 = ax.dir
		dir = (dir - n * dir.dot(n)).normalized()
		var lat := n.cross(dir)                  # points to the car's left
		var r: Vector3 = ax.pos
		var vp := v + angular_velocity.cross(com + r - com)
		var vl := vp.dot(dir)
		var vt := vp.dot(lat)
		var load: float = ax.n
		var cap: float = mu * load
		# longitudinal: drive, brakes, rolling resistance, handbrake lock on the rear
		var fx: float = ax.drive
		if ax.brake > 0.0:
			fx -= signf(vl) * minf(ax.brake, absf(vl) * mass * 0.5 / dt)
		fx -= vl * mass * 0.5 * (0.012 if absf(throttle) > 0.02 else 0.05)
		var locked: bool = ax.rear and handbrake
		if locked:
			fx = -signf(vl) * minf(cap * 0.85, absf(vl) * mass * 0.5 / dt)
			braking = true
		# lateral: slip-angle curve at speed, plain damping when crawling
		var fy: float
		if absf(vl) > 2.5:
			var alpha := atan2(vt, absf(vl))
			# a touch more rear grip than front = mild, safe understeer at the limit (GTA feel);
			# throttle or the handbrake still take it away through the friction circle
			fy = -_tyre_curve(alpha) * cap * (1.12 if ax.rear else 1.0)
			max_slip = maxf(max_slip, absf(alpha) * 10.0)
			if ax.rear:
				lat_slip_rear = alpha
		else:
			fy = clampf(-vt * mass * 0.5 / dt * 0.6, -cap, cap)
		if locked:
			fy *= 0.38
		# friction circle: wheelspin / lock-up eat into cornering grip
		var total := Vector2(fx, fy).length()
		if total > cap and total > 0.0:
			var over := total / cap
			max_slip = maxf(max_slip, (over - 1.0) * 6.0)
			# keep the longitudinal share (so the throttle can kick the rear out)
			var k := cap / total
			fx *= k
			fy *= k * (0.85 if over > 1.25 else 1.0)
		var at := com + r + up * (-COM_Y * 0.6)
		apply_force(dir * fx + lat * fy, at - global_position)
	# stability assist: nudges yaw rate toward what the steering asks for, much weaker when
	# you're deliberately sliding (handbrake) - accessible, but you can still drift
	var yaw_rate := angular_velocity.dot(up)
	var want := v_long * tan(steer) / wb * -1.0
	var assist := 0.0 if handbrake else (0.6 if driver == "player" else 0.9)
	# a slide you didn't ask for (rear stepping out with no handbrake, no throttle mash)
	# gets caught a little harder - you can hold a drift, but you don't spin out of nowhere
	if not handbrake and absf(lat_slip_rear) > 0.2 and throttle < 0.7:
		assist += 0.5
	if absf(v_long) > 3.0:
		apply_torque(up * (want - yaw_rate) * mass * wb * assist * 0.5)
	# aero drag, downforce, keep it from tumbling on flat ground
	apply_central_force(-v * v.length() * mass * 0.00042 - up * sp * sp * mass * 0.0016)
	var roll_rate := angular_velocity - up * yaw_rate
	apply_torque(-roll_rate * mass * 1.2)
	if up.y < 0.45 and sp < 3.0:
		apply_torque(up.cross(Vector3.UP) * mass * 8.0)
	slip = max_slip
	if throttle > 0.9 and sp < 7.0 and driver == "player" and spec.accel > 9.0:
		slip = maxf(slip, 2.6)
	# gearbox (sound / HUD)
	var frac: float = sp / spec.max_speed
	var gs := [0.0, 0.14, 0.3, 0.48, 0.68, 0.9, 1.1]
	var g := 1
	while g < 6 and frac > gs[g]:
		g += 1
	gear = 0 if v_long < -0.5 else g
	rpm = clampf((frac - gs[g - 1]) / (gs[g] - gs[g - 1]), 0.0, 1.0) * 0.8 + absf(throttle) * 0.2
	if slip > 2.2 and sp > 3.0:
		Game.main.fx.skid(self)
	else:
		skid_last = [null, null]

## A big velocity change in one tick can only be a collision.
func _hit_check(dvel: Vector3) -> void:
	hit_cd -= get_physics_process_delta_time()
	var dv := dvel.length()
	if dv > 4.0 and hit_cd <= 0.0:
		hit_cd = 0.4
		Game.main.on_vehicle_impact(self, dv)

func _process(dt: float) -> void:
	if lod_far or not visible or (sleeping and not siren):
		return
	var v_body := linear_velocity.dot(global_basis.z)
	# visual body motion: dive under braking, squat under power, lean in corners (springy)
	if body_node:
		var tp := clampf(a_long * 0.0065, -0.07, 0.07)
		var tr := clampf(-a_lat * 0.0085, -0.09, 0.09)
		_vis_pv += ((tp - _vis_pitch) * 160.0 - _vis_pv * 16.0) * dt
		_vis_rv += ((tr - _vis_roll) * 140.0 - _vis_rv * 14.0) * dt
		_vis_pitch += _vis_pv * dt
		_vis_roll += _vis_rv * dt
		body_node.rotation = Vector3(-_vis_pitch, 0, _vis_roll)
		body_node.position.y = absf(_vis_pitch) * -0.6
	for w in wheels:
		# wheels stay on the road while the body pitches/rolls above them
		var comp: float = (_vis_pitch * w.mount.z * (1.0 if w.front else 1.0)) - _vis_roll * w.mount.x
		w.len = clampf(REST + comp, 0.15, 0.5)
		w.grounded = grounded
		w.pivot.position.y = lerpf(w.pivot.position.y, WHEEL_R, minf(1.0, dt * 20.0))
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
	var ang := U.ang_to(global_position, tgt)
	var d := U.ang_diff(yaw(), ang)
	var dist := U.d2(global_position, tgt)
	var st := -clampf(d * 2.4, -1, 1)
	var vv := vmax if opts.get("arrive", true) == false else minf(vmax, dist * 0.8 + 3.0)
	if opts.has("next"):
		var nx: Vector3 = opts.next
		var turn := absf(U.ang_diff(ang, atan2(nx.x - tgt.x, nx.z - tgt.z)))
		if turn > 0.5 and dist < 40.0:
			vv = minf(vv, 8.0 + dist * 0.5)
	if absf(d) > 0.7:
		vv = minf(vv, 8.0)
	var sp := speed()
	var thr := clampf((vv - sp) * 0.4, -1, 1)
	if reverse_t > 0.0:
		reverse_t -= dt
		thr = -1.0
		st = -st
	elif thr > 0.3 and absf(sp) < 0.8:
		stuck_t += dt
		if stuck_t > 1.4:
			reverse_t = 1.1
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
