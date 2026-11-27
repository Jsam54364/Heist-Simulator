extends Node
## Visual check for the vehicle models: every kind in a row, people seated inside.
##   xvfb-run godot --path . --rendering-method mobile res://scenes/tests/garage.tscn  -> /tmp/garage_*.png
func _ready() -> void:
	await get_tree().process_frame
	var w := Node3D.new(); add_child(w)
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new(); var sm := ProceduralSkyMaterial.new(); sky.sky_material = sm; e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY; e.ambient_light_energy = 0.7
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e; w.add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-40, 35, 0); sun.light_energy = 1.4; sun.shadow_enabled = true; w.add_child(sun)
	var ground := MeshInstance3D.new(); var pm := PlaneMesh.new(); pm.size = Vector2(80, 80); ground.mesh = pm
	ground.material_override = Mats.solid(Color("5a5c60"), 0.9); w.add_child(ground)
	var kinds := ["sedan", "coupe", "suv", "pickup", "taxi", "police", "swat", "truck"]
	var cars := []
	var x := 0.0
	for k in kinds:
		var c: Vehicle = Vehicle.new().setup(k, Vector3(x, 0, 0), 0.0, {"color_idx": cars.size() % Game.CAR_COLORS.size()})
		c.freeze = true
		w.add_child(c)
		c.position = Vector3(x, 0, 0)
		cars.append(c)
		x -= c.W + 1.4
	# police helicopter parked beside the row
	var hroot := Node3D.new(); w.add_child(hroot); hroot.position = Vector3(8.5, 1.45, 0); hroot.rotation.y = 0.6
	for part in [["heli_body", Vector3.ZERO], ["heli_rotor", Vector3(0, 1.45, -0.2)], ["heli_tail_rotor", Vector3(0.22, 0.95, -5.55)]]:
		var hm := MeshInstance3D.new(); hm.mesh = CarModel.meshes[part[0]]; hm.position = part[1]; hroot.add_child(hm)
	# driver + passenger in the sedan, driver in the swat van
	var O = load("res://scripts/actors/outfits.gd"); var HM = load("res://scripts/actors/human_model.gd")
	var peeps := []
	for pair in [[cars[0], 0, "player"], [cars[0], 1, "partner"], [cars[6], 0, "player"], [cars[3], 0, "partner"]]:
		var car: Vehicle = pair[0]
		var hm = HM.new(); car.body_node.add_child(hm)
		hm.transform = car.seat_transform(pair[1])
		hm.build(O.for_role(pair[2], {}))
		peeps.append([hm, "drive" if pair[1] == 0 else "sit"])
	for f in 30:
		for p in peeps: p[0].drive(1.0 / 30, p[1], "stand", p[0].global_position, 0.0, {"speed": 0.0})
		await get_tree().process_frame
	var cam := Camera3D.new(); w.add_child(cam); cam.fov = 40; cam.make_current()
	var shots := {
		"row": [Vector3(6, 4.5, 14), Vector3(-14, 0.8, 0)],
		"sedan": [Vector3(3.2, 1.6, 4.8), Vector3(0, 0.8, 0)],
		"sedan_rear": [Vector3(-3.0, 1.5, -5.0), Vector3(0, 0.8, 0)],
		"cabin": [Vector3(2.2, 1.75, 0.9), Vector3(0.2, 0.9, -0.1)],
		"police": [Vector3(cars[5].position.x + 3.5, 1.7, 5.0), cars[5].position + Vector3(0, 0.8, 0)],
		"swat": [Vector3(cars[6].position.x + 4.5, 2.2, 6.5), cars[6].position + Vector3(0, 1.2, 0)],
		"truck": [Vector3(cars[7].position.x + 5.0, 2.4, 7.5), cars[7].position + Vector3(0, 1.4, 0)],
		"heli": [Vector3(15.5, 3.2, 9.0), Vector3(8.0, 1.4, -0.5)],
		"sedan_side": [Vector3(-1.5, 0.5, -0.4), Vector3(-0.3, 0.3, 0.0)],
		"pickup": [Vector3(cars[3].position.x - 4.0, 1.9, -5.5), cars[3].position + Vector3(0, 0.9, 0)],
	}
	for nm in shots:
		cam.position = shots[nm][0]
		cam.look_at(shots[nm][1])
		await get_tree().process_frame; await get_tree().process_frame; await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("/tmp/garage_%s.png" % nm)
	get_tree().quit()
