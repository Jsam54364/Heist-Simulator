extends SceneTree
## Generates the lighting environment resource (assets/env/day_environment.tres).
## Run: godot --headless --path . -s res://tools/make_scenes.gd
## The output is committed; tweak it in the editor afterwards if you like.

func _init() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.24, 0.44, 0.74)
	sky_mat.sky_horizon_color = Color(0.72, 0.78, 0.86)
	sky_mat.sky_curve = 0.12
	sky_mat.ground_bottom_color = Color(0.22, 0.21, 0.2)
	sky_mat.ground_horizon_color = Color(0.72, 0.76, 0.8)
	sky_mat.sun_angle_max = 25.0
	sky_mat.sun_curve = 0.12
	sky_mat.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_256

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = Color(0.62, 0.6, 0.57)
	env.ambient_light_energy = 0.85
	env.ambient_light_sky_contribution = 0.45
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 0.92
	env.tonemap_white = 6.0
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.6
	env.ssao_power = 1.4
	env.ssao_detail = 0.5
	env.ssil_enabled = false
	env.ssil_radius = 4.0
	env.ssil_intensity = 0.8
	env.ssr_enabled = false
	env.ssr_max_steps = 48
	env.ssr_fade_out = 1.6
	env.sdfgi_enabled = false
	env.sdfgi_use_occlusion = true
	env.sdfgi_cascades = 4
	env.sdfgi_min_cell_size = 0.4
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_strength = 0.9
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.15
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.74, 0.79, 0.86)
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.25
	env.fog_density = 0.85
	env.fog_sky_affect = 0.25
	env.fog_depth_begin = 70.0
	env.fog_depth_end = 320.0
	env.fog_depth_curve = 1.6
	env.volumetric_fog_enabled = false
	env.volumetric_fog_density = 0.006
	env.volumetric_fog_albedo = Color(0.9, 0.92, 0.95)
	env.volumetric_fog_length = 96.0
	env.volumetric_fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.1
	DirAccess.make_dir_recursive_absolute("res://assets/env")
	var err := ResourceSaver.save(env, "res://assets/env/day_environment.tres")
	print("env saved: ", err)

	quit()
