class_name Mats
## Material library. City surfaces come from assets/materials/*.tres (edit them in
## the Godot editor or swap their textures); small gameplay materials are made here.

static var lib := {}

const TILE := {
	"facade_stucco": Vector2(4, 3.4), "facade_brick": Vector2(4, 3.4), "facade_office": Vector2(4, 3.4), "facade_glass": Vector2(4, 3.4),
	"shopfront": Vector2(4, 4.2), "asphalt": Vector2(8, 8), "sidewalk": Vector2(3, 3), "roof_gravel": Vector2(4, 4), "sand": Vector2(5, 5),
	"grass": Vector2(4, 4), "wood_planks": Vector2(4, 4), "marble": Vector2(3, 3), "carpet": Vector2(3, 3), "checker_floor": Vector2(2, 2),
	"plaster": Vector2(3, 3), "concrete": Vector2(4, 4), "metal_brushed": Vector2(2, 2), "awning": Vector2(2, 2), "crosswalk": Vector2(12, 3),
}

static func m(name: String) -> Material:
	if lib.has(name):
		return lib[name]
	var mat: Material = null
	var path := "res://assets/materials/%s.tres" % name
	if ResourceLoader.exists(path):
		mat = load(path)
	else:
		mat = _make(name)
	mat.resource_name = name
	lib[name] = mat
	return mat

static func tile_of(mat: Material) -> Vector2:
	return TILE.get(mat.resource_name, Vector2(2, 2))

static func solid(c: Color, rough := 0.7, metal := 0.0, emit := 0.0) -> StandardMaterial3D:
	var s := StandardMaterial3D.new()
	s.albedo_color = c
	s.roughness = rough
	s.metallic = metal
	if emit > 0.0:
		s.emission_enabled = true
		s.emission = c
		s.emission_energy_multiplier = emit
	return s

static func _make(name: String) -> Material:
	match name:
		"interact": return solid(Color("ef8a2b"), 0.5, 0.0, 0.35)
		"alarm": return solid(Color("f2d230"), 0.5, 0.0, 0.6)
		"dvr": return solid(Color("3f8fff"), 0.4, 0.2, 0.5)
		"note": return solid(Color("7cf27c"), 0.6, 0.0, 0.7)
		"cash": return solid(Color("4caf50"), 0.7, 0.0, 0.15)
		"jewel": return solid(Color("7fe3ff"), 0.05, 0.3, 0.9)
		"locked": return solid(Color("c0563f"), 0.6)
		"reinforced": return solid(Color("7a2424"), 0.4, 0.6)
		"vault": return solid(Color("8c96a3"), 0.3, 0.9)
		"safe": return solid(Color("56606a"), 0.35, 0.8)
		"lockbox": return solid(Color("9aa3ad"), 0.3, 0.9)
		"counter": return solid(Color("8a8f96"), 0.5)
		"dark": return solid(Color("222428"), 0.6)
		"white": return solid(Color("f2f2f2"), 0.6)
		"glass": return m("window_glass")
		"zone":
			var z := solid(Color("2de2e6"), 1.0, 0.0, 0.5)
			z.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			z.albedo_color.a = 0.18
			z.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			return z
		"water":
			var w := ShaderMaterial.new()
			w.shader = load("res://assets/shaders/water.gdshader")
			w.set_shader_parameter("normal_tex", load("res://assets/textures/water_normal.png"))
			return w
	push_warning("Unknown material " + name)
	return solid(Color.MAGENTA)


## Cell in assets/textures/far_atlas.png used by the far HLOD for a facade material.
const FAR_CELLS := {"facade_stucco": 0, "facade_brick": 1, "facade_office": 2, "facade_glass": 3, "shopfront": 4, "roof_gravel": 5}
static func far_cell(mat: Material) -> int:
	return FAR_CELLS.get(str(mat.resource_name), 0)


## The merged city material (see assets/shaders/city_uber.gdshader). Surfaces whose
## material is in CityLayers.INDEX are drawn with it.
static var _uber: ShaderMaterial
static func uber() -> ShaderMaterial:
	if _uber:
		return _uber
	_uber = ShaderMaterial.new()
	_uber.resource_name = "city_uber"
	_uber.shader = load("res://assets/shaders/city_uber.gdshader")
	_uber.set_shader_parameter("albedo_arr", load("res://assets/textures/city_albedo_array.png"))
	_uber.set_shader_parameter("normal_arr", load("res://assets/textures/city_normal_array.png"))
	_uber.set_shader_parameter("orm_arr", load("res://assets/textures/city_orm_array.png"))
	var params := []
	var tints := []
	for i in 32:
		if i < CityLayers.COUNT:
			params.append(CityLayers.PARAMS[i])
			var t: Color = CityLayers.TINT[i]
			tints.append(Vector4(t.srgb_to_linear().r, t.srgb_to_linear().g, t.srgb_to_linear().b, 1.0))
		else:
			params.append(Vector4.ZERO)
			tints.append(Vector4.ONE)
	_uber.set_shader_parameter("params", params)
	_uber.set_shader_parameter("tint", tints)
	return _uber
