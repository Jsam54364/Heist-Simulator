extends Node
## Global game state shared by every system (the port of the web build's `G`).

signal notified(text: String, kind: String)
signal shop_requested
signal wasted_or_busted(kind: String, why: String)

const OUTFITS := [
	{"name": "Blue hoodie", "color": Color("2f6fe0")},
	{"name": "Green jacket", "color": Color("2fa04f")},
	{"name": "Tan coat", "color": Color("c9a26b")},
	{"name": "Red tracksuit", "color": Color("d23c3c")},
]
const CAR_COLORS := [Color("e0e0e0"), Color("2b2b2b"), Color("c0392b"), Color("2471a3"), Color("d4ac0d"), Color("1e8449"), Color("8e44ad"), Color("e67e22")]
const CAR_COLOR_NAMES := ["white", "black", "red", "blue", "yellow", "green", "purple", "orange"]

# world layout
const WORLD := {"min_x": -150.0, "max_x": 200.0, "min_z": -150.0, "max_z": 150.0, "shore": 181.0}
const ROAD_X := [-100.0, -50.0, 0.0, 50.0, 100.0, 150.0]
const ROAD_Z := [-100.0, -50.0, 0.0, 50.0, 100.0]
const ROAD_SPAN_X := [-150.0, 150.0]
const ROAD_SPAN_Z := [-150.0, 150.0]

const L_WORLD := 1
const L_GLASS := 2
const L_VEHICLE := 4
const L_CHAR := 8
const L_GROUND := 16

var t := 0.0
var running := false
var paused := false

var money := {"bank": 0.0, "cash": 250.0}
var bag: Array = []
var partner_bag: Array = []
var bag_cap := 24.0
var tools := {"snap": false, "c4": 0, "jammer": false, "suppressor": false, "armor": false}
var known_codes := {}
var keys := {}
var wanted := {"stars": 0, "last": Vector3.ZERO, "seen_ago": 99.0, "clear": 0.0, "searching": false, "search_pt": Vector3.ZERO, "search_pick": 0.0, "suspicion": 0.0, "spawn_t": 0.0, "patrol_t": 8.0}
var heat := {"face": 0.0, "outfit": -1, "outfit_t": 0.0, "car_id": -1, "car_color": -1, "car_t": 0.0}
var focus := false
var outfit := 0
var spare_outfit := 1
var stats := {"laundered": 0.0, "robberies": 0, "best": 0.0}

# live references (set by Main)
var main: Node = null
var world: Node3D = null
var player = null
var partner = null
var player_car = null
var robbery = null
var police = null
var sites: Array = []
var chars: Array = []
var cars: Array = []
var doors: Array = []
var interactables: Array = []
var buildings: Array = []
var footprints: Array = []
var noise: Array = []
var cur_building = null
var in_garage := false
var garage_bounds := Rect2(-40, 12, 26, 26)

func notify(text: String, kind := "") -> void:
	notified.emit(text, kind)

func add_noise(pos: Vector3, r: float) -> void:
	noise.append({"pos": pos, "r": r, "t": t})

func ground_y(x: float, z: float) -> float:
	## Height of the walkable surface (sidewalk slabs are 0.15 m, roads ~0.03 m).
	if x > 156.0:
		return 0.04 if x > 174.0 else 0.12
	for r in ROAD_X:
		if absf(x - r) < 6.0:
			return 0.02
	if x < ROAD_SPAN_X[1] + 6.0:
		for r in ROAD_Z:
			if absf(z - r) < 6.0:
				return 0.045
	return 0.15

func reset_state() -> void:
	money = {"bank": 0.0, "cash": 250.0}
	bag.clear()
	partner_bag.clear()
	tools = {"snap": false, "c4": 0, "jammer": false, "suppressor": false, "armor": false}
	known_codes.clear()
	keys.clear()
