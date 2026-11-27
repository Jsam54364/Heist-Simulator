# Heist Simulator (Godot 4)

A GTA-style heist sandbox set on **Key Lento** in the Leonida Keys (modelled on GTA 6's
starting area): case a store, mask up, hold the clerk at gunpoint, crack the safe, smash
jewelry cases, hit the bank vault while the armored truck is unloading, then lose the
Sheriff's office and launder the take. Godot 4.7, set up so the graybox can grow into a
good-looking game.

**Phone download:** every push to `main` builds an Android APK. Open
<https://github.com/Jsam54364/Heist-Simulator/releases/tag/latest-apk> on your phone and tap
`heist-simulator.apk`. New builds install over old ones (same debug key).

## Controls

Third-person-shooter layout modelled on COD Mobile (on foot) and PUBG/COD vehicle controls.

| Touch | Keyboard / mouse |
|---|---|
| Left: floating joystick - push past the ring to lock sprint | WASD, Shift sprint |
| Right side: drag to look (also drag off FIRE while shooting) | Mouse (click to capture, Esc to release) |
| FIRE (right + optional left) · ADS scope · RELOAD · JUMP · CROUCH | Click · hold right mouse · R · Space · C |
| Weapon card (bottom): tap to draw / holster, shows the magazine | R draw, X holster |
| Utility row: MASK · FOCUS · SHOUT · GIVE UP | M · V · G · B |
| Interaction pills (centre-right) | E / Q / Z |
| Car: ◀ ▶ steering buttons (or joystick, see Pause > Steering) · GAS · BRAKE · DRIFT · HORN · EXIT · HIDE | W · S · A/D · Space · N · E · H |
| Tap the radar for the map, II to pause | T map, Esc pause |

## What's in the game

- **Map - Key Lento:** one long, narrow key (~2.6 km x 0.3 km) with Route 1 running its length, the bay
  (Blackwater Sound) to the north and the Atlantic to the south. You start at Jason-style **stilt house** out on the
  bay (the safehouse) with your pickup on the shore. Along the strip: the town with the three targets, Brian's Boat
  Works & Marina (dry-stack racks, finger docks - Brian is a second fence), Key Lento Marina Club, the Rusty Anchor,
  Cheeky Mutineer and Marbles bars, The Captain's Cabins motel, two Arrow gas stations, the Wonder Whale statue and
  gift shop, Hamilton clinic, community center, the Sheriff's station (police dispatch), cell towers, canal
  neighbourhoods of stilt houses with docks and boats, beaches, "Welcome to the Keys" / "Key Lento" signs, and the
  bridges off the key (closed, like the real starting area).
- **Targets:** 24/7 Supermarket (low security), Diamond Dash Jewelers (medium), Leonida Federal Savings (high).
- **Robbery systems:** clerks emptying registers at gunpoint, guard surrender, wannabe heroes, silent alarms,
  safe codes (sticky notes, computers, searching guards), keys, snap gun, C4 on reinforced doors, security
  cameras (local DVR vs cloud), dye packs in marked bills, an armored truck delivery that opens the vault on a timer.
- **Police (GTA 6 style):** 6 stars with states - *response* (hollow stars: a 911 call / alarm / stolen-car tracker
  came in, units drive over from the station or patrols with a real ETA and don't know who you are), *pursuit*
  (solid: they see you), *lost* (flashing), *search* (red search area that grows; leave it or hide). Escapes leave
  **hot zones** with extra patrols. Heat icons: face, outfit, car, gun, partner, filmed/CCTV. Escalation: 1-2 stars
  patrol cars, 3 K9 unit (the dog follows your scent, bites, sniffs you out of a hiding car) and Route 1
  roadblocks, 4 SWAT van, spike strips and the helicopter (shoot it enough and it pulls back), 5-6 more units and a
  heli marksman. PIT manoeuvres, tyre shooting, arrests of unarmed suspects, surrendering, and a **criminal
  profile** (Professional / Hardened / Violent / Psycho) that decides how fast they shoot - Psychos can't surrender.
- **People & crowd control:** every civilian has bravery / nervousness / phone / filmer traits. Crimes create
  witnesses who flee, cower, film you (face gets posted) or **call 911** - the call takes seconds and can be stopped
  by aiming at them or shouting. In robberies: SHOUT puts everyone on the floor, intimidation wears off when nobody
  covers them, unwatched hostages sneak for the door or make a quiet call, heroes jump you; **zip-tie** hostages,
  take wallets, or let your partner hold the crowd. Pedestrians react to bodies, gunfire and speeding cars (they dive
  out of the way), drivers floor it or bail out at gunpoint; greet or antagonize locals to move witnesses along.
- **Economy:** cash vs bank (deposit at ATMs), duffel bag weight, partner carrying a second bag, two fences buy
  jewelry and launder marked bills, and sell tools (snap gun, C4, jammer, suppressor, armor, zip-ties).
- **Driving:** each car is ONE rigid body with ONE convex collider, driven by a two-axle tyre model: weight
  transfer, slip-angle grip that peaks and falls off, friction circle, RWD/FWD/AWD, handbrake drifts,
  speed-sensitive steering, a light stability assist, visible body roll/pitch, burst tyres, cars that sink in the
  sea. The whole island's ground is a single seamless heightfield so nothing snags at speed.

## Project layout

```
scenes/main.tscn            Root scene: WorldEnvironment, Sun, Camera (+ scripts/main.gd builds the rest)
assets/env/                 day_environment.tres - sky, tonemapping (AgX), glow, fog, SSAO...
assets/materials/           ORMMaterial3D / StandardMaterial3D .tres (PBR: albedo + normal + ORM)
assets/textures/            Generated PBR texture sets (tools/gen_assets.py)
assets/shaders/             city_uber (merged city material), far_city (HLOD), car_parts, water, minimap
assets/audio/               Generated sound effects + loops
scripts/autoload/           Game (state), Settings (quality presets), Sfx (audio)
scripts/world/              Key Lento generator (keys_gen.gd), robbery sites, chunked mesh builder, LOD streamer with
                            threaded chunk generation, local nav window, Route 1 road graph, materials
scripts/actors/             Character, Player, NPC AI, Police, HumanModel (assembly + AnimationTree), Outfits
assets/models/              human_m.glb / human_f.glb (rig + parts + 41 clips each), props.glb
assets/characters/          Character atlases (albedo / normal / hair) + humans.json part catalogue
scripts/vehicles/           Vehicle physics + car models (assets/models/cars.glb)
scripts/gameplay/           Robbery systems, traffic, FX, follow camera
scripts/ui/                 HUD, touch controls, menus, map
scripts/tests/              smoke.gd (headless gameplay test), shots.gd (screenshot tour), profile.gd (performance)
tools/                      Asset generators (Python) and the environment generator
.github/workflows/          Android APK build + smoke test
android/debug.keystore      Shared debug key so APKs update in place (not secret: debug only)
```

## Graphics: how it's set up, and where to push it

- **Renderers:** Forward+ on desktop; Mobile renderer on Android (Vulkan). Android falls back to
  Compatibility (GLES3) automatically on very old phones.
- **Quality presets** (`scripts/autoload/settings.gd`, Pause → Graphics): Low / Medium / High / Ultra control
  MSAA/TAA, internal resolution, shadow atlas size + cascades + distance, glow, fog distance and LOD distances.
  SSAO, SSIL, SSR, SDFGI and volumetric fog switch on automatically on Forward+ (High/Ultra).
  Phones default to Medium, desktops to High.
- **Materials are PBR** (albedo + normal + ORM) with per-instance vertex-colour tint, so a facade texture is
  reused across buildings. Swap any `assets/textures/*_albedo/_normal/_orm.png` for a scanned/photo texture
  set, rerun `tools/gen_city_arrays.py` + `tools/gen_far_atlas.py`, and every building using it upgrades.
- **Interiors** get warm ceiling lights and an interior ReflectionProbe (local ambient + reflections on
  marble/tile floors), so they are not lit by the blue sky.
- **Next visual steps** (in rough order of payoff):
  1. Bake lightmaps (LightmapGI) for interiors, add decals (grime, puddles, graffiti), more props.
  2. Day/night cycle: rotate the Sun, drive sky colours + street lamp emission from a time-of-day curve.
  3. To try Forward+ features on a high-end phone: Project Settings → Rendering → Renderer →
     `rendering_method.mobile` = `forward_plus`.

## Performance: how the world stays fast on phones

- **World LOD streaming** (`scripts/world/world_streamer.gd`): the city is cut into 50 m chunks
  (one block each). Around the camera each chunk's layers are built into meshes on demand, within a
  2.5 ms-per-frame budget, and freed again when you move away:
  `detail` props (~45 m) → `interior` rooms (~65 m) → full-detail `main` buildings and streets (~95 m)
  → `mid` palms/poles (~130 m). Beyond that every block is a **far HLOD**: one textured box per
  building plus flat ground, one draw call per block, using a 4×2 texture atlas and a cheap shader.
  Radii scale with the graphics preset.
- **Lazy, threaded generation:** Key Lento is laid out at startup in ~50 ms (land mask, Route 1, lots,
  landmarks, far-LOD boxes, minimap) but no meshes are built. When a chunk comes within ~230 m of you its
  geometry and colliders are generated on a `WorkerThreadPool` thread; the main thread only merges the result
  and creates the collision shapes. Chunks ~420 m behind you drop their generated data again (the far HLOD
  stays). Pedestrians and Route 1 traffic live in a ring around you (spawned out of sight, despawned behind).
- **Local navigation window:** people path-find on a 192 m AStarGrid2D window that follows you (rebuilt in
  ~2.5 ms; pushed ahead of you when driving so it rarely rebuilds).
- **Merged city material** (`assets/shaders/city_uber.gdshader`): 26 surface types (facades,
  asphalt, sidewalks, marble, paint, foliage...) live in three Texture2DArrays, so a whole block
  renders in one draw call instead of ~20. Car trim/lights/wheels share one material too
  (`car_parts.gdshader`), and far people are one mesh instead of three.
- **Occlusion culling**: every building is an occluder, so blocks hidden behind other blocks
  (and the people/cars in them) aren't drawn. Enterable shops only occlude above the ground floor.
- **Lighting cost**: room lights only affect rooms and people (render layers) and fade out with
  distance; small props don't cast shadows; people/cars drop shadows and detail with distance.
- **Actor LOD**: far people animate at half/quarter rate, think 4× less often and move without
  collision; far traffic rides its lane kinematically instead of simulating suspension; parked cars
  sleep; A* path searches are capped per tick and pedestrians take short local walks.
- **Resolution**: each preset targets an internal 3D height (Low 540p, Medium 720p, High 900p), so
  phones with very high-res screens don't render millions of extra pixels. **Auto resolution**
  (Pause menu) drops the 3D scale when the frame rate dips and raises it back when there's headroom.
  Frame rate can be capped at 60 or 30 (battery saver). Physics is capped at 3 steps per frame so a
  slow frame can't snowball.
- **Memory**: reflection atlas and shadow atlases sized for mobile (VRAM 434 MB → ~270 MB measured
  on desktop settings; less on phones).
- Turn on **Show FPS** in the pause menu to see fps, the current 3D scale and how many chunks are
  loaded / far / still loading.

Profiling: `godot --headless --path . --fixed-fps 60 res://scenes/tests/profile.tscn` prints script
time per system; run it with a display (`-- medium`) to also get draw calls / primitives / VRAM.
After changing textures run `tools/gen_assets.py`, `tools/gen_city_arrays.py`,
`tools/gen_far_atlas.py`, then `tools/write_imports.py`.

## Characters

People are built from CC0 **MakeHuman** assets (base mesh, morph targets, game-resolution proxy
bodies, clothes, shoes, hair cards, eyebrows/eyelashes, eyes, photo skins, default rig weights - see
`assets/characters/CREDITS.md`) by `tools/blender/make_mh_humans.py` (Blender as a Python module):

* bodies are morphed toward the reference sheets in `tools/reference/` (lean athletic male ~1.81 m,
  athletic female ~1.70 m); the player's and partner's faces are projected from those sheets onto
  their heads (affine fit to the eyes + mouth), and their whole-body skin is tone-matched to the face
* our game skeleton (with finger joints) sits on MakeHuman's joint centroids; MakeHuman's painted
  weights are mapped onto it; the rest pose is normalised so all 42 animation clips (keyed ones IK-authored in
  `human_anims.py` / `human_library.py`) bake onto both bodies
* locomotion (idle, walk, jog, sprint, panic run, crouch walk, the aim set incl. 4-way strafes, jumps,
  punch, wave) is real **motion capture** from the CMU Graphics Lab database, retargeted onto our rig in
  `mocap.py`: per-bone rest-direction alignment, hips scaled by leg-length ratio, travel removed so the
  clips play in place (the measured ground speed goes to `humans.json` and the AnimationTree matches
  playback speed to it), loops found by pose/velocity matching and closed with slerped residuals; armed
  clips keep the mocap legs and layer a keyed aim pose on top
* joints deform like real ones: twist bones spread forearm/upper-arm/thigh twist (swing-twist split),
  and half-angle elbow/knee helper bones take the shared skin weight so bent joints keep their volume
* outfits mix and match: suits are split into tops/bottoms, each with a coverage bit so hidden skin is
  removed when the game assembles a person into ONE skinned mesh with two draw calls (opaque atlas +
  alpha-tested hair); garments are tinted per character in `character.gdshader`

```
bash tools/blender/fetch_makehuman.sh                 # CC0 asset data (once, not in this repo)
bash tools/blender/fetch_mocap.sh                     # the 11 CMU mocap clips used (once), export CMU_BVH
pip install bpy pillow numpy
python tools/blender/make_mh_humans.py                # -> assets/models/human_*.glb, assets/characters/*
```

## Vehicles

`tools/blender/make_cars.py` models every vehicle (sedan, coupe, SUV, pickup with bed cover, taxi,
police interceptor with light bar and push bar, SWAT van, armoured truck, the police helicopter and
a shared alloy wheel) into `assets/models/cars.glb` + `cars.json`:

* bodies are lofted through cross-section stations taken from real proportions for each class
  (bumper, hood, cowl, windshield, roof, rear glass, deck), subdivided, wheel arches boolean-cut with
  dark liners, door shut lines, A/B pillars, glass bands, mirrors, handles, swept head lights, tail
  lights, grille, plates
* each cabin has a lining, seats, dash, console and a steering wheel placed where the seated driver's
  hands are; seat hip points (and a seat-back recline for low cars) go to `cars.json`, so people sit
  in the seats with their feet in the footwell
* one paint surface per car (colour swapped at runtime), shared glass, and all trim/lights/wheels on
  the single `car_parts` shader (tail lights brighten on braking via an instance uniform)

`python tools/blender/make_cars.py`; check them with `res://scenes/tests/garage.tscn` (renders to /tmp).

## Building

CI does everything (`.github/workflows/android.yml`): installs Godot 4.7.2 + export templates (cached),
imports the project, runs the headless smoke test (results in the run summary), exports a signed debug
APK, verifies the signature, uploads it as an artifact and republishes the `latest-apk` prerelease.

Locally (optional):

```
godot --headless --path . --import
godot --headless --path . --fixed-fps 60 res://scenes/tests/smoke.tscn     # gameplay smoke test
godot --path . res://scenes/tests/shots.tscn -- high                        # screenshot tour -> /tmp
python3 tools/gen_assets.py && python3 tools/write_imports.py && python3 tools/write_materials.py
```
