class_name Fx
extends Node3D
## Bullet tracers with muzzle flashes, and tyre skid marks drawn into a ring buffer
## MultiMesh (one draw call for every mark on the map).

const SKID_MAX := 1400
var skids: MultiMeshInstance3D
var skid_i := 0
var tracers: Array = []
var tracer_mat: StandardMaterial3D
var flash: OmniLight3D
var flash_t := 0.0

func _ready() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var q := QuadMesh.new()
	q.size = Vector2(0.24, 1.0)
	q.orientation = PlaneMesh.FACE_Y
	mm.mesh = q
	mm.instance_count = SKID_MAX
	mm.visible_instance_count = 0
	skids = MultiMeshInstance3D.new()
	skids.multimesh = mm
	skids.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.03, 0.03, 0.03, 0.55)
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.6
	m.render_priority = -1
	skids.material_override = m
	add_child(skids)
	tracer_mat = StandardMaterial3D.new()
	tracer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer_mat.albedo_color = Color(1.0, 0.85, 0.45)
	tracer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tracer_mat.emission_enabled = true
	tracer_mat.emission = Color(1.0, 0.8, 0.4)
	tracer_mat.emission_energy_multiplier = 4.0
	flash = OmniLight3D.new()
	flash.light_color = Color(1.0, 0.75, 0.4)
	flash.omni_range = 7.0
	flash.light_energy = 0.0
	flash.shadow_enabled = false
	add_child(flash)

func tracer(a: Vector3, b: Vector3) -> void:
	var len := a.distance_to(b)
	if len < 0.1:
		return
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.03, 0.03, len)
	mi.mesh = bm
	mi.material_override = tracer_mat.duplicate()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	mi.look_at_from_position((a + b) / 2, b, Vector3.UP if absf((b - a).normalized().y) < 0.98 else Vector3.RIGHT)
	tracers.append({"node": mi, "t": 0.09})
	flash.global_position = a
	flash.light_energy = 3.0
	flash_t = 0.06

func skid(car: Node) -> void:
	var mm := skids.multimesh
	var xf: Transform3D = car.global_transform
	for k in 2:
		var w: Dictionary = car.wheels[2 + k]
		if not w.get("grounded", true):
			car.skid_last[k] = null
			continue
		var m: Vector3 = w.mount
		var p := xf * Vector3(m.x, 0, m.z)
		p.y = Game.ground_y(p.x, p.z) + 0.03 + skid_i * 0.000004
		var last = car.skid_last[k]
		car.skid_last[k] = p
		if last == null:
			continue
		var seg: Vector3 = p - last
		seg.y = 0
		var l := seg.length()
		if l < 0.05 or l > 3.0:
			continue
		var fwd := seg / l
		var t := Transform3D(Basis(Vector3(fwd.z, 0, -fwd.x), Vector3.UP, fwd * l), (last + p) / 2)
		# QuadMesh FACE_Y lies in XZ with its 1 m length along -Z/+Z
		mm.set_instance_transform(skid_i, t)
		mm.set_instance_color(skid_i, Color(1, 1, 1, clampf(car.slip / 6.0, 0.35, 0.9)))
		skid_i = (skid_i + 1) % SKID_MAX
		mm.visible_instance_count = maxi(mm.visible_instance_count, skid_i if mm.visible_instance_count < SKID_MAX else SKID_MAX)

func _process(dt: float) -> void:
	for i in range(tracers.size() - 1, -1, -1):
		var tr: Dictionary = tracers[i]
		tr.t -= dt
		if tr.t <= 0.0:
			tr.node.queue_free()
			tracers.remove_at(i)
		else:
			(tr.node.material_override as StandardMaterial3D).albedo_color.a = tr.t / 0.09
	if flash_t > 0.0:
		flash_t -= dt
		if flash_t <= 0.0:
			flash.light_energy = 0.0
