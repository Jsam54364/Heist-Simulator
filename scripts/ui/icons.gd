class_name Icons
extends RefCounted
## HUD icon set (COD-Mobile-style line/solid glyphs). Stored as SVG source and rasterised
## at runtime with Image.load_svg_from_string at the size the button actually needs, so
## they stay sharp on any phone density. White on transparent: tint with modulate.

const S := "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64' width='64' height='64'>%s</svg>"
const L := " fill='none' stroke='#fff' stroke-linecap='round' stroke-linejoin='round' "

const SRC := {
	# bullet: fire
	"fire": "<path d='M32 5 C40 11 43 19 43 27 V47 H21 V27 C21 19 24 11 32 5 Z' fill='#fff'/><rect x='19' y='50' width='26' height='9' rx='2' fill='#fff'/>",
	# scope: aim down sights
	"ads": "<circle cx='32' cy='32' r='19'" + L + "stroke-width='4.5'/><path d='M32 4 V17 M32 47 V60 M4 32 H17 M47 32 H60'" + L + "stroke-width='4.5'/><circle cx='32' cy='32' r='3.5' fill='#fff'/>",
	# circular arrow around a round: reload
	"reload": "<path d='M51 27 A20 20 0 1 0 47 46'" + L + "stroke-width='5'/><path d='M57 18 L52 33 L40 25 Z' fill='#fff'/><path d='M32 20 C35 23 36 26 36 29 V42 H28 V29 C28 26 29 23 32 20 Z' fill='#fff'/>",
	# crouching figure
	"crouch": "<circle cx='37' cy='12' r='7' fill='#fff'/><path d='M33 22 L24 36 L41 39 L39 56 M24 36 L20 56 M31 27 L45 31'" + L + "stroke-width='7'/>",
	# jump: double chevron over a ground line
	"jump": "<path d='M15 31 L32 15 L49 31 M15 46 L32 30 L49 46'" + L + "stroke-width='7'/><path d='M12 57 H52'" + L + "stroke-width='4'/>",
	# running figure: sprint
	"sprint": "<circle cx='40' cy='10' r='6.5' fill='#fff'/><path d='M36 20 L28 36 L38 44 L34 58 M28 36 L15 43 M34 23 L45 30 L53 25 M34 23 L23 25 L16 33'" + L + "stroke-width='6'/>",
	# pistol (facing right)
	"pistol": "<path d='M7 17 H55 V28 H51 V31 H35 L37 35 C37 39 33 41 29 39 L27 31 H25 L21 53 H9 L15 28 H7 Z' fill='#fff'/>",
	# holster: pistol pointing down into a pouch
	"holster": "<path d='M20 6 H34 V40 H20 Z' fill='#fff'/><path d='M34 10 H46 L44 22 H34 Z' fill='#fff'/><path d='M14 30 H40 L36 58 H18 Z'" + L + "stroke-width='4.5'/>",
	# balaclava
	"mask": "<path fill-rule='evenodd' fill='#fff' d='M32 5 C18 5 11 17 11 30 C11 47 20 59 32 59 C44 59 53 47 53 30 C53 17 46 5 32 5 Z M21 24 H43 A4.5 4.5 0 0 1 43 33 H21 A4.5 4.5 0 0 1 21 24 Z M26 44 C26 41 38 41 38 44 C38 47 26 47 26 44 Z'/>",
	# eye: focus / scan
	"focus": "<path fill-rule='evenodd' fill='#fff' d='M3 32 C14 14 50 14 61 32 C50 50 14 50 3 32 Z M32 21 A11 11 0 1 0 32.01 21 Z'/><circle cx='32' cy='32' r='5' fill='#fff'/>",
	# megaphone: shout
	"shout": "<path d='M8 25 H20 L42 12 V52 L20 39 H8 Z' fill='#fff'/><path d='M14 40 L19 55 H27 L23 40 Z' fill='#fff'/><path d='M49 23 C54 28 54 36 49 41 M54 16 C62 25 62 39 54 48'" + L + "stroke-width='4'/>",
	# figure with raised arms: surrender
	"surrender": "<circle cx='32' cy='23' r='7' fill='#fff'/><path d='M32 31 V46 L25 60 M32 46 L39 60 M32 34 L19 20 L17 6 M32 34 L45 20 L47 6'" + L + "stroke-width='6'/>",
	# eye with slash: hide
	"hide": "<path fill-rule='evenodd' fill='#fff' d='M3 32 C14 14 50 14 61 32 C50 50 14 50 3 32 Z M32 22 A10 10 0 1 0 32.01 22 Z'/><path d='M10 56 L54 8'" + L + "stroke='#000' stroke-width='9'/><path d='M10 56 L54 8'" + L + "stroke-width='5'/>",
	# accelerator pedal
	"gas": "<path fill-rule='evenodd' fill='#fff' d='M22 6 H42 A6 6 0 0 1 48 12 V48 A6 6 0 0 1 42 54 H22 A6 6 0 0 1 16 48 V12 A6 6 0 0 1 22 6 Z M22 14 V18 H42 V14 Z M22 24 V28 H42 V24 Z M22 34 V38 H42 V34 Z M22 44 V48 H42 V44 Z'/><path d='M26 60 H38'" + L + "stroke-width='4'/>",
	# brake pedal (wide)
	"brake": "<path fill-rule='evenodd' fill='#fff' d='M14 16 H50 A6 6 0 0 1 56 22 V42 A6 6 0 0 1 50 48 H14 A6 6 0 0 1 8 42 V22 A6 6 0 0 1 14 16 Z M16 26 V30 H48 V26 Z M16 35 V39 H48 V35 Z'/><path d='M26 56 H38'" + L + "stroke-width='4'/>",
	# handbrake: (P) dashboard symbol
	"handbrake": "<circle cx='32' cy='32' r='17'" + L + "stroke-width='4.5'/><path d='M10 18 C4 26 4 38 10 46 M54 18 C60 26 60 38 54 46'" + L + "stroke-width='4.5'/><path d='M27 42 V22 H34 A6 6 0 0 1 34 34 H27'" + L + "stroke-width='4.5'/>",
	# horn
	"horn": "<path d='M6 26 H16 L40 13 V51 L16 38 H6 Z' fill='#fff'/><path d='M47 22 L57 16 M48 32 H60 M47 42 L57 48'" + L + "stroke-width='4.5'/>",
	# door with arrow out: exit vehicle
	"exit": "<path d='M36 18 V8 H10 V56 H36 V46'" + L + "stroke-width='5'/><path d='M24 32 H58 M48 22 L58 32 L48 42'" + L + "stroke-width='5'/>",
	"left": "<path d='M42 10 L18 32 L42 54 Z' fill='#fff' stroke='#fff' stroke-width='4' stroke-linejoin='round'/>",
	"right": "<path d='M22 10 L46 32 L22 54 Z' fill='#fff' stroke='#fff' stroke-width='4' stroke-linejoin='round'/>",
	"pause": "<rect x='16' y='12' width='11' height='40' rx='3' fill='#fff'/><rect x='37' y='12' width='11' height='40' rx='3' fill='#fff'/>",
	# folded map
	"map": "<path d='M6 14 L22 8 L42 14 L58 8 V50 L42 56 L22 50 L6 56 Z M22 8 V50 M42 14 V56'" + L + "stroke-width='4.5'/>",
	# hand: interact
	"hand": "<path d='M22 34 V14 A4 4 0 0 1 30 14 V30 M30 12 A4 4 0 0 1 38 12 V30 M38 15 A4 4 0 0 1 46 15 V32 M46 22 A4 4 0 0 1 54 22 V38 C54 50 46 58 36 58 C28 58 22 54 18 46 L11 34 A4 4 0 0 1 18 30 L22 36'" + L + "stroke-width='4'/>",
	# steering wheel (settings / steering mode)
	"wheel": "<circle cx='32' cy='32' r='24'" + L + "stroke-width='5'/><circle cx='32' cy='32' r='6' fill='#fff'/><path d='M8 30 H26 M38 30 H56 M32 38 V56'" + L + "stroke-width='5'/>",
	# siren light (police car)
	"siren": "<path d='M18 44 V30 A14 14 0 0 1 46 30 V44 Z' fill='#fff'/><rect x='12' y='46' width='40' height='8' rx='2' fill='#fff'/><path d='M32 4 V10 M10 14 L14 18 M54 14 L50 18'" + L + "stroke-width='4'/>",
	# duck / hide in car: arrow down into a car silhouette
	"duck": "<path d='M32 4 V24 M24 16 L32 24 L40 16'" + L + "stroke-width='5'/><path d='M8 46 L14 34 H50 L56 46 V54 H8 Z' fill='#fff'/>",
}

static var _cache := {}

## texture of icon `name` rasterised at `px` pixels square
static func tex(name: String, px: int) -> Texture2D:
	px = clampi(px, 16, 256)
	var key := "%s@%d" % [name, px]
	if _cache.has(key):
		return _cache[key]
	if not SRC.has(name):
		return null
	var img := Image.new()
	var err := img.load_svg_from_string(S % SRC[name], float(px) / 64.0)
	if err != OK:
		_cache[key] = null
		return null
	var t := ImageTexture.create_from_image(img)
	_cache[key] = t
	return t
