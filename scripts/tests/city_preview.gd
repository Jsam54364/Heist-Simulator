extends Node3D
## Dev helper: builds only the city and saves screenshots (run with a display).

func _ready() -> void:
	var b := MeshBuilder.new(self)
	var c := CityGen.new(b)
	var t0 := Time.get_ticks_msec()
	c.build([])
	b.finalize(self)
	print("city built in ", Time.get_ticks_msec() - t0, " ms, colliders ", b.cols.size())
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.sky = sky
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 40, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(-20, 12, 30)
	cam.look_at(Vector3(20, 4, -10))
	cam.far = 800
	cam.make_current()
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("/tmp/city1.png")
	cam.position = Vector3(140, 25, -60)
	cam.look_at(Vector3(175, 0, 10))
	await get_tree().process_frame
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("/tmp/city2.png")
	get_tree().quit()
