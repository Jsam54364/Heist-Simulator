"""Keyframed animation set for the shared human rig.

Authoring rig: legs and arms get IK chains (foot/hand targets + knee/elbow poles) so feet
plant exactly and two-handed weapon grips line up; everything is then BAKED to plain FK
rotations on the deform bones (visual keying) and the helpers are deleted before export.

Locomotion follows the classic key-pose method (contact -> down -> passing -> up, mirrored
for the other leg; Richard Williams' "contact method"). Runs use contact -> down -> push ->
peak with a flight phase; faster gaits lean further forward and spend less time on the
ground. Feet are driven by a gait function so the planted foot slides back at exactly the
ground speed (no foot skating when the game plays the clip at the matching speed).
Jump = anticipation -> take-off stretch -> airborne -> landing compression -> recovery.

Bone conventions (see humans.py): local +X rotation is flexion (spine/neck bend forward,
knee/elbow bend), Z is sideways (abduction), Y is twist. Right side mirrors left (x, -y, -z).
"""
import math
import bpy
from mathutils import Vector, Matrix, Quaternion, Euler
import bl_util as U

FPS = 30
ANKLE = Vector((0.10, 0.018, 0.095))
BALL = Vector((0.10, -0.095, 0.035))
HEEL = Vector((0.10, 0.06, 0.012))
HIP_Z = 0.96
# A-pose rest: arms hang 40 deg below horizontal. To let them hang at the sides:
ARM_DOWN = -47.0


def lr(n, side):
    return n + (".L" if side > 0 else ".R")


def mirror_rot(v):
    return (v[0], -v[1], -v[2])


def mirror_vec(v):
    return (-v[0], v[1], v[2])


# --------------------------------------------------------------------------- rig setup
def setup_ik(rig):
    """Parent the helpers, add IK + copy-rotation constraints, choose pole angles."""
    U.select_only(rig)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = rig.data.edit_bones
    for s in ("L", "R"):
        # IK target bones duplicate the real end bone so copy-rotation is exact
        for tgt, src, parent in ((f"foot_ik.{s}", f"foot.{s}", None), (f"hand_ik.{s}", f"hand.{s}", "chest")):
            b = eb[tgt]
            b.head = eb[src].head.copy()
            b.tail = eb[src].tail.copy()
            b.roll = eb[src].roll
            b.parent = eb[parent] if parent else None
        eb[f"knee_pole.{s}"].parent = eb["hips"]
        eb[f"elbow_pole.{s}"].parent = eb["chest"]
    bpy.ops.object.mode_set(mode='POSE')
    pb = rig.pose.bones
    for s in ("L", "R"):
        ik = pb[f"shin.{s}"].constraints.new('IK')
        ik.name = "IK"
        ik.target = rig
        ik.subtarget = f"foot_ik.{s}"
        ik.pole_target = rig
        ik.pole_subtarget = f"knee_pole.{s}"
        ik.chain_count = 2
        cr = pb[f"foot.{s}"].constraints.new('COPY_ROTATION')
        cr.name = "IKROT"
        cr.target = rig
        cr.subtarget = f"foot_ik.{s}"
        ik2 = pb[f"forearm.{s}"].constraints.new('IK')
        ik2.name = "IK"
        ik2.target = rig
        ik2.subtarget = f"hand_ik.{s}"
        ik2.pole_target = rig
        ik2.pole_subtarget = f"elbow_pole.{s}"
        ik2.chain_count = 2
        cr2 = pb[f"hand.{s}"].constraints.new('COPY_ROTATION')
        cr2.name = "IKROT"
        cr2.target = rig
        cr2.subtarget = f"hand_ik.{s}"
        for b in pb:
            b.rotation_mode = 'QUATERNION' if b.name.split(".")[0] in ("foot_ik", "hand_ik") else 'XYZ'
    bpy.ops.object.mode_set(mode='OBJECT')
    # pole angles: pick the one that leaves the rest pose untouched
    for chain, end in (("shin", "thigh"), ("forearm", "upper_arm")):
        for s in ("L", "R"):
            c = pb[f"{chain}.{s}"].constraints["IK"]
            best = None
            cands = [a * 1.0 for a in range(-180, 181, 5)]
            for ang in cands + [None]:
                if ang is None:
                    cands2 = [best[1] + d * 0.25 for d in range(-20, 21)]
                    for a2 in cands2:
                        c.pole_angle = math.radians(a2)
                        bpy.context.view_layer.update()
                        e2 = _chain_err(rig, pb, chain, end, s)
                        if e2 < best[0]:
                            best = (e2, a2)
                    break
                c.pole_angle = math.radians(ang)
                bpy.context.view_layer.update()
                err = 0.0
                for bn in (f"{chain}.{s}", f"{end}.{s}"):
                    m = pb[bn].matrix
                    r = rig.data.bones[bn].matrix_local
                    err += (m.col[0].xyz - r.col[0].xyz).length + (m.col[2].xyz - r.col[2].xyz).length + (m.col[3].xyz - r.col[3].xyz).length
                if best is None or err < best[0]:
                    best = (err, ang)
            c.pole_angle = math.radians(best[1])
            print(f"pole {chain}.{s}: {best[1]} deg (err {best[0]:.4f})")
    set_arm_ik(rig, 0.0)


def _chain_err(rig, pb, chain, end, s):
    err = 0.0
    for bn in (f"{chain}.{s}", f"{end}.{s}"):
        m = pb[bn].matrix
        r = rig.data.bones[bn].matrix_local
        err += (m.col[0].xyz - r.col[0].xyz).length + (m.col[2].xyz - r.col[2].xyz).length + (m.col[3].xyz - r.col[3].xyz).length
    return err


def set_arm_ik(rig, w, side=None):
    for s in ("L", "R"):
        if side is None or side == s:
            rig.pose.bones[f"forearm.{s}"].constraints["IK"].influence = w
            rig.pose.bones[f"hand.{s}"].constraints["IKROT"].influence = w


def set_leg_ik(rig, w):
    for s in ("L", "R"):
        rig.pose.bones[f"shin.{s}"].constraints["IK"].influence = w
        rig.pose.bones[f"foot.{s}"].constraints["IKROT"].influence = w


# --------------------------------------------------------------------------- pose model
class Pose(dict):
    """bone -> value.
    FK bones: (x, y, z) local degrees.
    'hips_off': armature-space offset of the hips (m); 'hips': local degrees.
    'foot.L'/'foot.R' IK: {'pos': ankle position (armature space), 'rot': (x, y, z) global degrees}
    'hand.L'/'hand.R' IK: same, but in the chest's rest frame (targets ride with the chest)
    'arm_ik.L'/'arm_ik.R': 0..1, 'leg_ik': 0..1
    """

    def mirrored(self):
        out = Pose()
        for k, v in self.items():
            nk = k
            if k.endswith(".L"):
                nk = k[:-2] + ".R"
            elif k.endswith(".R"):
                nk = k[:-2] + ".L"
            if k == "hips_off":
                out[nk] = mirror_vec(v)
            elif isinstance(v, dict):
                d = {"pos": mirror_vec(v["pos"])}
                if "rot" in v:
                    d["rot"] = mirror_rot(v["rot"])
                if "aim" in v:
                    d["aim"] = (mirror_vec(v["aim"][0]), mirror_vec(v["aim"][1]))
                out[nk] = d
            elif isinstance(v, (tuple, list)):
                out[nk] = mirror_rot(v)
            else:
                out[nk] = v
        return out

    def merged(self, other):
        p = Pose(self)
        p.update(other)
        return p


def lerp_pose(a, b, t):
    out = Pose()
    for k in set(a) | set(b):
        va = a.get(k, b.get(k))
        vb = b.get(k, a.get(k))
        if isinstance(va, dict):
            d = {"pos": tuple(va["pos"][i] + (vb["pos"][i] - va["pos"][i]) * t for i in range(3))}
            if "aim" in va or "aim" in vb:
                aa = va.get("aim", vb.get("aim"))
                ab = vb.get("aim", aa)
                d["aim"] = tuple(tuple(aa[j][i] + (ab[j][i] - aa[j][i]) * t for i in range(3)) for j in range(2))
            else:
                d["rot"] = tuple(va.get("rot", (0, 0, 0))[i] + (vb.get("rot", (0, 0, 0))[i] - va.get("rot", (0, 0, 0))[i]) * t for i in range(3))
            out[k] = d
        elif isinstance(va, (tuple, list)):
            out[k] = tuple(va[i] + (vb[i] - va[i]) * t for i in range(3))
        else:
            out[k] = va + (vb - va) * t
    return out


def ease(t):
    return t * t * (3 - 2 * t)


class Animator:
    def __init__(self, rig):
        self.rig = rig
        self.pb = rig.pose.bones
        self.rest = {b.name: b.matrix_local.copy() for b in rig.data.bones}
        self.actions = []

    def begin(self, name):
        rig = self.rig
        if rig.animation_data is None:
            rig.animation_data_create()
        act = bpy.data.actions.new(name + "_src")
        rig.animation_data.action = act
        for b in self.pb:
            b.location = (0, 0, 0)
            b.rotation_quaternion = (1, 0, 0, 0)
            b.rotation_euler = (0, 0, 0)
        return act

    def _local_offset(self, bone, world_offset):
        r = self.rest[bone].to_3x3()
        return r.inverted() @ Vector(world_offset)

    def _local_rot(self, bone, euler_deg):
        r = self.rest[bone].to_3x3()
        d = Euler([math.radians(a) for a in euler_deg], 'XYZ').to_matrix()
        return (r.inverted() @ d @ r).to_quaternion()

    def _aim_rot(self, bone, aim):
        """Orientation from the bone's desired Y (along the bone) and Z (thumb side) axes."""
        y = Vector(aim[0]).normalized()
        z = Vector(aim[1])
        z = (z - y * z.dot(y)).normalized()
        x = y.cross(z)
        m = Matrix((x, y, z)).transposed()
        r = self.rest[bone].to_3x3()
        return (r.inverted() @ m).to_quaternion()

    def apply(self, pose, frame):
        pb = self.pb
        for k, v in pose.items():
            if k == "hips_off":
                pb["hips"].location = self._local_offset("hips", v)
                pb["hips"].keyframe_insert("location", frame=frame)
            elif k in ("foot.L", "foot.R", "hand.L", "hand.R") and isinstance(v, dict):
                tgt = k.replace("foot", "foot_ik").replace("hand", "hand_ik")
                head = self.rest[tgt].to_translation()
                pb[tgt].location = self._local_offset(tgt, Vector(v["pos"]) - head)
                if "aim" in v:
                    pb[tgt].rotation_quaternion = self._aim_rot(tgt, v["aim"])
                else:
                    pb[tgt].rotation_quaternion = self._local_rot(tgt, v.get("rot", (0, 0, 0)))
                pb[tgt].keyframe_insert("location", frame=frame)
                pb[tgt].keyframe_insert("rotation_quaternion", frame=frame)
            elif k.startswith(("elbow_pole.", "knee_pole.")):
                head = self.rest[k].to_translation()
                pb[k].location = self._local_offset(k, Vector(v["pos"]) - head)
                pb[k].keyframe_insert("location", frame=frame)
            elif k.startswith("arm_ik."):
                s = k[-1]
                for bn, cn in ((f"forearm.{s}", "IK"), (f"hand.{s}", "IKROT")):
                    c = pb[bn].constraints[cn]
                    c.influence = v
                    c.keyframe_insert("influence", frame=frame)
            elif k == "leg_ik":
                for s in ("L", "R"):
                    for bn, cn in ((f"shin.{s}", "IK"), (f"foot.{s}", "IKROT")):
                        c = pb[bn].constraints[cn]
                        c.influence = v
                        c.keyframe_insert("influence", frame=frame)
            elif k in pb:
                pb[k].rotation_euler = Euler([math.radians(a) for a in v], 'XYZ')
                pb[k].keyframe_insert("rotation_euler", frame=frame)

    def finish(self, name, frames, loop):
        """Bake constraints into plain FK keys on deform bones only."""
        rig = self.rig
        src = rig.animation_data.action
        for fc in _fcurves(src):
            for kp in fc.keyframe_points:
                kp.interpolation = 'BEZIER'
                kp.handle_left_type = 'AUTO_CLAMPED'
                kp.handle_right_type = 'AUTO_CLAMPED'
            if loop:
                fc.modifiers.new('CYCLES')
        U.select_only(rig)
        bpy.ops.object.mode_set(mode='POSE')
        for b in rig.pose.bones:
            b.select = rig.data.bones[b.name].use_deform
        bpy.ops.nla.bake(frame_start=0, frame_end=frames - (1 if loop else 0), step=1, only_selected=True, visual_keying=True,
                         clear_constraints=False, clear_parents=False, use_current_action=False, clean_curves=False,
                         bake_types={'POSE'}, channel_types={'LOCATION', 'ROTATION'})
        bpy.ops.object.mode_set(mode='OBJECT')
        baked = rig.animation_data.action
        baked.name = name
        # keep only deform bones; only the hips may translate
        for fc in list(_fcurves(baked)):
            bone = fc.data_path.split('"')[1] if '"' in fc.data_path else ""
            if bone not in rig.data.bones or not rig.data.bones[bone].use_deform or ("location" in fc.data_path and bone != "hips"):
                _remove_fcurve(baked, fc)
        baked["loop"] = loop
        baked["length"] = frames / FPS
        baked.use_fake_user = True
        bpy.data.actions.remove(src)
        rig.animation_data.action = None
        self.actions.append(baked)
        return baked


def _fcurves(action):
    if hasattr(action, "fcurves") and action.fcurves is not None:
        try:
            return list(action.fcurves)
        except Exception:
            pass
    out = []
    for layer in action.layers:
        for strip in layer.strips:
            for cb in strip.channelbags:
                out.extend(cb.fcurves)
    return out


def _remove_fcurve(action, fc):
    try:
        action.fcurves.remove(fc)
        return
    except Exception:
        pass
    for layer in action.layers:
        for strip in layer.strips:
            for cb in strip.channelbags:
                if fc in list(cb.fcurves):
                    cb.fcurves.remove(fc)
                    return


# --------------------------------------------------------------------------- base poses
def stand_pose():
    p = Pose({
        "hips": (0, 0, 0), "hips_off": (0, 0, 0),
        "spine": (2, 0, 0), "chest": (-3, 0, 0), "neck": (5, 0, 0), "head": (-4, 0, 0),
        "leg_ik": 1.0, "arm_ik.L": 0.0, "arm_ik.R": 0.0,
    })
    for s in (1, -1):
        side = {
            "shoulder.L": (0, 0, -3),
            "upper_arm.L": (5, 10, ARM_DOWN),
            "forearm.L": (14, 0, 0),
            "hand.L": (0, 0, 8),
            "fingers.L": (22, 0, 0),
            "thumb.L": (12, 0, 0),
            "toe.L": (0, 0, 0),
            "foot.L": {"pos": (0.115, 0.0, ANKLE.z), "rot": (0, 0, 6)},
        }
        if s > 0:
            p.update(side)
        else:
            p.update(Pose(side).mirrored())
    return p


def catmull(keys, t):
    """keys: [(t, v)...] covering [0,1], periodic-ish piecewise smooth interpolation."""
    for i in range(len(keys) - 1):
        t0, v0 = keys[i]
        t1, v1 = keys[i + 1]
        if t0 <= t <= t1:
            u = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
            u = ease(u)
            return v0 + (v1 - v0) * u
    return keys[-1][1]


def foot_place(base, travel, pitch_up, lift, yaw_deg, dir_vec):
    """Ankle target for a foot that has travelled `travel` m along dir_vec from its base,
    pitched `pitch_up` deg (toes up +) about the heel (+) or the ball (-), lifted `lift` m."""
    off = Vector(base) - ANKLE + Vector(dir_vec) * travel
    ankle_flat = ANKLE + off
    pivot = (HEEL if pitch_up > 0 else BALL) + off
    r = Matrix.Rotation(math.radians(-pitch_up), 3, 'X')
    ankle = pivot + r @ (ankle_flat - pivot)
    ankle.z += lift
    return {"pos": tuple(ankle), "rot": (-pitch_up, 0, yaw_deg)}


def gait(A, name, speed, cycle, duty, lift, bob, lean, arm_swing, elbow, hip_yaw, hip_tilt, sway,
         kind="walk", crouch=0.0, upper=None, dir_vec=(0, -1, 0), stance_w=0.11, arm_out=0.0, fists=False):
    """Locomotion cycle generator (see module doc). `upper` = Pose overriding upper body."""
    frames = int(round(cycle * FPS))
    T = cycle
    S = speed * duty * T                   # distance a planted foot slides back per step
    lateral = abs(dir_vec[0]) > 0.5
    A.begin(name)
    base = stand_pose()
    bob_keys = ([(0, 0.0), (0.22, -1.0), (0.5, 0.2), (0.78, 1.0), (1.0, 0.0)] if kind == "walk"
                else [(0, -0.3), (0.18, -1.0), (0.42, 0.1), (0.7, 1.0), (1.0, -0.3)])
    for f in range(0, frames + 1, 1):
        ph = f / frames
        p = Pose(base)
        feet = {}
        for side, pp in ((1, ph), (-1, (ph + 0.5) % 1.0)):
            bx = stance_w * side
            if lateral:
                bx = (stance_w + 0.03) * side
            fbase = (bx, 0.0, ANKLE.z)
            if pp < duty:
                s = pp / duty
                travel = S * 0.5 - S * s
                if lateral:
                    pitch = 0.0
                else:
                    pitch = 14.0 * (1 - min(1.0, s / 0.18)) ** 2 if kind == "walk" else 6.0 * (1 - min(1.0, s / 0.12))
                    if s > 0.62:
                        pitch = -(s - 0.62) / 0.38 * (24.0 if kind == "walk" else 34.0)
                l = 0.0
            else:
                s = (pp - duty) / (1 - duty)
                travel = -S * 0.5 + S * ease(s)
                l = lift * math.sin(math.pi * min(1.0, s * 1.08)) ** 0.9
                if lateral:
                    pitch = 0.0
                else:
                    toe_off = -(24.0 if kind == "walk" else 34.0)
                    pitch = toe_off * (1 - s) ** 2 + (14.0 if kind == "walk" else 6.0) * s ** 3 - 8.0 * math.sin(math.pi * s) * (0 if kind == "walk" else 1)
            yaw = 6.0 * side
            fp = foot_place(fbase, travel, pitch, l, yaw, dir_vec)
            feet[side] = fp
            key = "foot.L" if side > 0 else "foot.R"
            p[key] = fp
            tkey = "toe.L" if side > 0 else "toe.R"
            p[tkey] = (max(0.0, -pitch) * 0.9, 0, 0)
        step = (ph * 2.0) % 1.0
        h = catmull(bob_keys, step)
        c = math.cos(2 * math.pi * ph)
        cl = math.cos(2 * math.pi * (ph - duty * 0.5))
        p["hips_off"] = (sway * cl, (-lean * 0.004 if not lateral else 0.0), bob * h - crouch)
        p["hips"] = (lean * 0.3 + crouch * 20.0, -hip_yaw * c, hip_tilt * cl)
        p["spine"] = (lean * 0.35 + 2 + crouch * 8.0, hip_yaw * 0.45 * c, -hip_tilt * 0.6 * cl)
        p["chest"] = (lean * 0.35 - 3 + crouch * 6.0, hip_yaw * 0.9 * c, -hip_tilt * 0.3 * cl)
        p["neck"] = (5 - lean * 0.4 - crouch * 14.0, -hip_yaw * 0.3 * c, 0)
        p["head"] = (-4 - lean * 0.45 - crouch * 12.0 - bob * h * 40.0, -hip_yaw * 0.12 * c, hip_tilt * 0.4 * cl)
        # knee poles ride forward with crouch
        for side in (1, -1):
            ca = math.cos(2 * math.pi * (ph - 0.1 + (0 if side > 0 else 0.5)))
            n = "upper_arm.L" if side > 0 else "upper_arm.R"
            fn = "forearm.L" if side > 0 else "forearm.R"
            flex = -arm_swing * ca
            v = (5 + flex, 10 + flex * 0.15, ARM_DOWN + arm_out + max(0.0, flex) * 0.12)
            p[n] = v if side > 0 else mirror_rot(v)
            e = elbow + max(0.0, flex) * (0.6 if kind != "walk" else 0.35)
            p[fn] = (e, 0, 0) if side > 0 else (e, 0, 0)
            fing = (68, 0, 0) if fists else (22, 0, 0)
            p["fingers.L" if side > 0 else "fingers.R"] = fing
            p["thumb.L" if side > 0 else "thumb.R"] = ((40, 0, 0) if fists else (12, 0, 0))
        if upper:
            p.update(upper)
        A.apply(p, f)
    return A.finish(name, frames, True)
