"""The full clip list for the shared human rig (see human_anims.py for conventions).

Clip names are what the game's AnimationTree uses. Loops end where they start.
Timings follow the references: walk ~1 s per cycle (2 steps), jog 0.66 s, sprint 0.56 s
(less ground contact, more lean, more arm drive); jumps hold the anticipation and the
landing longer than the take-off; one-shots ease in and settle out.
"""
import math
from mathutils import Vector
import human_anims as HA
from human_anims import Pose, stand_pose, lerp_pose, ease, ARM_DOWN, ANKLE

FPS = HA.FPS


def P(**kw):
    p = stand_pose()
    for k, v in kw.items():
        p[k.replace("_L", ".L").replace("_R", ".R")] = v
    return p


def sym(p, **left):
    """Set a left-side value and its mirror on the right."""
    for k, v in left.items():
        k = k.replace("_L", ".L")
        p[k] = v
        m = Pose({k: v}).mirrored()
        p.update(m)
    return p


def keyed(A, name, frames, keys, loop, sample=None):
    """keys: [(frame, Pose)]. sample(f, pose) -> pose adds procedural motion on top."""
    A.begin(name)
    keys = sorted(keys, key=lambda k: k[0])
    if loop and keys[-1][0] != frames:
        keys.append((frames, keys[0][1]))
    if sample is None:
        for f, p in keys:
            A.apply(p, f)
    else:
        for f in range(0, frames + 1, 2):
            # piecewise eased interpolation between key poses, then the procedural layer
            for i in range(len(keys) - 1):
                f0, p0 = keys[i]
                f1, p1 = keys[i + 1]
                if f0 <= f <= f1:
                    t = (f - f0) / (f1 - f0) if f1 > f0 else 0.0
                    p = lerp_pose(p0, p1, ease(t))
                    break
            else:
                p = keys[-1][1]
            A.apply(sample(f, Pose(p)), f)
    return A.finish(name, frames, loop)


# ------------------------------------------------------------------ arm targets
# wrists, in the chest's rest frame (targets ride with the chest when it bends/twists)
AIM_R = {"pos": (-0.07, -0.44, 1.405), "aim": ((0.10, -0.99, 0.04), (0.35, 0.0, 0.94))}
AIM_L = {"pos": (0.005, -0.415, 1.38), "aim": ((-0.40, -0.91, 0.06), (0.15, -0.2, 0.97))}
POLE_AIM_R = {"pos": (-0.55, 0.10, 1.05)}
POLE_AIM_L = {"pos": (0.55, 0.10, 1.02)}


def aim_upper(pitch=0.0):
    up = Pose({
        "arm_ik.L": 1.0, "arm_ik.R": 1.0,
        "hand.R": AIM_R, "hand.L": AIM_L, "elbow_pole.R": POLE_AIM_R, "elbow_pole.L": POLE_AIM_L,
        "fingers.R": (78, 0, 0), "thumb.R": (25, 0, 0), "fingers.L": (65, 0, 0), "thumb.L": (20, 0, 0),
        "shoulder.L": (6, 0, -2), "shoulder.R": (6, 0, 2),
        "spine": (3 + pitch * 0.4, -4, 0), "chest": (1 + pitch * 0.45, -6, 0), "neck": (2 + pitch * 0.1, 6, 0), "head": (-2 + pitch * 0.05, 4, 0),
    })
    return up


def aim_stance(crouch=0.0):
    p = stand_pose()
    p["foot.L"] = {"pos": (0.12, -0.09, ANKLE.z), "rot": (0, 0, 10)}
    p["foot.R"] = {"pos": (-0.13, 0.11, ANKLE.z), "rot": (0, 0, -22)}
    p["hips_off"] = (0.0, 0.01, -0.035 - crouch)
    p["hips"] = (4 + crouch * 30, -8, 0)
    p.update(aim_upper())
    return p


def breathe(amp=1.0, rate=1.0, sway=0.006):
    def fn(f, p):
        t = f / FPS * rate
        b = math.sin(t * 2 * math.pi / 4.0)
        p["chest"] = tuple(p["chest"][i] + (b * 1.4 * amp if i == 0 else 0) for i in range(3))
        p["neck"] = tuple(p["neck"][i] + (-b * 0.8 * amp if i == 0 else 0) for i in range(3))
        for s in ("shoulder.L", "shoulder.R"):
            if s in p:
                p[s] = (p[s][0], p[s][1], p[s][2] + (b * 1.0 * amp if s.endswith("L") else -b * 1.0 * amp))
        hx, hy, hz = p.get("hips_off", (0, 0, 0))
        p["hips_off"] = (hx + sway * math.sin(t * 2 * math.pi / 8.0), hy, hz + 0.003 * b * amp)
        return p
    return fn


def build_all(A):
    out = []
    # ---------------- idle & locomotion ---------------------------------------
    idle = stand_pose()

    def idle_sample(f, p):
        p = breathe()(f, p)
        t = f / FPS
        look = math.sin(t * 2 * math.pi / 8.0)
        p["head"] = (p["head"][0] + 2 * math.sin(t * 1.3), p["head"][1] + 9 * look, p["head"][2])
        p["neck"] = (p["neck"][0], p["neck"][1] + 4 * look, p["neck"][2])
        return p
    out.append(keyed(A, "idle", 240, [(0, idle)], True, idle_sample))

    out.append(HA.gait(A, "walk", 1.35, 0.96, 0.6, 0.09, 0.022, 4, 22, 14, 7, 4, 0.018, "walk"))
    out.append(HA.gait(A, "jog", 3.6, 0.66, 0.38, 0.16, 0.035, 12, 36, 66, 10, 5, 0.012, "run", fists=True))
    out.append(HA.gait(A, "sprint", 6.2, 0.56, 0.33, 0.22, 0.04, 20, 52, 72, 12, 5, 0.01, "run", fists=True))
    panic_up = Pose()
    sym(panic_up, upper_arm_L=(55, 25, ARM_DOWN + 24), forearm_L=(118, 0, 0), fingers_L=(30, 0, 0))
    panic_up["neck"] = (-5, 0, 0)
    panic_up["head"] = (-10, 0, 0)
    out.append(HA.gait(A, "panic_run", 5.0, 0.6, 0.36, 0.18, 0.035, 14, 0, 0, 10, 6, 0.015, "run", upper=panic_up))
    # crouch (sneaking): hips 0.32 m lower, knees out, torso forward
    out.append(HA.gait(A, "crouch_walk", 1.3, 1.1, 0.65, 0.07, 0.012, 22, 14, 40, 6, 3, 0.02, "walk", crouch=0.32, stance_w=0.15))
    crouch = stand_pose()
    crouch["hips_off"] = (0, 0.04, -0.34)
    crouch["hips"] = (30, 0, 0)
    crouch["spine"] = (14, 0, 0)
    crouch["chest"] = (6, 0, 0)
    crouch["neck"] = (-18, 0, 0)
    crouch["head"] = (-14, 0, 0)
    crouch["foot.L"] = {"pos": (0.16, -0.10, ANKLE.z), "rot": (0, 0, 12)}
    crouch["foot.R"] = {"pos": (-0.16, 0.10, ANKLE.z), "rot": (0, 0, -12)}
    sym(crouch, upper_arm_L=(30, 10, ARM_DOWN + 6), forearm_L=(40, 0, 0))
    out.append(keyed(A, "crouch_idle", 120, [(0, crouch)], True, breathe(0.8)))

    # ---------------- armed (pistol) -------------------------------------------
    aim = aim_stance()
    out.append(keyed(A, "aim_idle", 120, [(0, aim)], True, breathe(0.5, sway=0.003)))
    aim_c = aim_stance()
    aim_c.update(crouch)
    aim_c.update(aim_upper())
    aim_c["chest"] = (2, -6, 0)
    aim_c["spine"] = (6, -4, 0)
    aim_c["neck"] = (-8, 6, 0)
    aim_c["head"] = (-8, 4, 0)
    out.append(keyed(A, "aim_crouch", 120, [(0, aim_c)], True, breathe(0.5, sway=0.002)))
    upper = aim_upper()
    out.append(HA.gait(A, "aim_walk_f", 1.6, 0.9, 0.62, 0.08, 0.016, 4, 0, 0, 5, 3, 0.01, "walk", upper=upper))
    out.append(HA.gait(A, "aim_walk_l", 1.4, 0.9, 0.62, 0.07, 0.014, 0, 0, 0, 3, 3, 0.0, "walk", upper=upper, dir_vec=(1, 0, 0)))
    out.append(HA.gait(A, "aim_walk_r", 1.4, 0.9, 0.62, 0.07, 0.014, 0, 0, 0, 3, 3, 0.0, "walk", upper=upper, dir_vec=(-1, 0, 0)))
    out.append(HA.gait(A, "aim_walk_b", 1.3, 0.96, 0.62, 0.07, 0.014, -2, 0, 0, 5, 3, 0.01, "walk", upper=upper, dir_vec=(0, 1, 0)))
    for nm, pitch in (("aim_up", -38.0), ("aim_down", 38.0)):
        p = aim_stance()
        p.update(aim_upper(pitch))
        out.append(keyed(A, nm, 2, [(0, p), (2, p)], False))
    # fire: hands kick up and back, settle (8 frames)
    kick = aim_stance()
    kr = dict(AIM_R)
    kl = dict(AIM_L)
    kr = {"pos": (AIM_R["pos"][0], AIM_R["pos"][1] + 0.035, AIM_R["pos"][2] + 0.03), "aim": ((0.10, -0.95, 0.30), (0.35, 0.3, 0.88))}
    kl = {"pos": (AIM_L["pos"][0], AIM_L["pos"][1] + 0.035, AIM_L["pos"][2] + 0.028), "aim": ((-0.40, -0.88, 0.25), (0.15, 0.1, 0.98))}
    kick["hand.R"] = kr
    kick["hand.L"] = kl
    kick["chest"] = (kick["chest"][0] - 2.5, kick["chest"][1], 0)
    kick["head"] = (kick["head"][0] - 2, kick["head"][1], 0)
    out.append(keyed(A, "fire", 8, [(0, aim), (1, kick), (3, lerp_pose(aim, kick, 0.5)), (8, aim)], False))
    # reload: tilt gun in, left hand to the belt, insert mag, rack the slide, back on target
    r0 = aim_stance()
    tilt = {"pos": (-0.05, -0.36, 1.27), "aim": ((0.35, -0.92, 0.1), (0.7, 0.2, 0.68))}
    belt = {"pos": (0.13, -0.08, 0.98), "aim": ((0.1, -0.2, -0.97), (0.1, -0.97, 0.2))}
    under = {"pos": (-0.035, -0.30, 1.17), "aim": ((0.1, -0.15, 0.98), (0.2, -0.9, 0.1))}
    slide = {"pos": (-0.02, -0.33, 1.31), "aim": ((-0.5, -0.85, 0.1), (0.1, -0.1, 0.99))}
    rack = {"pos": (-0.02, -0.25, 1.31), "aim": ((-0.5, -0.85, 0.1), (0.1, -0.1, 0.99))}
    def rl(hr, hl, chest=-4, head=10, pole_l=None):
        p = aim_stance()
        p["hand.R"] = hr
        p["hand.L"] = hl
        p["chest"] = (p["chest"][0] + 4, p["chest"][1] + 6, 0)
        p["head"] = (head, 0, 0)
        if pole_l:
            p["elbow_pole.L"] = pole_l
        return p
    k1 = rl(tilt, AIM_L, head=8)
    k2 = rl(tilt, belt, head=14, pole_l={"pos": (0.5, 0.25, 1.1)})
    k3 = rl(tilt, under, head=14, pole_l={"pos": (0.45, 0.1, 0.9)})
    k4 = rl(tilt, slide, head=10)
    k5 = rl(tilt, rack, head=10)
    out.append(keyed(A, "reload", 48, [(0, r0), (6, k1), (14, k2), (18, k2), (27, k3), (30, k3), (35, k4), (38, k5), (41, k4), (48, r0)], False))

    # ---------------- jump ------------------------------------------------------
    st = stand_pose()
    antic = stand_pose()
    antic["hips_off"] = (0, 0.03, -0.18)
    antic["hips"] = (22, 0, 0)
    antic["spine"] = (18, 0, 0)
    antic["chest"] = (8, 0, 0)
    antic["head"] = (-16, 0, 0)
    sym(antic, upper_arm_L=(-25, 10, ARM_DOWN + 5), forearm_L=(30, 0, 0))
    stretch = stand_pose()
    stretch["hips_off"] = (0, -0.02, 0.04)
    stretch["hips"] = (-4, 0, 0)
    stretch["spine"] = (-6, 0, 0)
    stretch["head"] = (6, 0, 0)
    stretch["foot.L"] = {"pos": (0.11, 0.05, ANKLE.z + 0.06), "rot": (35, 0, 6)}
    stretch["foot.R"] = {"pos": (-0.11, 0.05, ANKLE.z + 0.06), "rot": (35, 0, -6)}
    sym(stretch, upper_arm_L=(70, 10, ARM_DOWN + 25), forearm_L=(30, 0, 0))
    out.append(keyed(A, "jump_start", 10, [(0, st), (5, antic), (10, stretch)], False))
    air = stand_pose()
    air["hips"] = (10, 0, 0)
    air["foot.L"] = {"pos": (0.12, 0.10, ANKLE.z + 0.26), "rot": (25, 0, 6)}
    air["foot.R"] = {"pos": (-0.12, -0.04, ANKLE.z + 0.18), "rot": (10, 0, -6)}
    sym(air, upper_arm_L=(40, 10, ARM_DOWN + 40), forearm_L=(45, 0, 0))
    air2 = Pose(air)
    air2["foot.L"] = {"pos": (0.12, 0.06, ANKLE.z + 0.22), "rot": (20, 0, 6)}
    air2["foot.R"] = {"pos": (-0.12, -0.02, ANKLE.z + 0.2), "rot": (12, 0, -6)}
    sym(air2, upper_arm_L=(30, 10, ARM_DOWN + 46))
    out.append(keyed(A, "jump_air", 24, [(0, air), (12, air2)], True))
    land = stand_pose()
    land["hips_off"] = (0, 0.04, -0.24)
    land["hips"] = (26, 0, 0)
    land["spine"] = (16, 0, 0)
    land["chest"] = (8, 0, 0)
    land["head"] = (-18, 0, 0)
    sym(land, upper_arm_L=(25, 10, ARM_DOWN + 25), forearm_L=(40, 0, 0))
    out.append(keyed(A, "jump_land", 16, [(0, air), (3, land), (7, land), (16, st)], False))

    # ---------------- reactions / combat -------------------------------------
    punch0 = stand_pose()
    punch0["hips"] = (2, 10, 0)
    punch0["chest"] = (0, 20, 0)
    sym(punch0, upper_arm_L=(30, 20, ARM_DOWN + 10), forearm_L=(110, 0, 0), fingers_L=(85, 0, 0), thumb_L=(40, 0, 0))
    punch1 = Pose(punch0)
    punch1["hips"] = (4, -16, 0)
    punch1["chest"] = (4, -28, 0)
    punch1["upper_arm.R"] = (85, -10, -(ARM_DOWN + 50))
    punch1["forearm.R"] = (8, 0, 0)
    punch1["foot.L"] = {"pos": (0.12, -0.16, ANKLE.z), "rot": (0, 0, 6)}
    out.append(keyed(A, "punch", 20, [(0, stand_pose()), (6, punch0), (10, punch1), (13, punch1), (20, stand_pose())], False))
    hit = stand_pose()
    hit["spine"] = (-8, 6, 0)
    hit["chest"] = (-12, 8, 0)
    hit["head"] = (-16, -10, 0)
    hit["hips_off"] = (0, 0.03, -0.02)
    sym(hit, upper_arm_L=(-10, 10, ARM_DOWN + 22), forearm_L=(30, 0, 0))
    out.append(keyed(A, "hit", 14, [(0, stand_pose()), (3, hit), (14, stand_pose())], False))
    # deaths: knees go, body drops and rotates onto the ground (legs free, FK)
    def fall(back=True):
        k0 = stand_pose()
        k1 = stand_pose()
        k1["hips_off"] = (0, 0.05 if back else -0.05, -0.25)
        k1["hips"] = ((-10 if back else 14), 8, 4)
        k1["spine"] = ((-12 if back else 20), 0, 0)
        k1["head"] = ((-20 if back else 25), 10, 0)
        sym(k1, upper_arm_L=(20 if back else -10, 10, ARM_DOWN + 30), forearm_L=(30, 0, 0))
        k2 = Pose(k1)
        k2["leg_ik"] = 0.0
        k2["hips_off"] = (0.02, 0.45 if back else -0.42, -0.82)
        k2["hips"] = ((-86 if back else 84), 4, 6)
        k2["spine"] = ((-4 if back else 6), 0, 0)
        k2["chest"] = (0, 0, 0)
        k2["neck"] = ((-6 if back else 8), 10, 0)
        k2["head"] = ((-10 if back else 0), 25, 0)
        k2["thigh.L"] = (20 if back else 12, 0, 6)
        k2["shin.L"] = (12, 0, 0)
        k2["thigh.R"] = (4 if back else 6, 0, -10)
        k2["shin.R"] = (30 if back else 20, 0, 0)
        k2["foot.L.fk"] = 0
        sym(k2, upper_arm_L=(10 if back else -60, 10, ARM_DOWN + 60), forearm_L=(15, 0, 0), fingers_L=(30, 0, 0))
        k2.pop("foot.L.fk")
        k15 = lerp_pose(k1, k2, 0.5)
        k15["leg_ik"] = 0.0
        k3 = Pose(k2)
        k3["hips_off"] = (k2["hips_off"][0], k2["hips_off"][1], k2["hips_off"][2] + 0.02)
        return [(0, k0), (8, k1), (14, k15), (20, k2), (24, k3), (30, k2)]
    out.append(keyed(A, "death_back", 30, fall(True), False))
    out.append(keyed(A, "death_fwd", 30, fall(False), False))

    # ---------------- poses (loops) --------------------------------------------
    hu = stand_pose()
    hu["arm_ik.L"] = 1.0
    hu["arm_ik.R"] = 1.0
    hu["hand.L"] = {"pos": (0.30, -0.06, 1.70), "aim": ((0.05, 0.05, 1.0), (-1.0, 0.0, 0.05))}
    hu["hand.R"] = Pose({"hand.L": hu["hand.L"]}).mirrored()["hand.R"]
    hu["elbow_pole.L"] = {"pos": (0.75, 0.15, 1.15)}
    hu["elbow_pole.R"] = {"pos": (-0.75, 0.15, 1.15)}
    sym(hu, fingers_L=(5, 0, 0), thumb_L=(0, 0, 0))
    hu["head"] = (-2, 0, 0)
    hu2 = Pose(hu)
    hu2["hand.L"] = {"pos": (0.31, -0.07, 1.68), "aim": hu["hand.L"]["aim"]}
    hu2["hand.R"] = Pose({"hand.L": hu2["hand.L"]}).mirrored()["hand.R"]

    def nervous(f, p):
        p = breathe(1.4, 1.5)(f, p)
        p["head"] = (p["head"][0], p["head"][1] + 12 * math.sin(f / FPS * 1.7), 0)
        return p
    out.append(keyed(A, "handsup", 90, [(0, hu), (45, hu2)], True, nervous))

    cower = stand_pose()
    cower["hips_off"] = (0, 0.10, -0.50)
    cower["hips"] = (48, 0, 0)
    cower["spine"] = (26, 0, 0)
    cower["chest"] = (22, 0, 0)
    cower["neck"] = (20, 0, 0)
    cower["head"] = (10, 0, 0)
    cower["foot.L"] = {"pos": (0.15, -0.02, ANKLE.z), "rot": (0, 0, 14)}
    cower["foot.R"] = {"pos": (-0.15, 0.0, ANKLE.z), "rot": (0, 0, -14)}
    cower["arm_ik.L"] = 1.0
    cower["arm_ik.R"] = 1.0
    cower["hand.L"] = {"pos": (0.11, -0.12, 1.69), "aim": ((-0.3, 0.2, 0.93), (-0.2, -0.95, 0.1))}
    cower["hand.R"] = Pose({"hand.L": cower["hand.L"]}).mirrored()["hand.R"]
    cower["elbow_pole.L"] = {"pos": (0.35, -0.6, 1.3)}
    cower["elbow_pole.R"] = {"pos": (-0.35, -0.6, 1.3)}

    def tremble(f, p):
        p = breathe(1.6, 2.2, sway=0.0)(f, p)
        j = math.sin(f * 1.9) * 0.8
        p["spine"] = (p["spine"][0] + j, p["spine"][1], p["spine"][2])
        return p
    out.append(keyed(A, "cower", 60, [(0, cower)], True, tremble))

    def kneel_base():
        k = stand_pose()
        k["hips_off"] = (0, 0.02, -0.43)
        k["hips"] = (2, 0, 0)
        k["foot.L"] = {"pos": (0.12, 0.40, 0.085), "rot": (62, 0, 4)}
        k["foot.R"] = {"pos": (-0.12, 0.40, 0.085), "rot": (62, 0, -4)}
        k["knee_pole.L"] = {"pos": (0.12, -0.6, 0.30)}
        k["knee_pole.R"] = {"pos": (-0.12, -0.6, 0.30)}
        sym(k, toe_L=(45, 0, 0))
        return k
    kh = kneel_base()
    kh["arm_ik.L"] = 1.0
    kh["arm_ik.R"] = 1.0
    kh["hand.L"] = {"pos": (0.07, 0.09, 1.73), "aim": ((-0.6, 0.2, 0.2), (-0.1, -0.2, 0.97))}
    kh["hand.R"] = Pose({"hand.L": kh["hand.L"]}).mirrored()["hand.R"]
    kh["elbow_pole.L"] = {"pos": (0.6, -0.1, 1.7)}
    kh["elbow_pole.R"] = {"pos": (-0.6, -0.1, 1.7)}
    kh["head"] = (8, 0, 0)
    out.append(keyed(A, "kneel_hands", 90, [(0, kh)], True, breathe(1.2, 1.3, sway=0.0)))
    kt = kneel_base()
    kt["arm_ik.L"] = 1.0
    kt["arm_ik.R"] = 1.0
    kt["hand.L"] = {"pos": (0.04, 0.17, 0.99), "aim": ((-0.8, 0.2, -0.2), (0.0, 0.3, -0.95))}
    kt["hand.R"] = Pose({"hand.L": kt["hand.L"]}).mirrored()["hand.R"]
    kt["elbow_pole.L"] = {"pos": (0.4, 0.6, 1.2)}
    kt["elbow_pole.R"] = {"pos": (-0.4, 0.6, 1.2)}
    kt["head"] = (14, 0, 0)
    kt["neck"] = (12, 0, 0)
    kt["shoulder.L"] = (-8, 0, -4)
    kt["shoulder.R"] = (-8, 0, 4)
    out.append(keyed(A, "tied", 90, [(0, kt)], True, breathe(1.0, 1.2, sway=0.0)))

    ph = stand_pose()
    ph["arm_ik.R"] = 1.0
    ph["hand.R"] = {"pos": (-0.10, -0.04, 1.58), "aim": ((0.25, -0.15, 0.95), (0.1, -0.98, -0.1))}
    ph["elbow_pole.R"] = {"pos": (-0.5, -0.3, 1.1)}
    sym(ph, fingers_L=(22, 0, 0))
    ph["fingers.R"] = (55, 0, 0)
    ph["thumb.R"] = (30, 0, 0)
    ph["head"] = (-4, -6, -8)
    ph["foot.L"] = {"pos": (0.12, -0.05, ANKLE.z), "rot": (0, 0, 10)}
    ph["hips"] = (0, 6, -3)
    ph2 = Pose(ph)
    ph2["upper_arm.L"] = (30, 10, ARM_DOWN + 12)
    ph2["forearm.L"] = (60, 0, 0)
    ph2["head"] = (2, 4, -6)

    def talky(f, p):
        p = breathe(1.0, 1.0)(f, p)
        return p
    out.append(keyed(A, "phone", 180, [(0, ph), (60, ph2), (100, ph2), (150, ph)], True, talky))

    tx = stand_pose()
    tx["arm_ik.L"] = 1.0
    tx["arm_ik.R"] = 1.0
    tx["hand.L"] = {"pos": (0.06, -0.27, 1.16), "aim": ((-0.4, -0.6, 0.65), (-0.6, 0.6, 0.4))}
    tx["hand.R"] = Pose({"hand.L": tx["hand.L"]}).mirrored()["hand.R"]
    tx["elbow_pole.L"] = {"pos": (0.4, 0.4, 1.0)}
    tx["elbow_pole.R"] = {"pos": (-0.4, 0.4, 1.0)}
    tx["neck"] = (18, 0, 0)
    tx["head"] = (12, 0, 0)
    sym(tx, fingers_L=(40, 0, 0), thumb_L=(5, 0, 0))
    tx2 = Pose(tx)
    tx2["thumb.R"] = (30, 0, 0)
    tx2["thumb.L"] = (-5, 0, 0)
    out.append(keyed(A, "text", 60, [(0, tx), (8, tx2), (16, tx), (30, tx2), (40, tx)], True, breathe(0.8)))

    fl = stand_pose()
    fl["arm_ik.L"] = 1.0
    fl["arm_ik.R"] = 1.0
    fl["hand.L"] = {"pos": (0.05, -0.36, 1.50), "aim": ((-0.3, -0.25, 0.92), (-0.5, -0.8, -0.1))}
    fl["hand.R"] = Pose({"hand.L": fl["hand.L"]}).mirrored()["hand.R"]
    fl["elbow_pole.L"] = {"pos": (0.5, 0.0, 1.0)}
    fl["elbow_pole.R"] = {"pos": (-0.5, 0.0, 1.0)}
    fl["head"] = (-2, 0, 0)
    sym(fl, fingers_L=(45, 0, 0))
    out.append(keyed(A, "film", 90, [(0, fl)], True, breathe(0.8, sway=0.004)))

    wv = stand_pose()
    wv["arm_ik.R"] = 1.0
    wv["hand.R"] = {"pos": (-0.36, -0.12, 1.66), "aim": ((-0.1, 0.0, 1.0), (0.98, 0.0, 0.1))}
    wv["elbow_pole.R"] = {"pos": (-0.8, 0.1, 1.2)}
    wv["fingers.R"] = (0, 0, 0)
    wv2 = Pose(wv)
    wv2["hand.R"] = {"pos": (-0.25, -0.12, 1.68), "aim": ((0.35, 0.0, 0.94), (0.94, 0.0, -0.35))}
    out.append(keyed(A, "wave", 24, [(0, wv), (12, wv2)], True))

    wk = stand_pose()
    wk["arm_ik.L"] = 1.0
    wk["arm_ik.R"] = 1.0
    wk["spine"] = (10, 0, 0)
    wk["chest"] = (8, 0, 0)
    wk["head"] = (10, 0, 0)
    wk["hand.L"] = {"pos": (0.15, -0.44, 1.24), "aim": ((0.0, -0.9, -0.4), (-0.2, -0.4, 0.9))}
    wk["hand.R"] = Pose({"hand.L": wk["hand.L"]}).mirrored()["hand.R"]
    wk["elbow_pole.L"] = {"pos": (0.6, 0.3, 1.0)}
    wk["elbow_pole.R"] = {"pos": (-0.6, 0.3, 1.0)}
    sym(wk, fingers_L=(50, 0, 0))
    wk2 = Pose(wk)
    wk2["hand.L"] = {"pos": (0.13, -0.48, 1.28), "aim": wk["hand.L"]["aim"]}
    wk2["hand.R"] = {"pos": (-0.16, -0.42, 1.21), "aim": wk["hand.R"]["aim"]}
    wk3 = Pose(wk)
    wk3["hand.L"] = {"pos": (0.16, -0.42, 1.21), "aim": wk["hand.L"]["aim"]}
    wk3["hand.R"] = {"pos": (-0.13, -0.48, 1.28), "aim": wk["hand.R"]["aim"]}
    out.append(keyed(A, "work", 32, [(0, wk), (8, wk2), (16, wk), (24, wk3)], True))

    # smash a display case: wind up overhead, two-handed strike down
    sm0 = stand_pose()
    sm1 = stand_pose()
    sm1["arm_ik.L"] = 1.0
    sm1["arm_ik.R"] = 1.0
    sm1["spine"] = (-8, 10, 0)
    sm1["chest"] = (-10, 12, 0)
    sm1["hand.R"] = {"pos": (-0.10, 0.05, 1.82), "aim": ((0.2, 0.3, 0.93), (0.0, -0.95, 0.3))}
    sm1["hand.L"] = {"pos": (0.02, 0.05, 1.80), "aim": ((-0.2, 0.3, 0.93), (0.0, -0.95, 0.3))}
    sm1["elbow_pole.L"] = {"pos": (0.5, -0.4, 1.6)}
    sm1["elbow_pole.R"] = {"pos": (-0.5, -0.4, 1.6)}
    sm2 = Pose(sm1)
    sm2["spine"] = (24, -4, 0)
    sm2["chest"] = (18, -6, 0)
    sm2["hips_off"] = (0, 0.0, -0.08)
    sm2["hand.R"] = {"pos": (-0.06, -0.50, 1.02), "aim": ((0.1, -0.6, -0.8), (0.0, -0.8, 0.6))}
    sm2["hand.L"] = {"pos": (0.04, -0.48, 1.03), "aim": ((-0.1, -0.6, -0.8), (0.0, -0.8, 0.6))}
    sm2["foot.L"] = {"pos": (0.12, -0.18, ANKLE.z), "rot": (0, 0, 6)}
    sym(sm1, fingers_L=(80, 0, 0))
    sym(sm2, fingers_L=(80, 0, 0))
    out.append(keyed(A, "smash", 26, [(0, sm0), (9, sm1), (14, sm2), (17, sm2), (26, sm0)], False))

    # driving (legs forward, hands on the wheel); steer poses blend left/right
    def seat(hands="wheel", steer=0.0):
        d = stand_pose()
        d["leg_ik"] = 0.0
        d["hips"] = (-12, 0, 0)
        d["spine"] = (4, 0, 0)
        d["chest"] = (2, 0, 0)
        d["neck"] = (4, 0, 0)
        d["head"] = (2, steer * 0.3, 0)
        # car seating: thighs level / knees a touch high, shins reaching for the pedals
        sym(d, thigh_L=(88, 0, 6), shin_L=(52, 0, 0), foot_L=(-2, 0, 0))
        if hands == "wheel":
            d["arm_ik.L"] = 1.0
            d["arm_ik.R"] = 1.0
            a = math.radians(steer)
            cx, cy, cz, r = 0.0, -0.44, 1.18, 0.18
            for s in (1, -1):
                ang = math.radians(90 if s > 0 else -90) * 0.0 + a
                px = cx + s * r * math.cos(a)
                pz = cz + s * r * math.sin(a) * -1.0
                nm = "hand.L" if s > 0 else "hand.R"
                d[nm] = {"pos": (px, cy + 0.02, pz), "aim": ((-0.2 * s, -0.5, 0.85), (-0.9 * s, -0.3, -0.2))}
            d["elbow_pole.L"] = {"pos": (0.45, 0.1, 0.9)}
            d["elbow_pole.R"] = {"pos": (-0.45, 0.1, 0.9)}
            sym(d, fingers_L=(80, 0, 0), thumb_L=(30, 0, 0))
        else:
            sym(d, upper_arm_L=(30, 10, ARM_DOWN + 8), forearm_L=(55, 0, 0), fingers_L=(30, 0, 0))
        return d
    out.append(keyed(A, "drive", 60, [(0, seat())], True, breathe(0.6, sway=0.0)))
    out.append(keyed(A, "drive_l", 2, [(0, seat(steer=55)), (2, seat(steer=55))], False))
    out.append(keyed(A, "drive_r", 2, [(0, seat(steer=-55)), (2, seat(steer=-55))], False))
    out.append(keyed(A, "sit", 60, [(0, seat("lap"))], True, breathe(0.8, sway=0.0)))
    # getting in / out: duck down and swing in (played while the body slides into the seat)
    duck = stand_pose()
    duck["hips_off"] = (0, 0.05, -0.25)
    duck["hips"] = (30, 0, 0)
    duck["spine"] = (25, 0, 0)
    duck["chest"] = (10, 0, 0)
    duck["head"] = (-10, 0, 0)
    sym(duck, upper_arm_L=(30, 10, ARM_DOWN + 10), forearm_L=(40, 0, 0))
    out.append(keyed(A, "enter_car", 18, [(0, stand_pose()), (8, duck), (18, seat())], False))
    out.append(keyed(A, "exit_car", 18, [(0, seat()), (10, duck), (18, stand_pose())], False))
    # dive out of the way of a car
    dv = stand_pose()
    dv["hips_off"] = (0.25, 0.0, -0.2)
    dv["hips"] = (10, 0, -25)
    dv["spine"] = (10, 0, -15)
    dv["foot.L"] = {"pos": (0.35, 0.0, ANKLE.z + 0.15), "rot": (0, 0, 10)}
    sym(dv, upper_arm_L=(-20, 10, ARM_DOWN + 70), forearm_L=(40, 0, 0))
    out.append(keyed(A, "dodge", 18, [(0, stand_pose()), (5, dv), (11, dv), (18, stand_pose())], False))
    return out
