# Heist Simulator (Godot 4)

A GTA-style heist sandbox: case a store, mask up, hold the clerk at gunpoint, crack
the safe, smash jewelry cases, hit the bank vault while the armored truck is
unloading, then lose the cops and launder the take. Godot 4.7 port of the
web prototype, set up so the graybox can grow into a good-looking game.

**Phone download:** every push to `main` builds an Android APK. Open
<https://github.com/Jsam54364/Heist-Simulator/releases/tag/latest-apk> on your phone and tap
`heist-simulator.apk`. New builds install over old ones (same debug key).

## Controls

| Touch | Keyboard / mouse |
|---|---|
| Left side: floating joystick (walk / steer) | WASD |
| Right side: drag to look | Mouse (click to capture, Esc to release) |
| Action pills (right) | E / Q / Z |
| GUN · FIRE · MASK · FOCUS · RUN | R · F or click · M · V · Shift |
| GAS · BRAKE · DRIFT (in a car) | W · S · Space |
| Tap the radar for the map, II to pause | T map, Esc pause |

## What's in the game

- **Targets:** Quik-E 24/7 (low security), Diamond Dash Jewelers (medium), Leonida Federal Savings (high).
- **Robbery systems:** clerks emptying registers at gunpoint, guard surrender, wannabe heroes, silent alarms,
  safe codes (sticky notes, computers, searching guards), keys, snap gun, C4 on reinforced doors, security
  cameras (local DVR vs cloud), dye packs in marked bills, an armored truck delivery that opens the vault on a timer.
- **Heat:** witnesses, face/outfit/car recognition, wanted stars, search circle, patrols, police on foot and in
  cars, helicopter at 3+ stars, busts. Hide in the parking garage, change outfit in your car's trunk, Pay 'N' Spray.
- **Economy:** cash vs bank (deposit at ATMs), duffel bag weight, partner carrying a second bag, the fence buys
  jewelry and launders marked bills, and sells tools.
- **Driving:** raycast-suspension cars on Jolt physics (spring/damper, tyre friction circle, handbrake drifts,
  anti-roll, downforce), traffic AI, police pursuit AI.

## Project layout

```
scenes/main.tscn            Root scene: WorldEnvironment, Sun, Camera (+ scripts/main.gd builds the rest)
assets/env/                 day_environment.tres - sky, tonemapping (AgX), glow, fog, SSAO...
assets/materials/           ORMMaterial3D / StandardMaterial3D .tres (PBR: albedo + normal + ORM)
assets/textures/            Generated PBR texture sets (tools/gen_assets.py)
assets/shaders/             city_uber (merged city material), far_city (HLOD), car_parts, water, minimap
assets/audio/               Generated sound effects + loops
scripts/autoload/           Game (state), Settings (quality presets), Sfx (audio)
scripts/world/              City generator, robbery sites, chunked mesh builder, LOD streamer, nav grid, road graph, materials
scripts/actors/             Character, Player, NPC AI, Police
scripts/vehicles/           Vehicle physics + procedural car models
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
  1. Replace the box characters with rigged glTF models + an AnimationTree (the gameplay code only talks to
     `Character.pose`, `speed_now`, `show_gun` and the mask flag).
  2. Replace procedural cars with modelled glTF cars (keep `Vehicle.gd`, swap `CarModel.build`).
  3. Bake lightmaps (LightmapGI) for interiors, add decals (grime, puddles, graffiti), more props.
  4. Day/night cycle: rotate the Sun, drive sky colours + street lamp emission from a time-of-day curve.
  5. To try Forward+ features on a high-end phone: Project Settings → Rendering → Renderer →
     `rendering_method.mobile` = `forward_plus`.

## Performance: how the world stays fast on phones

- **World LOD streaming** (`scripts/world/world_streamer.gd`): the city is cut into 50 m chunks
  (one block each). Around the camera each chunk's layers are built into meshes on demand, within a
  2.5 ms-per-frame budget, and freed again when you move away:
  `detail` props (~45 m) → `interior` rooms (~65 m) → full-detail `main` buildings and streets (~95 m)
  → `mid` palms/poles (~130 m). Beyond that every block is a **far HLOD**: one textured box per
  building plus flat ground, one draw call per block, using a 4×2 texture atlas and a cheap shader.
  Radii scale with the graphics preset.
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
