class_name Outfits
extends RefCounted
## Appearance for every role, built from the MakeHuman part catalogue (see HumanModel):
## gender, photo skin (+ tint for in-between tones), garment parts and their tint colours.
## Civilians are rolled from Keys-appropriate palettes; uniforms are fixed per role.
## Colours: alpha 1 = re-colour the garment, alpha 0 = keep its texture colours.

const HAIR := [Color("120d0a"), Color("2b1d12"), Color("3b2a1d"), Color("4a3020"), Color("6b4a2a"), Color("a07a4a"), Color("c9a26b"), Color("8a8a8a"), Color("7a2e1a")]
const TOPS := [Color("f2f2ee"), Color("2e6fd1"), Color("e2434b"), Color("2c8f6e"), Color("f2a531"), Color("1d9fb5"), Color("e85d9a"),
	Color("2c2d30"), Color("8b4bd1"), Color("f6e7a0"), Color("9fe0d8"), Color("ffc7d6"), Color("6e7f99"), Color("c9785a"), Color("444a3a")]
const BOTTOMS := [Color("3e4c63"), Color("2b3a55"), Color("1e2430"), Color("b9a57f"), Color("d9d2c2"), Color("4a5a3a"), Color("6b6f78"), Color("56657c")]
const SHOES := [Color("f2f2f2"), Color("1a1a1c"), Color("6b4a2a"), Color("2e6fd1"), Color("d9d2c2"), Color("e2434b"), Color("333333")]
const HATS := [Color("e2434b"), Color("1e2430"), Color("f2f2ee"), Color("2c8f6e"), Color("f2a531"), Color("2e6fd1")]
const NONE := Color(0, 0, 0, 0)
const NAVY := Color("1b2436")

const M_TOPS := ["tee", "tee", "tee", "longsleeve", "shirt", "jacket"]
const F_TOPS := ["tee", "tee_b", "crop", "tank", "tee", "blouse"]
const M_HAIR := ["hair_messy", "hair_side_part", "hair_buzz", "hair_afro"]
const F_HAIR := ["hair_ponytail", "hair_bob", "hair_long"]

static func pick(a: Array, rng: RandomNumberGenerator):
	return a[rng.randi() % a.size()]

static func _skin(s: Dictionary, g: String, rng: RandomNumberGenerator, which := -1) -> void:
	HumanModel._shared()
	var skins: Dictionary = HumanModel.catalogue[g].skins
	var names := skins.keys().filter(func(n): return not String(n).begins_with("hero"))
	names.sort()
	# caucasian / african / asian photo skins, each nudged lighter/darker for in-between tones
	var nm: String = names[which] if which >= 0 else pick(names, rng)
	s.skin = nm
	var off: Array = skins[nm]
	s.skin_offset = Vector2(off[0], off[1])
	var k := rng.randf_range(0.88, 1.06) if which < 0 else 1.0
	s.skin_tint = Color(k, k * rng.randf_range(0.97, 1.0), k * rng.randf_range(0.95, 1.0))

static func _skin_named(s: Dictionary, g: String, nm: String) -> void:
	HumanModel._shared()
	var off: Array = HumanModel.catalogue[g].skins[nm]
	s.skin = nm
	s.skin_offset = Vector2(off[0], off[1])
	s.skin_tint = Color.WHITE

static func for_role(role: String, opts := {}) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = opts.get("seed", randi())
	var female: bool = opts.get("female", rng.randf() < 0.45)
	var color: Color = opts.get("color", NONE)
	var s := {"top": NONE, "bottom": NONE, "shoes": NONE, "hat": NONE, "gear": Color("17191c"), "hair": NONE}
	var parts: Array = []
	match role:
		"player":
			# reference sheet: charcoal tee, worn grey-blue jeans, dark sneakers, messy brown hair
			female = false
			_skin_named(s, "m", "hero_m")       # face projected from the reference sheet
			parts = [opts.get("top_part", "tee"), "jeans", "sneakers", "hair_messy", "eyelashes"]
			s.top = color if color.a > 0 else Color("2c2d30")
			s.bottom = Color("56657c")
			s.shoes = Color("2a2a2c")
			s.hair = Color(0.30, 0.21, 0.15, 0.9)
		"partner":
			# reference sheet: cropped charcoal tank, bootcut jeans, black sneakers, brown ponytail
			female = true
			_skin_named(s, "f", "hero_f")
			parts = ["tank", "jeans", "sneakers", "hair_ponytail", "eyelashes", "eyes_alt"]
			s.top = color if color.a > 0 else Color("2e2e31")
			s.bottom = Color("4f5d73")
			s.shoes = Color("1c1c1e")
			s.hair = Color(0.36, 0.25, 0.17, 0.9)
		"cop":
			if opts.get("swat", false):
				female = false
				_skin(s, "m", rng)
				parts = ["longsleeve", "suit_pants", "boots", "vest", "helmet", "mask", "face_hair"]
				s.top = Color("1b1f27")
				s.bottom = Color("1b1f27")
				s.shoes = Color("141416")
				s.gear = Color("262b33")
			else:
				var g := "f" if female else "m"
				_skin(s, g, rng)
				var tan := rng.randf() < 0.3
				s.top = Color("c8b48a") if tan else NAVY
				s.bottom = Color("3a3328") if tan else Color("161c2a")
				s.shoes = Color("111113")
				s.hat = s.bottom
				if female:
					parts = ["tee", "jeans", "shoes_black", "police_hat", "duty_belt", pick(["hair_ponytail", "hair_bob"], rng), "face_hair"]
				else:
					parts = [pick(["tee", "longsleeve"], rng), "suit_pants", "shoes_black", "police_hat", "duty_belt", "hair_buzz", "face_hair"]
				if rng.randf() < 0.3:
					parts.append("sunglasses")
				s.hair = pick(HAIR.slice(0, 6), rng)
		"guard", "truckguard":
			female = false
			_skin(s, "m", rng)
			s.top = Color("3a4a3a") if role == "truckguard" else Color("26324a")
			s.bottom = Color("1e2430")
			s.shoes = Color("111113")
			s.hat = s.top.darkened(0.2)
			s.gear = Color("22262b")
			parts = ["longsleeve", "suit_pants", "shoes_black", "cap", "duty_belt", "hair_buzz", "face_hair"] + (["vest"] if role == "truckguard" else [])
			s.hair = pick(HAIR.slice(0, 6), rng)
		"clerk":
			var g2 := "f" if female else "m"
			_skin(s, g2, rng)
			s.top = color if color.a > 0 else Color("e2434b")
			s.bottom = Color("2b3140")
			s.shoes = Color("1a1a1c")
			parts = ["tee", "jeans", "sneakers", pick(F_HAIR if female else M_HAIR, rng), "face_hair"]
			if not female and rng.randf() < 0.4:
				parts.append("cap")
				s.hat = s.top
				parts.erase("hair_afro")
			s.hair = pick(HAIR, rng)
		"teller", "staff":
			var g3 := "f" if female else "m"
			_skin(s, g3, rng)
			if female:
				parts = ["blouse", "skirt", "flats", pick(F_HAIR, rng), "face_hair"]
				s.top = pick([NONE, Color("f2f2ee"), Color("2c3e5c")], rng)
				s.bottom = pick([Color("1e2430"), Color("3a3f47")], rng)
			else:
				parts = ["suit_jacket", "suit_pants", "shoes_black", pick(["hair_side_part", "hair_buzz"], rng), "face_hair"]
				s.top = pick([NONE, Color("1e2430"), Color("4a3a2a")], rng)
				s.bottom = s.top if s.top.a > 0 else NONE
			s.hair = pick(HAIR, rng)
		"fence":
			female = false
			_skin(s, "m", rng, 1)
			parts = ["jacket", "jeans", "boots", "hair_buzz", "sunglasses", "face_hair"]
			s.top = color if color.a > 0 else Color("6d5a3c")
			s.bottom = Color("3a3f47")
			s.hair = Color("120d0a")
		_:
			# civilians / pedestrians / drivers: dressed for the Keys
			var g4 := "f" if female else "m"
			_skin(s, g4, rng)
			var top: String = pick(F_TOPS if female else M_TOPS, rng)
			var bottom: String
			if female:
				bottom = pick(["jeans", "jeans", "shorts", "leggings", "skirt"], rng)
				if top == "blouse":
					bottom = "skirt"
			else:
				bottom = "jeans" if rng.randf() < 0.85 else "suit_pants"
			var shoes: String = pick(["sneakers", "sneakers_white", "sneakers_white", "shoes_black", "flats" if female else "boots"], rng)
			var hair: String = pick(F_HAIR if female else M_HAIR, rng)
			parts = [top, bottom, shoes, hair, "face_hair"]
			s.top = pick(TOPS, rng) if rng.randf() < 0.85 else NONE
			s.bottom = pick(BOTTOMS, rng) if (bottom != "jeans" or rng.randf() < 0.5) else NONE
			s.shoes = pick(SHOES, rng) if rng.randf() < 0.7 else NONE
			s.hair = pick(HAIR, rng)
			var r := rng.randf()
			if not female and r < 0.14:
				parts.append("cap")
				s.hat = pick(HATS, rng)
			elif r < 0.18:
				parts.append("beanie")
				s.hat = pick(HATS, rng)
			if rng.randf() < 0.16:
				parts.append("sunglasses")
	# hats sit on short hair only
	if parts.has("cap") or parts.has("beanie") or parts.has("police_hat") or parts.has("helmet"):
		for h in ["hair_afro", "hair_long", "hair_side_part", "hair_messy", "hair_bob"]:
			if parts.has(h):
				parts.erase(h)
				parts.append("hair_buzz" if not female else "hair_ponytail")
	if parts.has("helmet") or parts.has("mask"):
		parts = parts.filter(func(p): return not String(p).begins_with("hair_"))
	s.g = "f" if female else "m"
	s.female = female
	var uniq: Array = []
	for p in parts:
		if p != "" and not uniq.has(p):
			uniq.append(p)
	uniq.sort()
	s.parts = uniq
	return s
