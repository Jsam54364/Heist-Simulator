extends Node
## Sound effects: a pool of one-shot players plus named loops (alarm, siren, engine...).

const ONE_SHOTS := ["shot", "shot_suppressed", "npc_shot", "glass", "cash", "boom", "kick", "crash", "click", "beep", "bad", "good", "hit", "drill"]
const LOOPS := ["alarm_loop", "siren_loop", "engine_loop", "screech_loop", "wind_loop"]

var streams := {}
var pool: Array[AudioStreamPlayer] = []
var loops := {}
var next := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for n in ONE_SHOTS + LOOPS:
		var s = load("res://assets/audio/%s.wav" % n)
		if s:
			streams[n] = s
	for i in 14:
		var p := AudioStreamPlayer.new()
		add_child(p)
		pool.append(p)
	for n in LOOPS:
		var p := AudioStreamPlayer.new()
		p.stream = streams.get(n)
		p.volume_db = -80.0
		add_child(p)
		loops[n.replace("_loop", "")] = p

func play(name: String, vol := 1.0, pitch := 1.0) -> void:
	if not streams.has(name) or vol <= 0.01:
		return
	var p := pool[next]
	next = (next + 1) % pool.size()
	p.stream = streams[name]
	p.volume_db = linear_to_db(clampf(vol, 0.0, 2.0)) - 4.0
	p.pitch_scale = pitch * randf_range(0.96, 1.04)
	p.play()

func set_loop(name: String, vol: float, pitch := 1.0) -> void:
	var p: AudioStreamPlayer = loops.get(name)
	if p == null:
		return
	if vol <= 0.01:
		if p.playing:
			p.stop()
		return
	if not p.playing:
		p.play()
	p.volume_db = lerpf(p.volume_db, linear_to_db(vol) - 6.0, 0.2)
	p.pitch_scale = maxf(0.05, pitch)

func stop_loops() -> void:
	for p in loops.values():
		p.stop()
