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
assets/shaders/             water.gdshader (ocean), minimap.gdshader (radar)
assets/audio/               Generated sound effects + loops
scripts/autoload/           Game (state), Settings (quality presets), Sfx (audio)
scripts/world/              City generator, robbery sites, merged-mesh builder, nav grid, road graph, materials
scripts/actors/             Character, Player, NPC AI, Police
scripts/vehicles/           Vehicle physics + procedural car models
scripts/gameplay/           Robbery systems, traffic, FX, follow camera
scripts/ui/                 HUD, touch controls, menus, map
scripts/tests/              smoke.gd (headless gameplay test), shots.gd (screenshot tour)
tools/                      Asset generators (Python) and the environment generator
.github/workflows/          Android APK build + smoke test
android/debug.keystore      Shared debug key so APKs update in place (not secret: debug only)
```

## Graphics: how it's set up, and where to push it

- **Renderers:** Forward+ on desktop; Mobile renderer on Android (Vulkan). Android falls back to
  Compatibility (GLES3) automatically on very old phones.
- **Quality presets** (`scripts/autoload/settings.gd`, Pause → Graphics): Low / Medium / High / Ultra control
  MSAA/TAA/FXAA, render scale, shadow atlas size + cascades + distance, glow, fog distance and LOD.
  SSAO, SSIL, SSR, SDFGI and volumetric fog switch on automatically on Forward+ (High/Ultra).
  Phones default to Medium, desktops to High.
- **Materials are PBR** (albedo + normal + ORM) with per-instance vertex-colour tint, so a facade texture is
  reused across buildings. Swap any `assets/textures/*_albedo/_normal/_orm.png` for a scanned/photo texture
  set and every building using it upgrades.
- **Static geometry** is merged per 48 m chunk (one mesh per chunk, one surface per material): few draw
  calls, working frustum culling, and each chunk stays under the Mobile renderer's 8-lights-per-mesh limit.
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
