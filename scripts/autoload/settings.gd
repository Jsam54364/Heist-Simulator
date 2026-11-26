extends Node
## Graphics quality presets + player options. Saved to user://settings.cfg.
## Low/Medium suit phones (Mobile renderer); High/Ultra add Forward+ effects
## (SSAO, SSIL, SSR, SDFGI, volumetric fog) that only run on the desktop renderer.

signal changed

const PRESETS := {
	"low": {"msaa": Viewport.MSAA_DISABLED, "fxaa": true, "taa": false, "scale": 0.75, "fsr": true,
		"shadow_size": 1024, "splits": 1, "shadow_dist": 60.0, "ssao": false, "ssil": false, "ssr": false,
		"sdfgi": false, "glow": false, "vfog": false, "fog_far": 230.0, "lod": 4.0},
	"medium": {"msaa": Viewport.MSAA_2X, "fxaa": false, "taa": false, "scale": 0.9, "fsr": true,
		"shadow_size": 2048, "splits": 2, "shadow_dist": 90.0, "ssao": false, "ssil": false, "ssr": false,
		"sdfgi": false, "glow": true, "vfog": false, "fog_far": 300.0, "lod": 2.0},
	"high": {"msaa": Viewport.MSAA_4X, "fxaa": false, "taa": false, "scale": 1.0, "fsr": false,
		"shadow_size": 4096, "splits": 4, "shadow_dist": 130.0, "ssao": true, "ssil": false, "ssr": false,
		"sdfgi": false, "glow": true, "vfog": false, "fog_far": 380.0, "lod": 1.0},
	"ultra": {"msaa": Viewport.MSAA_DISABLED, "fxaa": false, "taa": true, "scale": 1.0, "fsr": false,
		"shadow_size": 4096, "splits": 4, "shadow_dist": 180.0, "ssao": true, "ssil": true, "ssr": true,
		"sdfgi": true, "glow": true, "vfog": true, "fog_far": 480.0, "lod": 1.0},
}
const ORDER := ["low", "medium", "high", "ultra"]

var quality := "high"
var look_sensitivity := 1.0
var show_fps := false
var is_mobile := false

func _ready() -> void:
	is_mobile = OS.has_feature("mobile")
	quality = "medium" if is_mobile else "high"
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		quality = cfg.get_value("graphics", "quality", quality)
		look_sensitivity = cfg.get_value("controls", "look_sensitivity", 1.0)
		show_fps = cfg.get_value("graphics", "show_fps", false)
	if not PRESETS.has(quality):
		quality = "medium"

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("graphics", "quality", quality)
	cfg.set_value("graphics", "show_fps", show_fps)
	cfg.set_value("controls", "look_sensitivity", look_sensitivity)
	cfg.save("user://settings.cfg")

func cycle_quality() -> void:
	quality = ORDER[(ORDER.find(quality) + 1) % ORDER.size()]
	save()
	apply()
	changed.emit()

func apply() -> void:
	var p: Dictionary = PRESETS[quality]
	var vp := get_viewport()
	vp.msaa_3d = p.msaa
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if p.fxaa else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa = p.taa
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if p.fsr else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = p.scale
	vp.mesh_lod_threshold = p.lod
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
	# SSAO/SSIL/SSR/SDFGI/volumetric fog/FSR exist only in Forward+ (desktop, or Android
	# if rendering_method.mobile is switched to forward_plus in Project Settings)
	var fplus := RenderingServer.get_current_rendering_method() == "forward_plus"
	if not fplus and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	if we and we.environment:
		var env := we.environment
		env.ssao_enabled = p.ssao and fplus
		env.ssil_enabled = p.ssil and fplus
		env.ssr_enabled = p.ssr and fplus
		env.sdfgi_enabled = p.sdfgi and fplus
		env.glow_enabled = p.glow
		env.volumetric_fog_enabled = p.vfog and fplus
		env.fog_depth_end = p.fog_far
	var cam := vp.get_camera_3d()
	if cam:
		cam.far = p.fog_far + 250.0
