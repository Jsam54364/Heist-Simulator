extends Node
## Graphics quality presets + player options. Saved to user://settings.cfg.
##
## Phones: Low/Medium/High run the Mobile renderer. Instead of a fixed render scale each
## preset targets an internal 3D resolution (e.g. 720p on Medium) so a 1440p phone and a
## 720p phone cost about the same, and "auto resolution" lowers/raises the scale to hold
## the frame rate. Distances for world LOD streaming, shadows and actor detail scale per
## preset. High/Ultra add Forward+ effects (SSAO, SSIL, SSR, SDFGI, volumetric fog) when
## that renderer is active (desktop).

signal changed

const PRESETS := {
	"low": {"target_h": 540, "msaa": Viewport.MSAA_DISABLED, "fxaa": false, "taa": false,
		"shadow_size": 1024, "splits": 1, "shadow_dist": 40.0, "char_shadow": 14.0, "car_shadow": 25.0,
		"ssao": false, "ssil": false, "ssr": false, "sdfgi": false, "glow": false, "vfog": false,
		"fog_far": 220.0, "lod_scale": 0.75, "probes": false, "occlusion": true},
	"medium": {"target_h": 720, "msaa": Viewport.MSAA_2X, "fxaa": false, "taa": false,
		"shadow_size": 2048, "splits": 2, "shadow_dist": 60.0, "char_shadow": 25.0, "car_shadow": 45.0,
		"ssao": false, "ssil": false, "ssr": false, "sdfgi": false, "glow": true, "vfog": false,
		"fog_far": 300.0, "lod_scale": 1.0, "probes": true, "occlusion": true},
	"high": {"target_h": 900, "msaa": Viewport.MSAA_4X, "fxaa": false, "taa": false,
		"shadow_size": 4096, "splits": 4, "shadow_dist": 100.0, "char_shadow": 40.0, "car_shadow": 70.0,
		"ssao": true, "ssil": false, "ssr": false, "sdfgi": false, "glow": true, "vfog": false,
		"fog_far": 380.0, "lod_scale": 1.3, "probes": true, "occlusion": true},
	"ultra": {"target_h": 2160, "msaa": Viewport.MSAA_DISABLED, "fxaa": false, "taa": true,
		"shadow_size": 4096, "splits": 4, "shadow_dist": 150.0, "char_shadow": 60.0, "car_shadow": 100.0,
		"ssao": true, "ssil": true, "ssr": true, "sdfgi": true, "glow": true, "vfog": true,
		"fog_far": 480.0, "lod_scale": 1.8, "probes": true, "occlusion": true},
}
const ORDER := ["low", "medium", "high", "ultra"]
const FPS_CHOICES := [60, 30]

var quality := "high"
var look_sensitivity := 1.0
var show_fps := false
var auto_res := true
var fps_cap := 60
var is_mobile := false
var preset_scale := 1.0
var dyn_scale := 1.0
var _fps_acc := 0.0
var _fps_n := 0
var _good_t := 0.0
var _cooldown := 0.0
var _sample_t := 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	is_mobile = OS.has_feature("mobile")
	quality = "medium" if is_mobile else "high"
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		quality = cfg.get_value("graphics", "quality", quality)
		look_sensitivity = cfg.get_value("controls", "look_sensitivity", 1.0)
		show_fps = cfg.get_value("graphics", "show_fps", false)
		auto_res = cfg.get_value("graphics", "auto_res", true)
		fps_cap = cfg.get_value("graphics", "fps_cap", 60)
	if not PRESETS.has(quality):
		quality = "medium"

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("graphics", "quality", quality)
	cfg.set_value("graphics", "show_fps", show_fps)
	cfg.set_value("graphics", "auto_res", auto_res)
	cfg.set_value("graphics", "fps_cap", fps_cap)
	cfg.set_value("controls", "look_sensitivity", look_sensitivity)
	cfg.save("user://settings.cfg")

func cycle_quality() -> void:
	quality = ORDER[(ORDER.find(quality) + 1) % ORDER.size()]
	save()
	apply()
	changed.emit()

func cycle_fps() -> void:
	fps_cap = FPS_CHOICES[(FPS_CHOICES.find(fps_cap) + 1) % FPS_CHOICES.size()]
	save()
	apply()
	changed.emit()

func toggle_auto_res() -> void:
	auto_res = not auto_res
	save()
	apply()
	changed.emit()

## Render scale that gives the preset's internal height on this screen.
func _scale_for(p: Dictionary) -> float:
	var h := float(get_window().size.y)
	if h <= 0.0:
		h = 720.0
	return clampf(float(p.target_h) / h, 0.5, 1.0)

func apply() -> void:
	var p: Dictionary = PRESETS[quality]
	var vp := get_viewport()
	var fplus := RenderingServer.get_current_rendering_method() == "forward_plus"
	Engine.max_fps = fps_cap
	vp.msaa_3d = p.msaa if not (p.taa and not fplus) else Viewport.MSAA_4X
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if p.fxaa else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa = p.taa and fplus
	vp.use_occlusion_culling = p.occlusion
	preset_scale = _scale_for(p)
	dyn_scale = preset_scale
	# FSR1 upscaling is Forward+ only; the Mobile renderer uses bilinear
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if (fplus and preset_scale < 0.99) else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = dyn_scale
	RenderingServer.directional_shadow_atlas_set_size(p.shadow_size, true)
	var sun := get_tree().get_first_node_in_group("sun") as DirectionalLight3D
	if sun:
		sun.shadow_enabled = true
		match int(p.splits):
			1: sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
			2: sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
			_: sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		sun.directional_shadow_max_distance = p.shadow_dist
	var we := get_tree().get_first_node_in_group("world_env") as WorldEnvironment
	if we and we.environment:
		var env := we.environment
		env.ssao_enabled = p.ssao and fplus
		env.ssil_enabled = p.ssil and fplus
		env.ssr_enabled = p.ssr and fplus
		env.sdfgi_enabled = p.sdfgi and fplus
		env.glow_enabled = p.glow
		env.volumetric_fog_enabled = p.vfog and fplus
		env.fog_depth_end = p.fog_far
	for rp in get_tree().get_nodes_in_group("interior_probe"):
		rp.visible = p.probes
	var cam := vp.get_camera_3d()
	if cam:
		cam.far = p.fog_far + 120.0
	var main = Game.main
	if main != null and is_instance_valid(main):
		if main.streamer:
			main.streamer.lod_scale = p.lod_scale
		main.actor_lod.char_shadow = p.char_shadow
		main.actor_lod.car_shadow = p.car_shadow

## Auto resolution: every second compare the frame rate with the cap. Drop the 3D scale
## quickly when we miss it, raise it slowly (after 4 s of headroom) back to the preset.
func _process(dt: float) -> void:
	if not auto_res or Engine.is_editor_hint():
		return
	_cooldown = maxf(0.0, _cooldown - dt)
	_sample_t += dt
	_fps_acc += dt
	_fps_n += 1
	if _sample_t < 1.0:
		return
	var fps := _fps_n / _fps_acc
	_sample_t = 0.0
	_fps_acc = 0.0
	_fps_n = 0
	var target := float(fps_cap)
	var vp := get_viewport()
	if fps < target * 0.9 and dyn_scale > 0.5:
		dyn_scale = maxf(0.5, dyn_scale - (0.1 if fps < target * 0.7 else 0.05))
		vp.scaling_3d_scale = dyn_scale
		_good_t = 0.0
		_cooldown = 6.0
	elif fps >= target * 0.97:
		_good_t += 1.0
		if _good_t >= 4.0 and _cooldown <= 0.0 and dyn_scale < preset_scale:
			dyn_scale = minf(preset_scale, dyn_scale + 0.05)
			vp.scaling_3d_scale = dyn_scale
			_good_t = 0.0
	else:
		_good_t = 0.0
